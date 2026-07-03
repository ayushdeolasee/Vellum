//! Webpage sessions: proxy fetching, sidecar annotation storage, and the
//! saved-pages library.
//!
//! Unlike PDFs (where annotations are embedded in the file itself), webpage
//! annotations live in a JSON sidecar in the app data dir, keyed by the
//! normalized page URL. The page itself is served to the frontend through the
//! `vellum-web` custom protocol, which strips framing protections and injects
//! the Vellum content script.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use chrono::Utc;
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;

use crate::models::{Annotation, AnnotationType, CreateAnnotationInput, UpdateAnnotationInput};

const DEFAULT_HIGHLIGHT_COLOR: &str = "#fef08a";
const DEFAULT_NOTE_COLOR: &str = "#fde68a";
pub(crate) const MAX_RESPONSE_BYTES: usize = 25 * 1024 * 1024;
const FETCH_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
     AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 Vellum/0.1";

/// The content script injected into every proxied page.
pub const CONTENT_SCRIPT: &str = include_str!("../assets/vellum-content-script.js");

/// Session state for an open webpage tab.
pub struct WebSession {
    /// Normalized page URL (this is the document identity).
    pub url: String,
    /// Path to the JSON sidecar holding metadata + annotations.
    pub record_path: PathBuf,
    /// Path to the offline HTML snapshot (may not exist).
    pub snapshot_path: PathBuf,
}

/// Sidecar record persisted per webpage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebPageRecord {
    pub url: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub page_count: Option<u32>,
    #[serde(default)]
    pub last_page: Option<u32>,
    #[serde(default)]
    pub saved: bool,
    #[serde(default)]
    pub saved_at: Option<String>,
    #[serde(default)]
    pub opened_at: Option<String>,
    /// "live-first" (default when None) or "snapshot-only" (pinned snapshot,
    /// set when importing a .vellumweb archive that requests it).
    #[serde(default)]
    pub loading_policy: Option<String>,
    #[serde(default)]
    pub annotations: Vec<Annotation>,
}

impl WebPageRecord {
    fn new(url: &str) -> Self {
        WebPageRecord {
            url: url.to_string(),
            title: None,
            page_count: None,
            last_page: None,
            saved: false,
            saved_at: None,
            opened_at: None,
            loading_policy: None,
            annotations: Vec::new(),
        }
    }
}

/// Entry returned for the saved-pages library.
#[derive(Debug, Serialize)]
pub struct WebLibraryEntry {
    pub url: String,
    pub title: Option<String>,
    pub page_count: Option<u32>,
    pub saved_at: Option<String>,
    pub has_snapshot: bool,
}

// ---------------------------------------------------------------------------
// URL normalization & storage paths
// ---------------------------------------------------------------------------

fn is_tracking_param(key: &str) -> bool {
    key.starts_with("utm_")
        || matches!(
            key,
            "fbclid" | "gclid" | "igshid" | "mc_cid" | "mc_eid" | "ref_src" | "twclid"
        )
}

/// Normalize a user-supplied URL: default to https, strip fragments and
/// tracking params so the same article always maps to one record.
pub fn normalize_url(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("Empty URL".to_string());
    }
    let candidate = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{}", trimmed)
    };

    let mut url = Url::parse(&candidate).map_err(|e| format!("Invalid URL: {}", e))?;
    match url.scheme() {
        "http" | "https" => {}
        other => return Err(format!("Unsupported URL scheme: {}", other)),
    }
    if url.host_str().is_none() {
        return Err("URL has no host".to_string());
    }

    url.set_fragment(None);
    let kept: Vec<(String, String)> = url
        .query_pairs()
        .filter(|(k, _)| !is_tracking_param(k))
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    if kept.is_empty() {
        url.set_query(None);
    } else {
        url.query_pairs_mut().clear().extend_pairs(kept);
    }

    Ok(url.to_string())
}

/// Stable storage key for a normalized URL.
pub fn page_key(normalized_url: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(normalized_url.as_bytes());
    let digest = hasher.finalize();
    digest.iter().map(|b| format!("{:02x}", b)).collect()
}

pub fn store_dir(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("web")
}

fn record_path(app_data_dir: &Path, key: &str) -> PathBuf {
    store_dir(app_data_dir).join(format!("{}.json", key))
}

fn snapshot_path(app_data_dir: &Path, key: &str) -> PathBuf {
    store_dir(app_data_dir).join(format!("{}.snapshot.html", key))
}

/// Managed library path for a page's `.vellumweb` archive. Opening a page
/// writes here by default, so the library is a collection of portable
/// archives rather than loose snapshot files.
pub fn managed_archive_path(app_data_dir: &Path, key: &str) -> PathBuf {
    store_dir(app_data_dir).join(format!("{}.vellumweb", key))
}

// ---------------------------------------------------------------------------
// Record persistence
// ---------------------------------------------------------------------------

pub fn load_record(path: &Path) -> Option<WebPageRecord> {
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn save_record(path: &Path, record: &WebPageRecord) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create web store dir: {}", e))?;
    }
    let json = serde_json::to_string_pretty(record)
        .map_err(|e| format!("Failed to serialize webpage record: {}", e))?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, json).map_err(|e| format!("Failed to write webpage record: {}", e))?;
    fs::rename(&tmp, path).map_err(|e| format!("Failed to commit webpage record: {}", e))?;
    Ok(())
}

/// Open (or create) a webpage session for a raw URL.
pub fn open_session(app_data_dir: &Path, raw_url: &str) -> Result<(WebSession, WebPageRecord), String> {
    let url = normalize_url(raw_url)?;
    let key = page_key(&url);
    let session = WebSession {
        url: url.clone(),
        record_path: record_path(app_data_dir, &key),
        snapshot_path: snapshot_path(app_data_dir, &key),
    };

    let mut record = load_record(&session.record_path).unwrap_or_else(|| WebPageRecord::new(&url));
    record.url = url;
    record.opened_at = Some(Utc::now().to_rfc3339());
    save_record(&session.record_path, &record)?;
    Ok((session, record))
}

fn with_record<T>(
    session: &WebSession,
    f: impl FnOnce(&mut WebPageRecord) -> T,
) -> Result<T, String> {
    let mut record =
        load_record(&session.record_path).unwrap_or_else(|| WebPageRecord::new(&session.url));
    let out = f(&mut record);
    save_record(&session.record_path, &record)?;
    Ok(out)
}

// ---------------------------------------------------------------------------
// Annotation CRUD (mirrors the pdf_annotations command surface)
// ---------------------------------------------------------------------------

pub fn get_annotations(
    session: &WebSession,
    page_number: Option<u32>,
) -> Result<Vec<Annotation>, String> {
    let record =
        load_record(&session.record_path).unwrap_or_else(|| WebPageRecord::new(&session.url));
    Ok(record
        .annotations
        .into_iter()
        .filter(|a| page_number.map(|p| a.page_number == p).unwrap_or(true))
        .collect())
}

pub fn create_annotation(
    session: &WebSession,
    input: &CreateAnnotationInput,
) -> Result<Annotation, String> {
    let now = Utc::now().to_rfc3339();
    let default_color = match input.annotation_type {
        AnnotationType::Highlight => Some(DEFAULT_HIGHLIGHT_COLOR.to_string()),
        AnnotationType::Note => Some(DEFAULT_NOTE_COLOR.to_string()),
        AnnotationType::Bookmark => None,
    };
    let annotation = Annotation {
        id: Uuid::new_v4().to_string(),
        annotation_type: input.annotation_type.clone(),
        page_number: input.page_number,
        color: input.color.clone().or(default_color),
        content: input.content.clone(),
        position_data: input.position_data.clone(),
        created_at: now.clone(),
        updated_at: now,
    };
    let stored = annotation.clone();
    with_record(session, move |record| record.annotations.push(stored))?;
    Ok(annotation)
}

pub fn update_annotation(
    session: &WebSession,
    input: &UpdateAnnotationInput,
) -> Result<bool, String> {
    with_record(session, |record| {
        let Some(annotation) = record.annotations.iter_mut().find(|a| a.id == input.id) else {
            return false;
        };
        if let Some(color) = &input.color {
            annotation.color = Some(color.clone());
        }
        if let Some(content) = &input.content {
            annotation.content = Some(content.clone());
        }
        if let Some(position_data) = &input.position_data {
            annotation.position_data = Some(position_data.clone());
        }
        annotation.updated_at = Utc::now().to_rfc3339();
        true
    })
}

pub fn delete_annotation(session: &WebSession, id: &str) -> Result<bool, String> {
    with_record(session, |record| {
        let before = record.annotations.len();
        record.annotations.retain(|a| a.id != id);
        record.annotations.len() != before
    })
}

pub fn set_metadata(session: &WebSession, key: &str, value: &str) -> Result<(), String> {
    with_record(session, |record| match key {
        "title" => {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                record.title = Some(trimmed.to_string());
            }
        }
        "page_count" => record.page_count = value.parse().ok(),
        "last_page" => record.last_page = value.parse().ok(),
        _ => {}
    })
}

pub fn document_info(record: &WebPageRecord) -> (Option<String>, Option<u32>, Option<u32>) {
    (record.title.clone(), record.page_count, record.last_page)
}

// ---------------------------------------------------------------------------
// Saved-pages library
// ---------------------------------------------------------------------------

pub fn set_saved(session: &WebSession, saved: bool) -> Result<(), String> {
    with_record(session, |record| {
        record.saved = saved;
        record.saved_at = if saved {
            Some(Utc::now().to_rfc3339())
        } else {
            None
        };
    })?;
    if !saved {
        remove_local_snapshots(app_data_dir_of(&session.record_path), &page_key(&session.url));
        let _ = fs::remove_file(&session.snapshot_path);
    }
    Ok(())
}

/// Recover the app data dir from a record path (`<app_data>/web/<key>.json`).
fn app_data_dir_of(record_path: &Path) -> PathBuf {
    record_path
        .parent()
        .and_then(|web_dir| web_dir.parent())
        .map(|dir| dir.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."))
}

/// Delete all locally cached snapshot artifacts for a page.
fn remove_local_snapshots(app_data_dir: PathBuf, key: &str) {
    let _ = fs::remove_file(snapshot_path(&app_data_dir, key));
    let _ = fs::remove_file(managed_archive_path(&app_data_dir, key));
    let _ = fs::remove_dir_all(store_dir(&app_data_dir).join("archives").join(key));
}

pub fn is_saved(session: &WebSession) -> bool {
    load_record(&session.record_path)
        .map(|r| r.saved)
        .unwrap_or(false)
}

/// Mark a page saved without disturbing an existing `saved_at`. Used by the
/// automatic on-open archiver so opened pages land in the library.
pub fn mark_saved_if_absent(record_path: &Path, url: &str) -> Result<(), String> {
    let mut record = load_record(record_path).unwrap_or_else(|| WebPageRecord::new(url));
    record.url = url.to_string();
    record.saved = true;
    if record.saved_at.is_none() {
        record.saved_at = Some(Utc::now().to_rfc3339());
    }
    save_record(record_path, &record)
}

fn has_local_snapshot(app_data_dir: &Path, key: &str) -> bool {
    snapshot_path(app_data_dir, key).is_file()
        || managed_archive_path(app_data_dir, key).is_file()
        || store_dir(app_data_dir)
            .join("archives")
            .join(key)
            .join("snapshot.html")
            .is_file()
}

pub fn list_saved(app_data_dir: &Path) -> Vec<WebLibraryEntry> {
    let dir = store_dir(app_data_dir);
    let Ok(entries) = fs::read_dir(&dir) else {
        return Vec::new();
    };

    let mut out: Vec<WebLibraryEntry> = entries
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                return None;
            }
            let record = load_record(&path)?;
            if !record.saved {
                return None;
            }
            let key = page_key(&record.url);
            Some(WebLibraryEntry {
                has_snapshot: has_local_snapshot(app_data_dir, &key),
                url: record.url,
                title: record.title,
                page_count: record.page_count,
                saved_at: record.saved_at,
            })
        })
        .collect();

    out.sort_by(|a, b| b.saved_at.cmp(&a.saved_at));
    out
}

pub fn remove_saved(app_data_dir: &Path, raw_url: &str) -> Result<(), String> {
    let url = normalize_url(raw_url)?;
    let key = page_key(&url);
    let path = record_path(app_data_dir, &key);
    // Un-save (keep annotations in case the page is reopened later).
    if let Some(mut record) = load_record(&path) {
        record.saved = false;
        record.saved_at = None;
        save_record(&path, &record)?;
    }
    remove_local_snapshots(app_data_dir.to_path_buf(), &key);
    Ok(())
}

// ---------------------------------------------------------------------------
// Proxy: fetch + rewrite
// ---------------------------------------------------------------------------

pub enum FetchedPage {
    Html {
        html: String,
        /// URL after redirects — may differ from the requested URL (http →
        /// https, moved articles). Callers should treat this as the page's
        /// effective identity.
        final_url: String,
    },
    Other {
        content_type: String,
        body: Vec<u8>,
    },
}

/// Shared HTTP client configuration for page and asset fetches.
pub fn http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(FETCH_USER_AGENT)
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {}", e))
}

/// Read a response body with the size cap enforced *while* streaming, so a
/// missing/false Content-Length or a decompression bomb can't exhaust memory
/// before a post-hoc check.
pub async fn read_body_capped(
    mut response: reqwest::Response,
    cap: usize,
) -> Result<Vec<u8>, String> {
    if let Some(len) = response.content_length() {
        if len > cap as u64 {
            return Err("Response is too large to load".to_string());
        }
    }
    let mut body: Vec<u8> = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| format!("Failed to read response body: {}", e))?
    {
        if body.len() + chunk.len() > cap {
            return Err("Response is too large to load".to_string());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Decode HTML bytes honoring the charset from the Content-Type header
/// (falling back to UTF-8), mirroring what `Response::text()` would do.
fn decode_html(body: &[u8], content_type: &str) -> String {
    let charset = content_type
        .split(';')
        .filter_map(|part| part.trim().strip_prefix("charset="))
        .next()
        .map(|c| c.trim_matches('"').trim())
        .unwrap_or("utf-8");
    let encoding =
        encoding_rs::Encoding::for_label(charset.as_bytes()).unwrap_or(encoding_rs::UTF_8);
    let (text, _, _) = encoding.decode(body);
    text.into_owned()
}

/// Write a snapshot file atomically (temp + rename) so concurrent readers
/// never observe a torn file.
pub fn write_snapshot_atomic(path: &Path, html: &str) {
    let tmp = path.with_extension(format!("tmp-{}", Uuid::new_v4()));
    if fs::write(&tmp, html).is_ok() && fs::rename(&tmp, path).is_err() {
        let _ = fs::remove_file(&tmp);
    }
}

pub async fn fetch_page(url: &str) -> Result<FetchedPage, String> {
    let client = http_client()?;

    let response = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("Failed to fetch page: {}", e))?;

    let status = response.status();
    if !status.is_success() {
        return Err(format!("The server responded with HTTP {}", status.as_u16()));
    }

    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("text/html")
        .to_string();

    if content_type.contains("text/html") || content_type.contains("application/xhtml") {
        let final_url = response.url().to_string();
        let body = read_body_capped(response, MAX_RESPONSE_BYTES).await?;
        Ok(FetchedPage::Html {
            html: decode_html(&body, &content_type),
            final_url,
        })
    } else {
        let body = read_body_capped(response, MAX_RESPONSE_BYTES).await?;
        Ok(FetchedPage::Other { content_type, body })
    }
}

fn csp_meta_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        RegexBuilder::new(r#"<meta[^>]+http-equiv\s*=\s*["']?content-security-policy["']?[^>]*>"#)
            .case_insensitive(true)
            .build()
            .expect("valid CSP meta regex")
    })
}

fn refresh_meta_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        RegexBuilder::new(r#"<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*>"#)
            .case_insensitive(true)
            .build()
            .expect("valid refresh meta regex")
    })
}

fn head_open_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        RegexBuilder::new(r"<head[^>]*>")
            .case_insensitive(true)
            .build()
            .expect("valid head regex")
    })
}

fn html_open_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        RegexBuilder::new(r"<html[^>]*>")
            .case_insensitive(true)
            .build()
            .expect("valid html regex")
    })
}

/// Rewrite fetched HTML for serving inside the Vellum iframe:
/// - strip `<meta http-equiv="Content-Security-Policy">` tags (headers are
///   already dropped because we build a fresh response),
/// - inject `<base href>` so relative subresources resolve against the real
///   origin,
/// - inject the Vellum content script with the normalized page URL.
pub fn prepare_html(html: &str, page_url: &str, offline_snapshot: bool) -> String {
    let stripped = csp_meta_regex().replace_all(html, "");
    // Meta refresh would navigate the iframe straight to the target site,
    // escaping the proxy (no content script, likely frame-blocked).
    let stripped = refresh_meta_regex().replace_all(&stripped, "");

    let safe_url_attr = page_url.replace('"', "%22");
    let url_json = serde_json::to_string(page_url).unwrap_or_else(|_| "\"\"".to_string());
    let injection = format!(
        "<base href=\"{}\"><script>window.__VELLUM_PAGE_URL__={};window.__VELLUM_OFFLINE__={};\n{}</script>",
        safe_url_attr, url_json, offline_snapshot, CONTENT_SCRIPT
    );

    if let Some(m) = head_open_regex().find(&stripped) {
        let mut out = String::with_capacity(stripped.len() + injection.len());
        out.push_str(&stripped[..m.end()]);
        out.push_str(&injection);
        out.push_str(&stripped[m.end()..]);
        return out;
    }
    if let Some(m) = html_open_regex().find(&stripped) {
        let mut out = String::with_capacity(stripped.len() + injection.len());
        out.push_str(&stripped[..m.end()]);
        out.push_str("<head>");
        out.push_str(&injection);
        out.push_str("</head>");
        out.push_str(&stripped[m.end()..]);
        return out;
    }
    format!("{}{}", injection, stripped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_url_defaults_to_https_and_strips_tracking() {
        let url = normalize_url("example.com/post?utm_source=x&id=7#section").unwrap();
        assert_eq!(url, "https://example.com/post?id=7");
    }

    #[test]
    fn normalize_url_rejects_non_http_schemes() {
        assert!(normalize_url("file:///etc/passwd").is_err());
        assert!(normalize_url("javascript:alert(1)").is_err());
    }

    #[test]
    fn same_article_maps_to_one_key() {
        let a = normalize_url("https://example.com/post?utm_campaign=a").unwrap();
        let b = normalize_url("example.com/post").unwrap();
        assert_eq!(page_key(&a), page_key(&b));
    }

    #[test]
    fn prepare_html_injects_base_and_script_after_head() {
        let html = "<!doctype html><html><head><title>T</title></head><body>hi</body></html>";
        let out = prepare_html(html, "https://example.com/post", false);
        let head_pos = out.find("<head>").unwrap();
        let base_pos = out.find("<base href=\"https://example.com/post\">").unwrap();
        let title_pos = out.find("<title>").unwrap();
        assert!(head_pos < base_pos && base_pos < title_pos);
        assert!(out.contains("__VELLUM_PAGE_URL__"));
        assert!(out.contains("vellumCmd"));
    }

    #[test]
    fn prepare_html_strips_meta_csp() {
        let html = r#"<html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'"></head><body></body></html>"#;
        let out = prepare_html(html, "https://example.com", false);
        assert!(!out.to_lowercase().contains("content-security-policy"));
    }

    #[test]
    fn prepare_html_strips_meta_refresh() {
        let html = r#"<html><head><META HTTP-EQUIV="Refresh" content="0; url=https://evil.example/out"></head><body>stay</body></html>"#;
        let out = prepare_html(html, "https://example.com", false);
        assert!(!out.to_lowercase().contains("http-equiv=\"refresh\""));
        assert!(!out.contains("evil.example"));
        assert!(out.contains("stay"));
    }

    #[test]
    fn prepare_html_handles_headless_documents() {
        let out = prepare_html("<p>bare fragment</p>", "https://example.com", false);
        assert!(out.contains("__VELLUM_PAGE_URL__"));
        assert!(out.contains("bare fragment"));
    }
}

/// Simple error page, also run through `prepare_html` so the content script
/// still reports to the app shell.
pub fn error_page(url: &str, message: &str) -> String {
    let esc = |s: &str| {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    };
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><title>Couldn't load page</title></head>
<body style="font-family: -apple-system, system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1.5rem; color: #333;">
<h1 style="font-size: 1.25rem;">Couldn't load this page</h1>
<p style="color:#666; word-break: break-all;">{}</p>
<p>{}</p>
<p style="color:#666;">Check the URL and your network connection, then reload the tab.</p>
</body></html>"#,
        esc(url),
        esc(message)
    )
}
