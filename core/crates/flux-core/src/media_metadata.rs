use std::io::Read;
use std::path::{Component, Path, PathBuf};

use crate::domain::{MediaChapter, MediaChapterSource};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct AnalyzedMedia {
    pub duration_ms: Option<u64>,
    pub artwork: Option<Vec<u8>>,
    pub embedded_chapters: Vec<MediaChapterInput>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MediaChapterInput {
    pub title: String,
    pub start_ms: u64,
    pub end_ms: Option<u64>,
}

pub(crate) fn resolve_media_reference(root: &Path, reference: &str) -> Option<PathBuf> {
    let path = Path::new(reference);
    if path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return None;
    }
    Some(root.join(path))
}

pub(crate) fn analyze_file(path: &Path) -> AnalyzedMedia {
    if !path.is_file() {
        return AnalyzedMedia::default();
    }
    let bytes = bounded_file_prefix(path);
    let structured_chapters = bytes.as_deref().map(parse_id3_chapters).unwrap_or_default();
    let (duration_ms, artwork, text_chapters) = if let Ok(tagged) = lofty::read_from_path(path) {
        use lofty::file::{AudioFile, TaggedFileExt};
        let duration_ms = (tagged.properties().duration().as_millis() > 0)
            .then(|| tagged.properties().duration().as_millis() as u64);
        let artwork = tagged
            .primary_tag()
            .and_then(|tag| tag.pictures().first())
            .map(|picture| picture.data().to_vec())
            .filter(|data| !data.is_empty() && data.len() <= 10 * 1024 * 1024);
        let chapters = tagged
            .tags()
            .iter()
            .flat_map(|tag| tag.items())
            .filter_map(|item| {
                let lofty::tag::ItemKey::Unknown(key) = item.key() else {
                    return None;
                };
                if !key.to_ascii_uppercase().starts_with("CHAPTER") {
                    return None;
                }
                let lofty::tag::ItemValue::Text(value) = item.value() else {
                    return None;
                };
                let (timestamp, title) = value.split_once(' ')?;
                Some(MediaChapterInput {
                    title: title.trim().to_string(),
                    start_ms: parse_timestamp(timestamp)?,
                    end_ms: None,
                })
            })
            .collect();
        (duration_ms, artwork, chapters)
    } else {
        (None, None, Vec::new())
    };
    let mut embedded_chapters = if structured_chapters.is_empty() {
        text_chapters
    } else {
        structured_chapters
    };
    embedded_chapters = finalize_chapters(embedded_chapters, duration_ms);
    AnalyzedMedia {
        duration_ms,
        artwork,
        embedded_chapters,
    }
}

fn bounded_file_prefix(path: &Path) -> Option<Vec<u8>> {
    const MAX_ID3_BYTES: u64 = 8 * 1024 * 1024;
    let file = std::fs::File::open(path).ok()?;
    let mut bytes = Vec::new();
    file.take(MAX_ID3_BYTES).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

fn parse_id3_chapters(bytes: &[u8]) -> Vec<MediaChapterInput> {
    if bytes.len() < 10 || &bytes[0..3] != b"ID3" || !(bytes[3] == 3 || bytes[3] == 4) {
        return Vec::new();
    }
    let tag_size = syncsafe(&bytes[6..10]).unwrap_or(0);
    let end = 10usize.saturating_add(tag_size).min(bytes.len());
    let mut offset = 10usize;
    let mut chapters = Vec::new();
    while offset.saturating_add(10) <= end {
        let header = &bytes[offset..offset + 10];
        if header.iter().all(|byte| *byte == 0) {
            let Some(next) = resynchronize_frame(bytes, offset + 1, end, bytes[3]) else {
                break;
            };
            offset = next;
            continue;
        }
        let frame_size = if bytes[3] == 4 {
            syncsafe(&header[4..8])
        } else {
            Some(u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize)
        };
        let Some(frame_size) = frame_size else {
            let Some(next) = resynchronize_frame(bytes, offset + 1, end, bytes[3]) else {
                break;
            };
            offset = next;
            continue;
        };
        let frame_end = offset
            .checked_add(10)
            .and_then(|value| value.checked_add(frame_size));
        let Some(frame_end) = frame_end.filter(|value| *value <= end) else {
            let Some(next) = resynchronize_frame(bytes, offset + 1, end, bytes[3]) else {
                break;
            };
            offset = next;
            continue;
        };
        if &header[0..4] == b"CHAP"
            && let Some(chapter) = parse_chap(&bytes[offset + 10..frame_end], bytes[3])
        {
            chapters.push(chapter);
        }
        offset = frame_end;
    }
    finalize_chapters(chapters, None)
}

fn parse_chap(payload: &[u8], version: u8) -> Option<MediaChapterInput> {
    let id_end = payload.iter().position(|byte| *byte == 0)?;
    let timing = payload.get(id_end + 1..id_end + 17)?;
    let start_ms = u64::from(u32::from_be_bytes(timing[0..4].try_into().ok()?));
    let end_raw = u32::from_be_bytes(timing[4..8].try_into().ok()?);
    let end_ms = (end_raw != u32::MAX).then_some(u64::from(end_raw));
    let title = parse_id3_title_frames(&payload[id_end + 17..], version)
        .or_else(|| String::from_utf8(payload[..id_end].to_vec()).ok())?;
    Some(MediaChapterInput {
        title,
        start_ms,
        end_ms,
    })
}

fn resynchronize_frame(bytes: &[u8], start: usize, end: usize, version: u8) -> Option<usize> {
    let last = end.checked_sub(10)?;
    for offset in start..=last {
        let header = bytes.get(offset..offset + 10)?;
        if !header[0].is_ascii_uppercase()
            || !header[1..4]
                .iter()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        {
            continue;
        }
        let size = if version == 4 {
            syncsafe(&header[4..8])
        } else {
            Some(u32::from_be_bytes(header[4..8].try_into().ok()?) as usize)
        }?;
        if offset
            .checked_add(10)
            .and_then(|value| value.checked_add(size))
            .is_some_and(|frame_end| frame_end <= end)
        {
            return Some(offset);
        }
    }
    None
}

fn parse_id3_title_frames(mut bytes: &[u8], version: u8) -> Option<String> {
    while bytes.len() >= 10 {
        let size = if version == 4 {
            syncsafe(&bytes[4..8])?
        } else {
            u32::from_be_bytes(bytes[4..8].try_into().ok()?) as usize
        };
        let end = 10usize.checked_add(size)?;
        if end > bytes.len() {
            return None;
        }
        if &bytes[0..4] == b"TIT2" && size > 1 {
            return decode_id3_text(&bytes[10..end]);
        }
        bytes = &bytes[end..];
    }
    None
}

fn decode_id3_text(bytes: &[u8]) -> Option<String> {
    let (encoding, value) = bytes.split_first()?;
    let text = match encoding {
        0 => value.iter().map(|byte| char::from(*byte)).collect(),
        1 | 2 => String::from_utf16(
            &value
                .chunks(2)
                .filter(|pair| pair.len() == 2)
                .map(|pair| {
                    if *encoding == 1 {
                        u16::from_le_bytes([pair[0], pair[1]])
                    } else {
                        u16::from_be_bytes([pair[0], pair[1]])
                    }
                })
                .collect::<Vec<_>>(),
        )
        .ok()?,
        3 => String::from_utf8(value.to_vec()).ok()?,
        _ => return None,
    };
    (!text.trim().is_empty())
        .then(|| text.trim_matches('\0').trim().to_string())
        .filter(|text| !text.is_empty())
}

fn syncsafe(bytes: &[u8]) -> Option<usize> {
    (bytes.len() == 4 && bytes.iter().all(|byte| byte & 0x80 == 0)).then(|| {
        usize::from(bytes[0]) << 21
            | usize::from(bytes[1]) << 14
            | usize::from(bytes[2]) << 7
            | usize::from(bytes[3])
    })
}

fn finalize_chapters(
    mut chapters: Vec<MediaChapterInput>,
    duration_ms: Option<u64>,
) -> Vec<MediaChapterInput> {
    chapters.sort_by_key(|chapter| chapter.start_ms);
    chapters.dedup_by_key(|chapter| chapter.start_ms);
    chapters.retain(|chapter| {
        !chapter.title.is_empty() && duration_ms.is_none_or(|duration| chapter.start_ms <= duration)
    });
    for chapter in &mut chapters {
        if chapter.end_ms.is_some_and(|end| {
            end <= chapter.start_ms || duration_ms.is_some_and(|duration| end > duration)
        }) {
            chapter.end_ms = None;
        }
    }
    for index in 0..chapters.len().saturating_sub(1) {
        if chapters[index].end_ms.is_none() {
            chapters[index].end_ms = Some(chapters[index + 1].start_ms);
        }
    }
    if let (Some(duration), Some(last)) = (duration_ms, chapters.last_mut())
        && duration > last.start_ms
        && last.end_ms.is_none()
    {
        last.end_ms = Some(duration);
    }
    chapters.retain(|chapter| chapter.end_ms.is_none_or(|end| end > chapter.start_ms));
    chapters
}

pub(crate) fn article_chapters(
    article_html: &str,
    duration_ms: Option<u64>,
) -> Vec<MediaChapterInput> {
    let text = strip_tags(article_html);
    let mut chapters = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let Some((timestamp, title)) = line.split_once(' ') else {
            continue;
        };
        let Some(start_ms) = parse_timestamp(timestamp) else {
            continue;
        };
        let title = title.trim();
        if title.is_empty() || duration_ms.is_some_and(|duration| start_ms > duration) {
            continue;
        }
        if chapters
            .last()
            .is_some_and(|chapter: &MediaChapterInput| chapter.start_ms == start_ms)
        {
            continue;
        }
        chapters.push(MediaChapterInput {
            title: title.to_string(),
            start_ms,
            end_ms: None,
        });
    }
    chapters.sort_by_key(|chapter| chapter.start_ms);
    for index in 0..chapters.len().saturating_sub(1) {
        chapters[index].end_ms = Some(chapters[index + 1].start_ms);
    }
    if let (Some(duration), Some(last)) = (duration_ms, chapters.last_mut())
        && duration > last.start_ms
    {
        last.end_ms = Some(duration);
    }
    chapters.retain(|chapter| chapter.end_ms.is_none_or(|end| end > chapter.start_ms));
    chapters
}

pub(crate) fn to_domain_chapters(
    enclosure_id: i64,
    source: MediaChapterSource,
    inputs: &[MediaChapterInput],
) -> Vec<MediaChapter> {
    inputs
        .iter()
        .map(|chapter| MediaChapter {
            enclosure_id,
            title: chapter.title.clone(),
            start_ms: chapter.start_ms,
            end_ms: chapter.end_ms,
            source,
        })
        .collect()
}

fn parse_timestamp(value: &str) -> Option<u64> {
    let parts = value.split(':').collect::<Vec<_>>();
    if !(2..=3).contains(&parts.len()) {
        return None;
    }
    let numbers = parts
        .iter()
        .map(|part| part.parse::<u64>().ok())
        .collect::<Option<Vec<_>>>()?;
    if numbers[1] >= 60 || (parts.len() == 3 && numbers[2] >= 60) {
        return None;
    }
    let seconds = if parts.len() == 2 {
        numbers[0].checked_mul(60)?.checked_add(numbers[1])?
    } else {
        numbers[0]
            .checked_mul(3600)?
            .checked_add(numbers[1].checked_mul(60)?)?
            .checked_add(numbers[2])?
    };
    seconds.checked_mul(1000)
}

fn strip_tags(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    let mut inside = false;
    for character in value.chars() {
        match character {
            '<' => inside = true,
            '>' => inside = false,
            _ if !inside => output.push(character),
            _ => {}
        }
    }
    output.replace("&nbsp;", " ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn article_timestamps_are_ordered_and_bounded() {
        let chapters = article_chapters(
            "00:00 Intro\n03:42 Topic One\n15:10 Topic Two",
            Some(20 * 60 * 1000),
        );
        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[1].start_ms, 222_000);
        assert_eq!(chapters[0].end_ms, Some(222_000));
        assert_eq!(chapters[2].end_ms, Some(1_200_000));
    }

    #[test]
    fn invalid_timestamps_and_traversal_references_are_ignored() {
        assert!(article_chapters("99:99 Not a chapter\n123 unrelated", None).is_empty());
        assert!(resolve_media_reference(Path::new("/media"), "../outside.mp3").is_none());
        assert!(resolve_media_reference(Path::new("/media"), "/tmp/file.mp3").is_none());
    }

    #[test]
    fn long_form_timestamps_allow_unbounded_minutes_but_validate_seconds() {
        assert_eq!(parse_timestamp("60:00"), Some(3_600_000));
        assert_eq!(parse_timestamp("75:30"), Some(4_530_000));
        assert_eq!(parse_timestamp("1:15:30"), Some(4_530_000));
        assert_eq!(parse_timestamp("1:23:75"), None);
        assert_eq!(parse_timestamp("75:99"), None);
        assert_eq!(
            article_chapters("60:00 Long intro\n75:30 Topic", None)[0].start_ms,
            3_600_000
        );
    }

    #[test]
    fn id3_chap_frames_are_structured_and_malformed_frames_fail_softly() {
        let mut frames = chapter_frame("one", 0, 30_000, Some(25_000), "Intro");
        frames.extend_from_slice(&malformed_oversized_frame());
        frames.extend(chapter_frame("two", 30_000, 90_000, None, "Topic"));
        let fixture = id3_fixture(&frames);
        let chapters = parse_id3_chapters(&fixture);
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "Intro");
        assert_eq!(chapters[0].end_ms, Some(25_000));
        assert_eq!(chapters[1].start_ms, 30_000);
        assert_eq!(chapters[1].title, "Topic");
    }

    #[test]
    fn missing_chap_end_is_derived_and_oversized_frames_terminate_safely() {
        let mut frames = chapter_frame("one", 0, 30_000, None, "Intro");
        frames.extend(chapter_frame("two", 30_000, 60_000, Some(60_000), "Topic"));
        let chapters = parse_id3_chapters(&id3_fixture(&frames));
        assert_eq!(chapters[0].end_ms, Some(30_000));
        let malformed_end = [
            chapter_frame("bad", 30_000, 0, Some(20_000), "Bad boundary"),
            chapter_frame("good", 40_000, 0, Some(60_000), "Good"),
        ]
        .concat();
        let chapters = parse_id3_chapters(&id3_fixture(&malformed_end));
        assert_eq!(chapters[0].title, "Bad boundary");
        assert_eq!(chapters[0].end_ms, Some(40_000));
        assert!(parse_id3_chapters(&id3_fixture(&malformed_oversized_frame())).is_empty());
    }

    fn malformed_oversized_frame() -> Vec<u8> {
        let mut frame = b"JUNK".to_vec();
        frame.extend_from_slice(&u32::MAX.to_be_bytes());
        frame.extend_from_slice(&[0, 0]);
        frame
    }

    fn chapter_frame(
        id: &str,
        start: u32,
        _end: u32,
        explicit_end: Option<u32>,
        title: &str,
    ) -> Vec<u8> {
        let mut payload = id.as_bytes().to_vec();
        payload.push(0);
        payload.extend_from_slice(&start.to_be_bytes());
        payload.extend_from_slice(&explicit_end.unwrap_or(u32::MAX).to_be_bytes());
        payload.extend_from_slice(&0u32.to_be_bytes());
        payload.extend_from_slice(&0u32.to_be_bytes());
        let mut title_frame = b"TIT2".to_vec();
        let text = [vec![3], title.as_bytes().to_vec()].concat();
        title_frame.extend_from_slice(&(text.len() as u32).to_be_bytes());
        title_frame.extend_from_slice(&[0, 0]);
        title_frame.extend_from_slice(&text);
        payload.extend_from_slice(&title_frame);
        let mut frame = b"CHAP".to_vec();
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&[0, 0]);
        frame.extend_from_slice(&payload);
        frame
    }

    fn id3_fixture(frames: &[u8]) -> Vec<u8> {
        let size = frames.len();
        let mut fixture = b"ID3\x03\x00\x00".to_vec();
        fixture.extend_from_slice(&[
            (size >> 21) as u8,
            (size >> 14) as u8 & 0x7f,
            (size >> 7) as u8 & 0x7f,
            size as u8 & 0x7f,
        ]);
        fixture.extend_from_slice(frames);
        fixture
    }
}
