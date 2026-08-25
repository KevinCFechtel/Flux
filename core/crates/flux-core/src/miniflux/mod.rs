//! Miniflux HTTP adapter. It maps wire data into domain values and never persists it.

use std::collections::HashMap;
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

pub trait RemoteSource: Send + Sync {
    fn fetch_initial_articles(&self) -> Result<RemoteSnapshot, CoreError>;
    fn set_read_state(&self, article_ids: &[i64], read: bool) -> Result<(), CoreError>;
    fn set_starred_state(&self, article_id: i64, starred: bool) -> Result<(), CoreError>;
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
            tracing::debug!(target: "miniflux", "entry page completed set={} entries={} total={}", set, page.entries.len(), page.total);
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
            if all.len() as i64 >= page.total {
                break;
            }
        }
        tracing::info!(target: "miniflux", "entry fetch completed set={} entries={} elapsed_ms={}", set, all.len(), started.elapsed().as_millis());
        Ok(all)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn fetches_only_unread_and_starred_entries_without_read_history() {
        let responses = vec![
            r#"[{"id":1,"title":"Category"}]"#,
            r#"[{"id":9,"title":"Feed","category":{"id":1}}]"#,
            r#"{"total":1,"entries":[{"id":4,"feed_id":9,"title":"Unread and starred","url":"https://entry","status":"unread","starred":true,"published_at":"2026-01-02T03:04:05Z","content":"<p>source</p>"}]}"#,
            r#"{"total":1,"entries":[{"id":4,"feed_id":9,"title":"Unread and starred","url":"https://entry","status":"unread","starred":true,"published_at":"2026-01-02T03:04:05Z","content":"<p>source</p>"}]}"#,
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
        assert_eq!(snapshot.articles[0].raw_html_content, "<p>source</p>");
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
}
