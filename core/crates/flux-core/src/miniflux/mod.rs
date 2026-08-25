//! Miniflux HTTP adapter. It maps wire data into domain values and never persists it.

use std::collections::HashMap;
use std::io::Read;
use std::sync::Mutex;
use std::time::Instant;

use crate::domain::{Article, Category, CoreError, Feed};
use chrono::{DateTime, SecondsFormat};
use serde::Deserialize;

const PAGE_SIZE: i64 = 100;

#[derive(Clone, Debug)]
pub struct RemoteSnapshot {
    pub categories: Vec<Category>,
    pub feeds: Vec<Feed>,
    pub articles: Vec<Article>,
}

pub struct RemoteImage {
    pub content_type: Option<String>,
    pub bytes: Vec<u8>,
}

pub trait RemoteSource: Send + Sync {
    fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, CoreError>;
    fn set_read_state(&self, article_ids: &[i64], read: bool) -> Result<(), CoreError>;
    fn set_starred_state(&self, article_id: i64, starred: bool) -> Result<(), CoreError>;
    fn fetch_feed_icon(&self, _feed_id: i64) -> Result<Option<String>, CoreError> {
        Err(CoreError::data("feed icon acquisition is unavailable"))
    }
    fn fetch_article_image(&self, _url: &str, _max_bytes: usize) -> Result<RemoteImage, CoreError> {
        Err(CoreError::data(
            "article thumbnail acquisition is unavailable",
        ))
    }
}

pub struct MinifluxClient {
    agent: ureq::Agent,
    base_url: String,
    api_key: String,
    request_lock: Mutex<()>,
}

impl MinifluxClient {
    pub fn new(base_url: &str, api_key: &str) -> Result<Self, CoreError> {
        let base_url = base_url
            .trim_end_matches('/')
            .trim_end_matches("/v1")
            .to_string();
        let parsed = url::Url::parse(&base_url)
            .map_err(|_| CoreError::invalid_configuration("base URL is invalid"))?;
        if !matches!(parsed.scheme(), "https" | "http") {
            return Err(CoreError::invalid_configuration(
                "base URL must use HTTP(S)",
            ));
        }
        Ok(Self {
            agent: ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(80))
                .redirects(10)
                .build(),
            base_url,
            api_key: api_key.to_string(),
            request_lock: Mutex::new(()),
        })
    }
    fn get<T: for<'a> Deserialize<'a>>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, CoreError> {
        let _request = self
            .request_lock
            .lock()
            .map_err(|_| CoreError::internal("HTTP client lock poisoned"))?;
        let mut serializer = url::form_urlencoded::Serializer::new(String::new());
        for (key, value) in query {
            serializer.append_pair(key, value);
        }
        let suffix = serializer.finish();
        let url = if suffix.is_empty() {
            format!("{}{path}", self.base_url)
        } else {
            format!("{}{path}?{suffix}", self.base_url)
        };
        let started = Instant::now();
        tracing::debug!(target: "miniflux", "request started endpoint={path}");
        let response = match self
            .agent
            .get(&url)
            .set("Accept", "application/json")
            .set("X-Auth-Token", &self.api_key)
            .call()
            .map_err(map_http_error)
        {
            Ok(response) => response,
            Err(error) => {
                tracing::warn!(target: "miniflux", "request failed endpoint={} kind={:?} elapsed_ms={}", path, error.kind, started.elapsed().as_millis());
                return Err(error);
            }
        };
        let decoded = serde_json::from_reader(response.into_reader())
            .map_err(|e| CoreError::data(format!("invalid Miniflux response: {e}")));
        match decoded {
            Ok(value) => {
                tracing::debug!(target: "miniflux", "request completed endpoint={} elapsed_ms={}", path, started.elapsed().as_millis());
                Ok(value)
            }
            Err(error) => {
                tracing::warn!(target: "miniflux", "response decoding failed endpoint={} kind={:?} elapsed_ms={}", path, error.kind, started.elapsed().as_millis());
                Err(error)
            }
        }
    }
    fn put(&self, path: &str, body: String) -> Result<(), CoreError> {
        let _request = self
            .request_lock
            .lock()
            .map_err(|_| CoreError::internal("HTTP client lock poisoned"))?;
        let started = Instant::now();
        tracing::debug!(target: "miniflux", "request started endpoint={path}");
        match self
            .agent
            .put(&format!("{}{path}", self.base_url))
            .set("Content-Type", "application/json")
            .set("X-Auth-Token", &self.api_key)
            .send_string(&body)
            .map_err(map_http_error)
        {
            Ok(_) => {
                tracing::debug!(target: "miniflux", "request completed endpoint={} elapsed_ms={}", path, started.elapsed().as_millis());
                Ok(())
            }
            Err(error) => {
                tracing::warn!(target: "miniflux", "request failed endpoint={} kind={:?} elapsed_ms={}", path, error.kind, started.elapsed().as_millis());
                Err(error)
            }
        }
    }
    fn entries(&self, status: Option<&str>, starred: bool) -> Result<Vec<EntryDto>, CoreError> {
        let set = if starred {
            "starred"
        } else {
            status.unwrap_or("all")
        };
        let started = Instant::now();
        tracing::info!(target: "miniflux", "entry fetch started set={set}");
        let mut all = Vec::new();
        let mut after_id = 0;
        loop {
            let mut query = vec![
                ("limit", PAGE_SIZE.to_string()),
                ("order", "id".to_string()),
                ("direction", "asc".to_string()),
            ];
            if let Some(status) = status {
                query.push(("status", status.to_string()));
            }
            if starred {
                query.push(("starred", "1".to_string()));
            }
            if after_id > 0 {
                query.push(("after_entry_id", after_id.to_string()));
            }
            let page: EntriesDto = self.get("/v1/entries", &query)?;
            tracing::debug!(target: "miniflux", "entry page completed set={} entries={} total={} accumulated={} after_entry_id={}", set, page.entries.len(), page.total, all.len(), after_id);
            if page.entries.is_empty() {
                break;
            }
            let mut previous = after_id;
            for entry in &page.entries {
                if entry.id <= previous {
                    return Err(CoreError::data(
                        "Miniflux returned unstable entry pagination",
                    ));
                }
                previous = entry.id;
            }
            after_id = previous;
            all.extend(page.entries);
        }
        tracing::info!(target: "miniflux", "entry fetch completed set={} entries={} elapsed_ms={}", set, all.len(), started.elapsed().as_millis());
        Ok(all)
    }
    fn download_image(&self, url: &str, max_bytes: usize) -> Result<RemoteImage, CoreError> {
        let response = self
            .agent
            .get(url)
            .set("Accept", "image/*")
            .call()
            .map_err(map_image_http_error)?;
        if response
            .header("Content-Length")
            .and_then(|value| value.parse::<usize>().ok())
            .is_some_and(|length| length > max_bytes)
        {
            return Err(CoreError::data("article image exceeds maximum payload"));
        }
        let content_type = response.header("Content-Type").map(str::to_owned);
        let mut reader = response.into_reader().take((max_bytes + 1) as u64);
        let mut bytes = Vec::with_capacity(max_bytes.min(64 * 1024));
        reader.read_to_end(&mut bytes).map_err(|error| {
            CoreError::connectivity(format!("article image download failed: {error}"))
        })?;
        if bytes.len() > max_bytes {
            return Err(CoreError::data("article image exceeds maximum payload"));
        }
        Ok(RemoteImage {
            content_type,
            bytes,
        })
    }
}

impl RemoteSource for MinifluxClient {
    fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, CoreError> {
        let categories: Vec<CategoryDto> = self.get("/v1/categories", &[])?;
        let feeds: Vec<FeedDto> = self.get("/v1/feeds", &[])?;
        let categories = categories
            .into_iter()
            .map(|c| Category {
                id: c.id,
                title: c.title,
            })
            .collect();
        let feeds: Vec<Feed> = feeds
            .into_iter()
            .map(|f| Feed {
                id: f.id,
                category_id: f.category.map(|c| c.id).unwrap_or_default(),
                title: f.title,
            })
            .collect();
        let feed_ids: HashMap<i64, _> = feeds.iter().map(|f| (f.id, ())).collect();
        let mut entries = HashMap::new();
        // Normal sync retains the account-wide unread and starred remote sets. Retention only
        // cleans up articles that were already persisted locally.
        for entry in self
            .entries(Some("unread"), false)?
            .into_iter()
            .chain(self.entries(None, true)?)
        {
            entries.insert(entry.id, entry);
        }
        let mut articles = Vec::with_capacity(entries.len());
        for entry in entries.into_values() {
            if !feed_ids.contains_key(&entry.feed_id) {
                return Err(CoreError::data(format!(
                    "article {} references unknown feed {}",
                    entry.id, entry.feed_id
                )));
            }
            let published = DateTime::parse_from_rfc3339(&entry.published_at).map_err(|_| {
                CoreError::data(format!("article {} has invalid publication time", entry.id))
            })?;
            let enclosures = entry
                .enclosures
                .iter()
                .map(|item| crate::article::EnclosureInput {
                    url: item.url.clone(),
                    mime_type: item.mime_type.clone(),
                })
                .collect::<Vec<_>>();
            let processed = crate::article::process(&entry.content, &entry.url, &enclosures);
            articles.push(Article {
                id: entry.id,
                feed_id: entry.feed_id,
                title: entry.title,
                url: entry.url,
                comments_url: entry.comments_url,
                published_at: published
                    .to_utc()
                    .to_rfc3339_opts(SecondsFormat::Secs, true),
                is_read: entry.status == "read",
                is_starred: entry.starred,
                raw_html_content: entry.content,
                preview: processed.preview,
                image_url: processed.image_url,
            });
        }
        Ok(RemoteSnapshot {
            categories,
            feeds,
            articles,
        })
    }
    fn set_read_state(&self, article_ids: &[i64], read: bool) -> Result<(), CoreError> {
        let ids = article_ids
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(",");
        let status = if read { "read" } else { "unread" };
        self.put(
            "/v1/entries",
            format!(r#"{{"entry_ids":[{ids}],"status":"{status}"}}"#),
        )
    }
    fn set_starred_state(&self, article_id: i64, starred: bool) -> Result<(), CoreError> {
        let entry: EntryDto = self.get(&format!("/v1/entries/{article_id}"), &[])?;
        if entry.starred != starred {
            self.put(&format!("/v1/entries/{article_id}/star"), String::new())
        } else {
            Ok(())
        }
    }
    fn fetch_feed_icon(&self, feed_id: i64) -> Result<Option<String>, CoreError> {
        let icon: IconDto = match self.get(&format!("/v1/feeds/{feed_id}/icon"), &[]) {
            Ok(icon) => icon,
            Err(error) if error.message == "Miniflux returned HTTP 404" => return Ok(None),
            Err(error) => return Err(error),
        };
        Ok(icon.data_url())
    }
    fn fetch_article_image(&self, url: &str, max_bytes: usize) -> Result<RemoteImage, CoreError> {
        self.download_image(url, max_bytes)
    }
}

fn map_http_error(error: ureq::Error) -> CoreError {
    match error {
        ureq::Error::Status(401, _) | ureq::Error::Status(403, _) => {
            CoreError::authentication("Miniflux rejected credentials")
        }
        ureq::Error::Status(status, _) if status == 429 || status >= 500 => {
            CoreError::server_transient(format!("Miniflux server returned HTTP {status}"))
        }
        ureq::Error::Status(status, _) => {
            CoreError::invalid_configuration(format!("Miniflux returned HTTP {status}"))
        }
        other => CoreError::connectivity(format!("Miniflux request failed: {other}")),
    }
}
fn map_image_http_error(error: ureq::Error) -> CoreError {
    match error {
        ureq::Error::Status(status, _) if status == 429 || status >= 500 => {
            CoreError::server_transient(format!("article image server returned HTTP {status}"))
        }
        ureq::Error::Status(status, _) => {
            CoreError::data(format!("article image returned HTTP {status}"))
        }
        other => CoreError::connectivity(format!("article image request failed: {other}")),
    }
}

#[derive(Deserialize)]
struct EntriesDto {
    #[serde(default)]
    total: i64,
    #[serde(default)]
    entries: Vec<EntryDto>,
}
#[derive(Deserialize)]
struct EntryDto {
    id: i64,
    feed_id: i64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
    #[serde(default)]
    comments_url: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    starred: bool,
    published_at: String,
    #[serde(default)]
    content: String,
    #[serde(default)]
    enclosures: Vec<EnclosureDto>,
}
#[derive(Deserialize)]
struct EnclosureDto {
    #[serde(default)]
    url: String,
    #[serde(default)]
    mime_type: String,
}
#[derive(Deserialize)]
struct CategoryDto {
    id: i64,
    #[serde(default)]
    title: String,
}
#[derive(Deserialize)]
struct FeedDto {
    id: i64,
    #[serde(default)]
    title: String,
    category: Option<CategoryRefDto>,
}
#[derive(Deserialize)]
struct CategoryRefDto {
    id: i64,
}
#[derive(Deserialize)]
struct IconDto {
    #[serde(default)]
    data: Option<String>,
    #[serde(default)]
    mime_type: Option<String>,
}
impl IconDto {
    fn data_url(self) -> Option<String> {
        let data = self.data?.trim().to_string();
        if data.is_empty() {
            None
        } else if data.starts_with("data:") {
            Some(data)
        } else if data.starts_with("image/") {
            Some(format!("data:{data}"))
        } else if self
            .mime_type
            .as_deref()
            .is_some_and(|mime| mime.starts_with("image/"))
        {
            Some(format!("data:{};base64,{data}", self.mime_type.unwrap()))
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{SocketAddr, TcpListener};
    use std::thread;

    fn entry_page(total: i64, ids: impl IntoIterator<Item = i64>) -> String {
        let entries = ids
            .into_iter()
            .map(|id| {
                serde_json::json!({
                    "id": id,
                    "feed_id": 1,
                    "published_at": "2026-01-02T03:04:05Z",
                })
            })
            .collect::<Vec<_>>();
        serde_json::json!({ "total": total, "entries": entries }).to_string()
    }

    fn entry_server(
        responses: Vec<(u16, String)>,
    ) -> (SocketAddr, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let mut targets = Vec::new();
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                targets.push(line.split_whitespace().nth(1).unwrap().to_string());
                let mut authenticated = false;
                loop {
                    line.clear();
                    reader.read_line(&mut line).unwrap();
                    if line == "\r\n" {
                        break;
                    }
                    if line
                        .to_ascii_lowercase()
                        .starts_with("x-auth-token: test-key")
                    {
                        authenticated = true;
                    }
                }
                assert!(authenticated);
                write!(stream, "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
            }
            targets
        });
        (address, worker)
    }

    fn unread_entry_targets(after_ids: &[i64]) -> Vec<String> {
        let mut targets =
            vec!["/v1/entries?limit=100&order=id&direction=asc&status=unread".to_string()];
        targets.extend(after_ids.iter().map(|id| {
            format!(
                "/v1/entries?limit=100&order=id&direction=asc&status=unread&after_entry_id={id}"
            )
        }));
        targets
    }

    #[test]
    fn entries_continue_after_decreasing_totals_until_empty_page() {
        let (address, worker) = entry_server(vec![
            (200, entry_page(230, 1..=100)),
            (200, entry_page(130, 101..=200)),
            (200, entry_page(30, 201..=230)),
            (200, entry_page(0, [])),
        ]);
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();

        let entries = client.entries(Some("unread"), false).unwrap();

        assert_eq!(
            entries
                .into_iter()
                .map(|entry| entry.id)
                .collect::<Vec<_>>(),
            (1..=230).collect::<Vec<_>>()
        );
        assert_eq!(
            worker.join().unwrap(),
            unread_entry_targets(&[100, 200, 230])
        );
    }

    #[test]
    fn entries_fetch_empty_page_after_exactly_full_page() {
        let (address, worker) = entry_server(vec![
            (200, entry_page(100, 1..=100)),
            (200, entry_page(0, [])),
        ]);
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();

        let entries = client.entries(Some("unread"), false).unwrap();

        assert_eq!(entries.len(), 100);
        assert_eq!(worker.join().unwrap(), unread_entry_targets(&[100]));
    }

    #[test]
    fn entries_accept_empty_first_page() {
        let (address, worker) = entry_server(vec![(200, entry_page(0, []))]);
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();

        assert!(client.entries(Some("unread"), false).unwrap().is_empty());
        assert_eq!(worker.join().unwrap(), unread_entry_targets(&[]));
    }

    #[test]
    fn entries_reject_unstable_later_page() {
        let (address, worker) = entry_server(vec![
            (200, entry_page(100, 1..=100)),
            (200, entry_page(1, [100])),
        ]);
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();

        let error = match client.entries(Some("unread"), false) {
            Err(error) => error,
            Ok(_) => panic!("unstable entry pagination should fail"),
        };

        assert_eq!(error.kind, crate::domain::CoreErrorKind::Data);
        assert_eq!(error.message, "Miniflux returned unstable entry pagination");
        assert_eq!(worker.join().unwrap(), unread_entry_targets(&[100]));
    }

    #[test]
    fn entries_return_error_when_second_page_fails() {
        let (address, worker) =
            entry_server(vec![(200, entry_page(100, 1..=100)), (500, String::new())]);
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();

        let error = match client.entries(Some("unread"), false) {
            Err(error) => error,
            Ok(_) => panic!("second-page server failure should fail entry fetch"),
        };

        assert_eq!(error.kind, crate::domain::CoreErrorKind::ServerTransient);
        assert_eq!(error.message, "Miniflux server returned HTTP 500");
        assert_eq!(worker.join().unwrap(), unread_entry_targets(&[100]));
    }

    #[test]
    fn fetches_only_unread_and_starred_entries_without_read_history() {
        let responses = vec![
            r#"[{"id":1,"title":"Category"}]"#,
            r#"[{"id":9,"title":"Feed","category":{"id":1}}]"#,
            r#"{"total":1,"entries":[{"id":4,"feed_id":9,"title":"Unread and starred","url":"https://entry/post","status":"unread","starred":true,"published_at":"2026-01-02T03:04:05Z","content":"<p>source &amp; preview</p>","enclosures":[{"url":"audio.mp3","mime_type":"audio/mpeg"},{"url":"/cover.jpg","mime_type":"image/jpeg"}]}]}"#,
            r#"{"total":0,"entries":[]}"#,
            r#"{"total":1,"entries":[{"id":4,"feed_id":9,"title":"Unread and starred","url":"https://entry/post","status":"unread","starred":true,"published_at":"2026-01-02T03:04:05Z","content":"<p>source &amp; preview</p>","enclosures":[{"url":"audio.mp3","mime_type":"audio/mpeg"},{"url":"/cover.jpg","mime_type":"image/jpeg"}]}]}"#,
            r#"{"total":0,"entries":[]}"#,
        ];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let mut targets = Vec::new();
            for body in responses {
                let (mut stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                targets.push(line.split_whitespace().nth(1).unwrap().to_string());
                let mut authenticated = false;
                loop {
                    line.clear();
                    reader.read_line(&mut line).unwrap();
                    if line == "\r\n" {
                        break;
                    }
                    if line
                        .to_ascii_lowercase()
                        .starts_with("x-auth-token: test-key")
                    {
                        authenticated = true;
                    }
                }
                assert!(authenticated);
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
            }
            targets
        });
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();
        let snapshot = client.fetch_initial_articles().unwrap();
        let targets = worker.join().unwrap();
        assert_eq!(
            snapshot.categories,
            vec![Category {
                id: 1,
                title: "Category".into()
            }]
        );
        assert_eq!(
            snapshot.feeds,
            vec![Feed {
                id: 9,
                category_id: 1,
                title: "Feed".into()
            }]
        );
        assert_eq!(snapshot.articles.len(), 1);
        assert_eq!(
            snapshot.articles[0].raw_html_content,
            "<p>source &amp; preview</p>"
        );
        assert_eq!(snapshot.articles[0].preview, "source & preview");
        assert_eq!(
            snapshot.articles[0].image_url.as_deref(),
            Some("https://entry/cover.jpg")
        );
        assert!(!snapshot.articles[0].is_read);
        assert!(snapshot.articles[0].is_starred);
        assert!(
            targets
                .iter()
                .any(|target| target.contains("status=unread"))
        );
        assert!(targets.iter().any(|target| target.contains("starred=1")));
        assert!(!targets.iter().any(|target| target.contains("status=read")));
    }
    #[test]
    fn fetches_feed_icon_data_url() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            while !request.ends_with("\r\n\r\n") {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                request.push_str(&line);
                if line == "\r\n" {
                    break;
                }
            }
            assert!(request.starts_with("GET /v1/feeds/9/icon HTTP/1.1"));
            let body = r#"{"id":9,"data":"image/png;base64,AA==","mime_type":"image/png"}"#;
            write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
        });
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();
        assert_eq!(
            client.fetch_feed_icon(9).unwrap().as_deref(),
            Some("data:image/png;base64,AA==")
        );
        worker.join().unwrap();
    }
    #[test]
    fn treats_missing_feed_icon_as_unavailable() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            assert!(request.starts_with("GET /v1/feeds/9/icon HTTP/1.1"));
            write!(
                stream,
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
        });
        let client = MinifluxClient::new(&format!("http://{address}"), "test-key").unwrap();
        assert_eq!(client.fetch_feed_icon(9).unwrap(), None);
        worker.join().unwrap();
    }
}
