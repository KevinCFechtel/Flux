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
    let Ok(tagged) = lofty::read_from_path(path) else {
        return AnalyzedMedia::default();
    };
    use lofty::file::{AudioFile, TaggedFileExt};
    let duration_ms = (tagged.properties().duration().as_millis() > 0)
        .then(|| tagged.properties().duration().as_millis() as u64);
    let artwork = tagged
        .primary_tag()
        .and_then(|tag| tag.pictures().first())
        .map(|picture| picture.data().to_vec())
        .filter(|data| !data.is_empty() && data.len() <= 10 * 1024 * 1024);
    let mut embedded_chapters = tagged
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
        .collect::<Vec<_>>();
    embedded_chapters.sort_by_key(|chapter| chapter.start_ms);
    embedded_chapters.dedup_by_key(|chapter| chapter.start_ms);
    embedded_chapters.retain(|chapter| {
        !chapter.title.is_empty() && duration_ms.is_none_or(|duration| chapter.start_ms <= duration)
    });
    for index in 0..embedded_chapters.len().saturating_sub(1) {
        embedded_chapters[index].end_ms = Some(embedded_chapters[index + 1].start_ms);
    }
    if let (Some(duration), Some(last)) = (duration_ms, embedded_chapters.last_mut())
        && duration > last.start_ms
    {
        last.end_ms = Some(duration);
    }
    AnalyzedMedia {
        duration_ms,
        artwork,
        embedded_chapters,
    }
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
    if numbers[0] >= 60 || numbers[1] >= 60 || (parts.len() == 3 && numbers[1] >= 60) {
        return None;
    }
    let seconds = if parts.len() == 2 {
        numbers[0] * 60 + numbers[1]
    } else {
        numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
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
}
