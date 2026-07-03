//! `.vellumweb` — portable, versioned ZIP archive for annotated webpages.
//!
//! Layout (all paths inside the ZIP):
//!   manifest.json           format marker, URLs, capture time, hashes, policy
//!   snapshot/index.html     sanitized, self-contained snapshot (scripts
//!                           stripped, asset refs rewritten to
//!                           `__VELLUM_ASSET__/<name>` placeholders)
//!   snapshot/assets/<name>  captured subresources (images, stylesheets)
//!   text/pages.json         extracted normalized text per virtual page
//!   annotations.json        highlights/notes/bookmarks with text-quote anchors
//!
//! This is an import/export & archival format. The live source of truth stays
//! the per-URL JSON sidecar; importing merges into it, exporting reads from it.
//!
//! Size strategy: text entries use Zopfli deflate when small enough (levels
//! 10+ with the `deflate-zopfli` feature), flate2 level 9 otherwise;
//! already-compressed media (jpg/png/webp/woff2/...) is Stored rather than
//! recompressed; scripts, srcset variants, and preload hints are stripped
//! from the snapshot before packing.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::models::Annotation;
use crate::web_page;

pub const FORMAT_NAME: &str = "vellumweb";
pub const FORMAT_VERSION: u32 = 1;

const MAX_ASSETS: usize = 80;
const MAX_ASSET_BYTES: usize = 8 * 1024 * 1024;
const MAX_TOTAL_ASSET_BYTES: usize = 64 * 1024 * 1024;
/// Deflate levels 10-264 select Zopfli (iteration count) in the zip crate;
/// worth it for small text entries, too slow for megabyte-scale HTML.
const ZOPFLI_LEVEL: i64 = 15;
const ZOPFLI_MAX_BYTES: usize = 384 * 1024;
const FLATE_LEVEL: i64 = 9;

const ASSET_PLACEHOLDER: &str = "__VELLUM_ASSET__";

// ---------------------------------------------------------------------------
// Manifest
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestHashes {
    /// "sha256:<hex>" of snapshot/index.html bytes.
    pub snapshot_html: String,
    /// "sha256:<hex>" of text/pages.json bytes.
    pub page_text: String,
    /// "sha256:<hex>" of annotations.json bytes (added in later exports;
    /// verified on import when present).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ManifestAsset {
    pub path: String,
    pub url: String,
    pub content_type: String,
    pub bytes: u64,
    /// "sha256:<hex>" of the asset bytes (verified on import when present).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchiveManifest {
    pub format: String,
    pub version: u32,
    pub url: String,
    pub canonical_url: String,
    pub title: Option<String>,
    pub captured_at: String,
    pub generator: String,
    /// "live-first" (default) or "snapshot-only".
    pub loading_policy: String,
    pub page_count: Option<u32>,
    pub last_page: Option<u32>,
    pub hashes: ManifestHashes,
    #[serde(default)]
    pub assets: Vec<ManifestAsset>,
    #[serde(default)]
    pub assets_skipped: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageText {
    pub number: u32,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExportSummary {
    pub path: String,
    pub bytes: u64,
    pub asset_count: u32,
    pub assets_skipped: u32,
}

pub struct CapturedAsset {
    pub name: String,
    pub url: String,
    pub content_type: String,
    pub bytes: Vec<u8>,
}

pub struct CapturedSnapshot {
    pub html: String,
    pub assets: Vec<CapturedAsset>,
    pub skipped: u32,
}

pub struct ImportedArchive {
    pub manifest: ArchiveManifest,
    pub snapshot_html: String,
    pub assets: Vec<(String, Vec<u8>)>,
    pub annotations: Vec<Annotation>,
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    format!("sha256:{}", hex)
}

// ---------------------------------------------------------------------------
// Snapshot sanitizing & asset capture
// ---------------------------------------------------------------------------

fn re(pattern: &str, cell: &'static OnceLock<Regex>) -> &'static Regex {
    cell.get_or_init(|| {
        RegexBuilder::new(pattern)
            .case_insensitive(true)
            .dot_matches_new_line(true)
            .build()
            .expect("valid archive regex")
    })
}

fn script_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(r"<script\b[^>]*>.*?</script\s*>|<script\b[^>]*/>", &RE)
}

fn preload_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(
        r#"<link\b[^>]*rel\s*=\s*["']?(?:preload|prefetch|modulepreload|dns-prefetch|preconnect)["']?[^>]*>"#,
        &RE,
    )
}

fn attr_strip_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(
        r#"\s(?:srcset|sizes|integrity|crossorigin)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
        &RE,
    )
}

fn img_src_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(r#"<img\b[^>]*?\ssrc\s*=\s*["']([^"']+)["']"#, &RE)
}

fn link_tag_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(r"<link\b[^>]*>", &RE)
}

fn href_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(r#"\bhref\s*=\s*["']([^"']+)["']"#, &RE)
}

fn stylesheet_rel_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(r#"\brel\s*=\s*["']?stylesheet["']?"#, &RE)
}

fn css_url_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    re(r#"url\(\s*['"]?([^'")]+)['"]?\s*\)|@import\s+['"]([^'"]+)['"]"#, &RE)
}

/// Strip scripts, preload hints, and per-response attributes (srcset/sizes/
/// integrity/crossorigin) that either bloat the archive or break once assets
/// are served locally.
pub fn sanitize_snapshot_html(html: &str) -> String {
    let out = script_re().replace_all(html, "");
    let out = preload_re().replace_all(&out, "");
    let out = attr_strip_re().replace_all(&out, "");
    out.into_owned()
}

/// Collect capturable asset URLs (img src + stylesheet href), in document
/// order, deduplicated, resolved against the page URL.
fn collect_asset_urls(html: &str, page_url: &str) -> Vec<(String, String)> {
    let base = match Url::parse(page_url) {
        Ok(u) => u,
        Err(_) => return Vec::new(),
    };
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<(String, String)> = Vec::new(); // (raw attr value, absolute url)

    let mut push = |raw: &str| {
        let raw = raw.trim();
        if raw.is_empty() || raw.starts_with("data:") || raw.starts_with('#') {
            return;
        }
        let Ok(abs) = base.join(raw) else { return };
        match abs.scheme() {
            "http" | "https" => {}
            _ => return,
        }
        if seen.insert(raw.to_string()) {
            out.push((raw.to_string(), abs.to_string()));
        }
    };

    for cap in img_src_re().captures_iter(html) {
        if let Some(m) = cap.get(1) {
            push(m.as_str());
        }
    }
    for tag in link_tag_re().find_iter(html) {
        let tag_str = tag.as_str();
        if !stylesheet_rel_re().is_match(tag_str) {
            continue;
        }
        if let Some(cap) = href_re().captures(tag_str) {
            if let Some(m) = cap.get(1) {
                push(m.as_str());
            }
        }
    }
    out
}

/// Rewrite `url(...)` / `@import` references inside captured CSS to absolute
/// URLs so they still resolve when the stylesheet is served from the archive.
/// (Nested CSS assets are not embedded; see format limitations.)
fn absolutize_css(css: &str, css_url: &str) -> String {
    let Ok(base) = Url::parse(css_url) else {
        return css.to_string();
    };
    css_url_re()
        .replace_all(css, |caps: &regex::Captures| {
            let whole = caps.get(0).map(|m| m.as_str()).unwrap_or("");
            let reference = caps
                .get(1)
                .or_else(|| caps.get(2))
                .map(|m| m.as_str().trim())
                .unwrap_or("");
            if reference.is_empty()
                || reference.starts_with("data:")
                || reference.starts_with('#')
            {
                return whole.to_string();
            }
            match base.join(reference) {
                Ok(abs) if matches!(abs.scheme(), "http" | "https") => {
                    if whole.to_ascii_lowercase().starts_with("@import") {
                        format!("@import \"{}\"", abs)
                    } else {
                        format!("url(\"{}\")", abs)
                    }
                }
                _ => whole.to_string(),
            }
        })
        .into_owned()
}

fn extension_for(content_type: &str, url: &str) -> &'static str {
    let ct = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    match ct.as_str() {
        "text/css" => return "css",
        "image/png" => return "png",
        "image/jpeg" | "image/jpg" => return "jpg",
        "image/gif" => return "gif",
        "image/webp" => return "webp",
        "image/avif" => return "avif",
        "image/svg+xml" => return "svg",
        "image/x-icon" | "image/vnd.microsoft.icon" => return "ico",
        "font/woff2" => return "woff2",
        "font/woff" | "application/font-woff" => return "woff",
        "font/ttf" => return "ttf",
        "font/otf" => return "otf",
        _ => {}
    }
    let path_ext = Url::parse(url)
        .ok()
        .and_then(|u| {
            Path::new(u.path())
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_ascii_lowercase())
        })
        .unwrap_or_default();
    match path_ext.as_str() {
        "css" => "css",
        "png" => "png",
        "jpg" | "jpeg" => "jpg",
        "gif" => "gif",
        "webp" => "webp",
        "avif" => "avif",
        "svg" => "svg",
        "ico" => "ico",
        "woff2" => "woff2",
        "woff" => "woff",
        "ttf" => "ttf",
        "otf" => "otf",
        _ => "bin",
    }
}

pub fn content_type_for_name(name: &str) -> &'static str {
    let ext = Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "css" => "text/css",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "svg" => "image/svg+xml",
        "ico" => "image/x-icon",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "html" => "text/html; charset=utf-8",
        _ => "application/octet-stream",
    }
}

/// Media whose container is already compressed: recompressing wastes CPU and
/// can slightly grow the archive, so these are Stored.
fn is_precompressed(name: &str) -> bool {
    matches!(
        Path::new(name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str(),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "avif" | "woff" | "woff2"
    )
}

/// Sanitize + capture subresources for a fetched page. Asset references in
/// the returned HTML point at `__VELLUM_ASSET__/<name>` placeholders.
pub async fn capture_snapshot(page_url: &str, raw_html: &str) -> Result<CapturedSnapshot, String> {
    let mut html = sanitize_snapshot_html(raw_html);
    let targets = collect_asset_urls(&html, page_url);

    let client = web_page::http_client()?;
    let mut assets: Vec<CapturedAsset> = Vec::new();
    let mut skipped: u32 = 0;
    let mut total_bytes: usize = 0;

    for (raw_ref, abs_url) in targets {
        if assets.len() >= MAX_ASSETS || total_bytes >= MAX_TOTAL_ASSET_BYTES {
            skipped += 1;
            continue;
        }

        let fetched = async {
            let resp = client.get(&abs_url).send().await.ok()?;
            if !resp.status().is_success() {
                return None;
            }
            let content_type = resp
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("application/octet-stream")
                .to_string();
            // Cap enforced while streaming so an unbounded or lying origin
            // can't exhaust memory before a post-hoc check.
            let bytes = web_page::read_body_capped(resp, MAX_ASSET_BYTES).await.ok()?;
            Some((content_type, bytes))
        }
        .await;

        let Some((content_type, mut bytes)) = fetched else {
            skipped += 1;
            continue;
        };

        let ext = extension_for(&content_type, &abs_url);
        if ext == "css" {
            let css = String::from_utf8_lossy(&bytes);
            bytes = absolutize_css(&css, &abs_url).into_bytes();
        }

        let name = format!("a{}.{}", assets.len(), ext);
        let placeholder = format!("{}/{}", ASSET_PLACEHOLDER, name);
        html = html
            .replace(&format!("\"{}\"", raw_ref), &format!("\"{}\"", placeholder))
            .replace(&format!("'{}'", raw_ref), &format!("'{}'", placeholder));

        total_bytes += bytes.len();
        assets.push(CapturedAsset {
            name,
            url: abs_url,
            content_type,
            bytes,
        });
    }

    Ok(CapturedSnapshot {
        html,
        assets,
        skipped,
    })
}

// ---------------------------------------------------------------------------
// Archive write / read
// ---------------------------------------------------------------------------

fn text_options(len: usize) -> SimpleFileOptions {
    let level = if len <= ZOPFLI_MAX_BYTES {
        ZOPFLI_LEVEL
    } else {
        FLATE_LEVEL
    };
    SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .compression_level(Some(level))
}

fn asset_options(name: &str) -> SimpleFileOptions {
    if is_precompressed(name) {
        SimpleFileOptions::default().compression_method(CompressionMethod::Stored)
    } else {
        SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .compression_level(Some(FLATE_LEVEL))
    }
}

pub fn build_manifest(
    url: &str,
    title: Option<String>,
    page_count: Option<u32>,
    last_page: Option<u32>,
    loading_policy: &str,
    snapshot_html: &str,
    pages_json: &[u8],
    assets: &[CapturedAsset],
    assets_skipped: u32,
) -> ArchiveManifest {
    ArchiveManifest {
        format: FORMAT_NAME.to_string(),
        version: FORMAT_VERSION,
        url: url.to_string(),
        canonical_url: url.to_string(),
        title,
        captured_at: chrono::Utc::now().to_rfc3339(),
        generator: format!("Vellum {}", env!("CARGO_PKG_VERSION")),
        loading_policy: loading_policy.to_string(),
        page_count,
        last_page,
        hashes: ManifestHashes {
            snapshot_html: sha256_hex(snapshot_html.as_bytes()),
            page_text: sha256_hex(pages_json),
            annotations: None, // filled in by write_archive
        },
        assets: assets
            .iter()
            .map(|a| ManifestAsset {
                path: format!("snapshot/assets/{}", a.name),
                url: a.url.clone(),
                content_type: a.content_type.clone(),
                bytes: a.bytes.len() as u64,
                sha256: Some(sha256_hex(&a.bytes)),
            })
            .collect(),
        assets_skipped,
    }
}

/// Write the archive atomically: pack into a temp file next to `dest`, fsync,
/// then rename over the destination.
pub fn write_archive(
    dest: &Path,
    manifest: &ArchiveManifest,
    snapshot_html: &str,
    assets: &[CapturedAsset],
    pages_json: &[u8],
    annotations: &[Annotation],
) -> Result<u64, String> {
    let parent = dest
        .parent()
        .ok_or_else(|| "Destination has no parent directory".to_string())?;
    fs::create_dir_all(parent).map_err(|e| format!("Failed to create destination dir: {}", e))?;

    let file_name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("archive.vellumweb");
    // Unique per operation: concurrent writers to the same destination (e.g.
    // auto-archive racing an explicit export) must not share a temp file.
    let tmp = parent.join(format!(
        ".{}.tmp-{}-{}",
        file_name,
        std::process::id(),
        Uuid::new_v4()
    ));

    let result = (|| -> Result<u64, String> {
        let file = File::create(&tmp).map_err(|e| format!("Failed to create archive: {}", e))?;
        let mut zip = ZipWriter::new(file);
        let err = |e: zip::result::ZipError| format!("Failed to write archive: {}", e);
        let ioerr = |e: std::io::Error| format!("Failed to write archive: {}", e);

        let annotations_json = serde_json::to_vec(annotations)
            .map_err(|e| format!("Failed to serialize annotations: {}", e))?;
        let mut manifest = manifest.clone();
        manifest.hashes.annotations = Some(sha256_hex(&annotations_json));

        let manifest_json = serde_json::to_vec_pretty(&manifest)
            .map_err(|e| format!("Failed to serialize manifest: {}", e))?;
        zip.start_file("manifest.json", text_options(manifest_json.len()))
            .map_err(err)?;
        zip.write_all(&manifest_json).map_err(ioerr)?;

        let html_bytes = snapshot_html.as_bytes();
        zip.start_file("snapshot/index.html", text_options(html_bytes.len()))
            .map_err(err)?;
        zip.write_all(html_bytes).map_err(ioerr)?;

        for asset in assets {
            zip.start_file(
                format!("snapshot/assets/{}", asset.name),
                asset_options(&asset.name),
            )
            .map_err(err)?;
            zip.write_all(&asset.bytes).map_err(ioerr)?;
        }

        zip.start_file("text/pages.json", text_options(pages_json.len()))
            .map_err(err)?;
        zip.write_all(pages_json).map_err(ioerr)?;

        zip.start_file("annotations.json", text_options(annotations_json.len()))
            .map_err(err)?;
        zip.write_all(&annotations_json).map_err(ioerr)?;

        let file = zip.finish().map_err(err)?;
        file.sync_all()
            .map_err(|e| format!("Failed to sync archive: {}", e))?;
        let bytes = file
            .metadata()
            .map_err(|e| format!("Failed to stat archive: {}", e))?
            .len();
        drop(file);

        fs::rename(&tmp, dest).map_err(|e| format!("Failed to move archive into place: {}", e))?;
        Ok(bytes)
    })();

    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// Read one zip entry with a hard decompressed-size cap. `entry.size()` is an
/// attacker-controlled header field in a shared archive, so it must never be
/// trusted for allocation, and decompression must stop at the cap rather than
/// inflate a bomb.
fn read_zip_entry_capped<R: Read + std::io::Seek>(
    zip: &mut ZipArchive<R>,
    name: &str,
    cap: u64,
) -> Result<Vec<u8>, String> {
    let entry = zip
        .by_name(name)
        .map_err(|_| format!("Archive is missing {}", name))?;
    if entry.size() > cap {
        return Err(format!("Archive entry {} exceeds its size limit", name));
    }
    let mut buf = Vec::with_capacity(entry.size().min(cap) as usize);
    let mut limited = entry.take(cap + 1);
    limited
        .read_to_end(&mut buf)
        .map_err(|e| format!("Failed to read {}: {}", name, e))?;
    if buf.len() as u64 > cap {
        return Err(format!("Archive entry {} exceeds its size limit", name));
    }
    Ok(buf)
}

/// Only bare file names are allowed for assets (zip-slip guard).
fn safe_asset_name(name: &str) -> Option<String> {
    if name.is_empty()
        || name.contains("..")
        || name.contains('/')
        || name.contains('\\')
        || name.starts_with('.')
    {
        return None;
    }
    Some(name.to_string())
}

const MAX_MANIFEST_BYTES: u64 = 4 * 1024 * 1024;
const MAX_ANNOTATIONS_BYTES: u64 = 32 * 1024 * 1024;

pub fn read_archive(path: &Path) -> Result<ImportedArchive, String> {
    let file = File::open(path).map_err(|e| format!("Failed to open archive: {}", e))?;
    let mut zip =
        ZipArchive::new(file).map_err(|e| format!("Not a valid .vellumweb archive: {}", e))?;

    let manifest_bytes = read_zip_entry_capped(&mut zip, "manifest.json", MAX_MANIFEST_BYTES)?;
    let manifest: ArchiveManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|e| format!("Invalid archive manifest: {}", e))?;
    if manifest.format != FORMAT_NAME {
        return Err("Not a .vellumweb archive (wrong format marker)".to_string());
    }
    if manifest.version > FORMAT_VERSION {
        return Err(format!(
            "This archive uses format version {} — please update Vellum",
            manifest.version
        ));
    }

    let snapshot_bytes = read_zip_entry_capped(
        &mut zip,
        "snapshot/index.html",
        web_page::MAX_RESPONSE_BYTES as u64,
    )?;
    if sha256_hex(&snapshot_bytes) != manifest.hashes.snapshot_html {
        return Err("Archive snapshot failed its integrity check (corrupted file?)".to_string());
    }
    let snapshot_html = String::from_utf8_lossy(&snapshot_bytes).into_owned();

    let annotations: Vec<Annotation> = if zip.by_name("annotations.json").is_ok() {
        let buf = read_zip_entry_capped(&mut zip, "annotations.json", MAX_ANNOTATIONS_BYTES)?;
        let parsed: Vec<Annotation> = serde_json::from_slice(&buf)
            .map_err(|e| format!("Invalid annotations in archive: {}", e))?;
        if let Some(expected) = &manifest.hashes.annotations {
            if &sha256_hex(&buf) != expected {
                return Err(
                    "Archive annotations failed their integrity check (corrupted file?)"
                        .to_string(),
                );
            }
        }
        parsed
    } else {
        Vec::new()
    };

    let mut asset_names: Vec<String> = Vec::new();
    for i in 0..zip.len() {
        let entry = zip
            .by_index(i)
            .map_err(|e| format!("Failed to scan archive: {}", e))?;
        if let Some(rest) = entry.name().strip_prefix("snapshot/assets/") {
            if let Some(safe) = safe_asset_name(rest) {
                asset_names.push(safe);
            }
        }
    }
    let mut assets = Vec::with_capacity(asset_names.len());
    let mut total_asset_bytes: u64 = 0;
    for name in asset_names {
        let entry_path = format!("snapshot/assets/{}", name);
        let bytes = read_zip_entry_capped(&mut zip, &entry_path, MAX_ASSET_BYTES as u64)?;
        total_asset_bytes += bytes.len() as u64;
        if total_asset_bytes > MAX_TOTAL_ASSET_BYTES as u64 {
            return Err("Archive assets exceed the total size limit".to_string());
        }
        if let Some(expected) = manifest
            .assets
            .iter()
            .find(|a| a.path == entry_path)
            .and_then(|a| a.sha256.as_ref())
        {
            if &sha256_hex(&bytes) != expected {
                return Err(format!(
                    "Archive asset {} failed its integrity check",
                    name
                ));
            }
        }
        assets.push((name, bytes));
    }

    Ok(ImportedArchive {
        manifest,
        snapshot_html,
        assets,
        annotations,
    })
}

// ---------------------------------------------------------------------------
// Local self-contained snapshot dir (archives/<key>/)
// ---------------------------------------------------------------------------

pub fn archive_dir(app_data_dir: &Path, key: &str) -> PathBuf {
    web_page::store_dir(app_data_dir).join("archives").join(key)
}

/// Install snapshot + assets into `archives/<key>/`: staged into a unique
/// sibling dir, then swapped in with rename-aside so a concurrent reader
/// never sees a missing dir for more than the instant between two renames,
/// and a failed install leaves the previous snapshot intact.
pub fn install_archive_dir(
    app_data_dir: &Path,
    key: &str,
    snapshot_html: &str,
    assets: &[(String, Vec<u8>)],
    manifest: Option<&ArchiveManifest>,
) -> Result<(), String> {
    let final_dir = archive_dir(app_data_dir, key);
    let op_id = Uuid::new_v4();
    let staging = final_dir.with_extension(format!("staging-{}", op_id));
    let aside = final_dir.with_extension(format!("old-{}", op_id));

    fs::create_dir_all(staging.join("assets"))
        .map_err(|e| format!("Failed to stage snapshot dir: {}", e))?;
    let staged = (|| -> Result<(), String> {
        fs::write(staging.join("snapshot.html"), snapshot_html)
            .map_err(|e| format!("Failed to write snapshot: {}", e))?;
        for (name, bytes) in assets {
            let Some(safe) = safe_asset_name(name) else {
                continue;
            };
            fs::write(staging.join("assets").join(safe), bytes)
                .map_err(|e| format!("Failed to write asset: {}", e))?;
        }
        if let Some(manifest) = manifest {
            let json = serde_json::to_vec_pretty(manifest)
                .map_err(|e| format!("Failed to serialize manifest: {}", e))?;
            fs::write(staging.join("manifest.json"), json)
                .map_err(|e| format!("Failed to write manifest: {}", e))?;
        }
        Ok(())
    })();
    if let Err(e) = staged {
        let _ = fs::remove_dir_all(&staging);
        return Err(e);
    }

    // Swap: move the current dir aside (not delete), move staging in, then
    // clean up. On failure, restore the previous dir.
    let had_previous = final_dir.exists() && fs::rename(&final_dir, &aside).is_ok();
    match fs::rename(&staging, &final_dir) {
        Ok(()) => {
            if had_previous {
                let _ = fs::remove_dir_all(&aside);
            }
            Ok(())
        }
        Err(e) => {
            if had_previous {
                let _ = fs::rename(&aside, &final_dir);
            }
            let _ = fs::remove_dir_all(&staging);
            Err(format!("Failed to install snapshot dir: {}", e))
        }
    }
}

/// Load a previously installed self-contained snapshot, if present.
pub fn load_archive_dir(
    app_data_dir: &Path,
    key: &str,
) -> Option<(String, Vec<(String, Vec<u8>)>)> {
    let dir = archive_dir(app_data_dir, key);
    let html = fs::read_to_string(dir.join("snapshot.html")).ok()?;
    let mut assets = Vec::new();
    if let Ok(entries) = fs::read_dir(dir.join("assets")) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Ok(bytes) = fs::read(entry.path()) {
                assets.push((name, bytes));
            }
        }
    }
    Some((html, assets))
}

/// Rewrite asset placeholders for serving: `__VELLUM_ASSET__/<name>` becomes
/// an absolute proxy URL under the given base (e.g.
/// `vellum-web://localhost/asset/<key>`).
pub fn resolve_asset_placeholders(html: &str, asset_base: &str) -> String {
    html.replace(
        &format!("{}/", ASSET_PLACEHOLDER),
        &format!("{}/", asset_base.trim_end_matches('/')),
    )
}

/// Merge imported annotations into the sidecar's list. Same-id conflicts keep
/// the newer `updated_at`. Returns how many entries were added or replaced.
pub fn merge_annotations(existing: &mut Vec<Annotation>, incoming: &[Annotation]) -> u32 {
    let mut changed = 0;
    for annotation in incoming {
        match existing.iter_mut().find(|a| a.id == annotation.id) {
            None => {
                existing.push(annotation.clone());
                changed += 1;
            }
            Some(current) => {
                if newer_than(&annotation.updated_at, &current.updated_at) {
                    *current = annotation.clone();
                    changed += 1;
                }
            }
        }
    }
    changed
}

fn newer_than(a: &str, b: &str) -> bool {
    use chrono::DateTime;
    match (
        DateTime::parse_from_rfc3339(a),
        DateTime::parse_from_rfc3339(b),
    ) {
        (Ok(a), Ok(b)) => a > b,
        _ => a > b, // fall back to lexical compare (same generator format)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{AnnotationType, PositionData};

    fn sample_annotation(id: &str, updated_at: &str) -> Annotation {
        Annotation {
            id: id.to_string(),
            annotation_type: AnnotationType::Highlight,
            page_number: 1,
            color: Some("#fef08a".to_string()),
            content: None,
            position_data: Some(PositionData {
                rects: vec![],
                page_width: 1.0,
                page_height: 1.0,
                selected_text: Some("hello world".to_string()),
                start_offset: Some(10),
                end_offset: Some(21),
                prefix: Some("before ".to_string()),
                suffix: Some(" after".to_string()),
                viewport_offset: None,
            }),
            created_at: "2026-07-01T00:00:00Z".to_string(),
            updated_at: updated_at.to_string(),
        }
    }

    #[test]
    fn sanitize_strips_scripts_srcset_and_preloads() {
        let html = r#"<html><head>
            <link rel="preload" href="/x.woff2" as="font">
            <script src="/app.js"></script>
        </head><body>
            <script>alert(1)</script>
            <img src="/a.png" srcset="/a2x.png 2x" sizes="100vw" crossorigin="anonymous">
            <p>keep me</p>
        </body></html>"#;
        let out = sanitize_snapshot_html(html);
        assert!(!out.contains("<script"));
        assert!(!out.contains("alert(1)"));
        assert!(!out.contains("srcset"));
        assert!(!out.contains("preload"));
        assert!(!out.contains("crossorigin"));
        assert!(out.contains("keep me"));
        assert!(out.contains(r#"src="/a.png""#));
    }

    #[test]
    fn collects_img_and_stylesheet_urls() {
        let html = r#"<img src="/pic.png"><link rel="stylesheet" href="style.css">
            <link href="/other.css" rel="stylesheet"><link rel="icon" href="/fav.ico">
            <img src="data:image/png;base64,xxx">"#;
        let urls = collect_asset_urls(html, "https://example.com/post/index.html");
        let absolute: Vec<&str> = urls.iter().map(|(_, abs)| abs.as_str()).collect();
        assert_eq!(
            absolute,
            vec![
                "https://example.com/pic.png",
                "https://example.com/post/style.css",
                "https://example.com/other.css",
            ]
        );
    }

    #[test]
    fn css_urls_are_absolutized() {
        let css = r#"body { background: url("../img/bg.png"); } @import "extra.css";"#;
        let out = absolutize_css(css, "https://example.com/styles/main.css");
        assert!(out.contains(r#"url("https://example.com/img/bg.png")"#));
        assert!(out.contains(r#"@import "https://example.com/styles/extra.css""#));
    }

    #[test]
    fn archive_round_trip_preserves_content_and_verifies_hashes() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("article.vellumweb");

        let html = "<html><head></head><body><p>hello world</p>\
             <img src=\"__VELLUM_ASSET__/a0.png\"></body></html>";
        let assets = vec![CapturedAsset {
            name: "a0.png".to_string(),
            url: "https://example.com/pic.png".to_string(),
            content_type: "image/png".to_string(),
            bytes: vec![0x89, 0x50, 0x4e, 0x47, 1, 2, 3],
        }];
        let pages = vec![PageText {
            number: 1,
            text: "hello world".to_string(),
        }];
        let pages_json = serde_json::to_vec(&pages).unwrap();
        let annotations = vec![sample_annotation("ann-1", "2026-07-02T00:00:00Z")];

        let manifest = build_manifest(
            "https://example.com/post",
            Some("Post".to_string()),
            Some(1),
            Some(1),
            "live-first",
            html,
            &pages_json,
            &assets,
            0,
        );

        let bytes = write_archive(&dest, &manifest, html, &assets, &pages_json, &annotations)
            .expect("write archive");
        assert!(bytes > 0);
        assert!(dest.is_file());

        let imported = read_archive(&dest).expect("read archive");
        assert_eq!(imported.manifest.url, "https://example.com/post");
        assert_eq!(imported.manifest.version, FORMAT_VERSION);
        assert_eq!(imported.snapshot_html, html);
        assert_eq!(imported.assets.len(), 1);
        assert_eq!(imported.assets[0].0, "a0.png");
        assert_eq!(imported.annotations.len(), 1);
        assert_eq!(
            imported.annotations[0]
                .position_data
                .as_ref()
                .unwrap()
                .prefix
                .as_deref(),
            Some("before ")
        );
    }

    #[test]
    fn corrupted_snapshot_fails_integrity_check() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("bad.vellumweb");
        let pages_json = b"[]".to_vec();
        let mut manifest = build_manifest(
            "https://example.com",
            None,
            None,
            None,
            "live-first",
            "<html>real</html>",
            &pages_json,
            &[],
            0,
        );
        manifest.hashes.snapshot_html = "sha256:deadbeef".to_string();
        write_archive(&dest, &manifest, "<html>real</html>", &[], &pages_json, &[]).unwrap();
        let err = match read_archive(&dest) {
            Ok(_) => panic!("corrupted archive was accepted"),
            Err(e) => e,
        };
        assert!(err.contains("integrity"));
    }

    #[test]
    fn merge_prefers_newer_annotations_and_adds_missing() {
        let mut existing = vec![sample_annotation("a", "2026-07-01T00:00:00Z")];
        let incoming = vec![
            sample_annotation("a", "2026-07-02T00:00:00Z"),
            sample_annotation("b", "2026-07-01T00:00:00Z"),
        ];
        let changed = merge_annotations(&mut existing, &incoming);
        assert_eq!(changed, 2);
        assert_eq!(existing.len(), 2);
        assert_eq!(existing[0].updated_at, "2026-07-02T00:00:00Z");

        // Older incoming copy does not clobber the newer local one.
        let changed = merge_annotations(
            &mut existing,
            &[sample_annotation("a", "2026-06-30T00:00:00Z")],
        );
        assert_eq!(changed, 0);
        assert_eq!(existing[0].updated_at, "2026-07-02T00:00:00Z");
    }

    #[test]
    fn asset_placeholders_resolve_to_proxy_urls() {
        let html = r#"<img src="__VELLUM_ASSET__/a0.png">"#;
        let out = resolve_asset_placeholders(html, "vellum-web://localhost/asset/abc123");
        assert_eq!(out, r#"<img src="vellum-web://localhost/asset/abc123/a0.png">"#);
    }

    #[test]
    fn zip_slip_names_are_rejected() {
        assert!(safe_asset_name("../evil.css").is_none());
        assert!(safe_asset_name("a/b.css").is_none());
        assert!(safe_asset_name(".hidden").is_none());
        assert!(safe_asset_name("a0.css").is_some());
    }

    /// Spin up a throwaway local HTTP server for fetch/capture integration
    /// tests. Returns the base URL; the server dies with the thread when the
    /// returned handle is dropped at test end.
    fn spawn_test_server(
        routes: Vec<(&'static str, &'static str, &'static [u8])>,
    ) -> (String, std::sync::Arc<tiny_http::Server>) {
        let server =
            std::sync::Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind test server"));
        let base = format!("http://{}", server.server_addr());
        let routes: Vec<(String, String, Vec<u8>)> = routes
            .into_iter()
            .map(|(p, ct, b)| (p.to_string(), ct.to_string(), b.to_vec()))
            .collect();

        let server_thread = server.clone();
        std::thread::spawn(move || {
            while let Ok(request) = server_thread.recv() {
                let url = request.url().to_string();
                if let Some(target) = url.strip_prefix("/redirect-to") {
                    let location = target.trim_start_matches('/').to_string();
                    let response = tiny_http::Response::empty(302).with_header(
                        tiny_http::Header::from_bytes(&b"Location"[..], format!("/{}", location))
                            .unwrap(),
                    );
                    let _ = request.respond(response);
                    continue;
                }
                match routes.iter().find(|(path, _, _)| *path == url) {
                    Some((_, content_type, body)) => {
                        let response = tiny_http::Response::from_data(body.clone()).with_header(
                            tiny_http::Header::from_bytes(
                                &b"Content-Type"[..],
                                content_type.as_bytes(),
                            )
                            .unwrap(),
                        );
                        let _ = request.respond(response);
                    }
                    None => {
                        let _ = request.respond(tiny_http::Response::empty(404));
                    }
                }
            }
        });

        (base, server)
    }

    #[tokio::test]
    async fn fetch_page_reports_final_url_after_redirect() {
        let (base, _server) = spawn_test_server(vec![(
            "/article",
            "text/html; charset=utf-8",
            b"<html><head></head><body>landed</body></html>",
        )]);

        let fetched = crate::web_page::fetch_page(&format!("{}/redirect-to/article", base))
            .await
            .expect("fetch through redirect");
        match fetched {
            crate::web_page::FetchedPage::Html { html, final_url } => {
                assert!(html.contains("landed"));
                assert!(
                    final_url.ends_with("/article"),
                    "final_url should be the redirect target, got {}",
                    final_url
                );
            }
            _ => panic!("expected HTML"),
        }
    }

    #[tokio::test]
    async fn capture_snapshot_embeds_assets_and_rewrites_refs() {
        let (base, _server) = spawn_test_server(vec![
            ("/style.css", "text/css", b"body { background: url('bg.png'); }".as_slice()),
            ("/pic.png", "image/png", b"\x89PNGfake".as_slice()),
        ]);

        let html = format!(
            r#"<html><head><link rel="stylesheet" href="style.css"><script>tracker()</script></head>
            <body><img src="{}/pic.png" srcset="pic2x.png 2x"><p>content</p></body></html>"#,
            base
        );
        let page_url = format!("{}/post", base);

        let captured = capture_snapshot(&page_url, &html).await.expect("capture");

        assert_eq!(captured.assets.len(), 2);
        assert_eq!(captured.skipped, 0);
        assert!(!captured.html.contains("<script"));
        assert!(!captured.html.contains("srcset"));
        // Both refs rewritten to placeholders (img srcs are collected before
        // stylesheet hrefs, so the png gets a0).
        assert!(captured.html.contains("__VELLUM_ASSET__/a0.png"));
        assert!(captured.html.contains("__VELLUM_ASSET__/a1.css"));
        // Image bytes stored verbatim.
        assert_eq!(captured.assets[0].bytes, b"\x89PNGfake");
        // CSS url() refs absolutized against the stylesheet's own URL.
        let css = String::from_utf8_lossy(&captured.assets[1].bytes).into_owned();
        assert!(
            css.contains(&format!("url(\"{}/bg.png\")", base)),
            "css was: {}",
            css
        );
    }

    #[tokio::test]
    async fn capture_snapshot_skips_unreachable_assets() {
        let (base, _server) = spawn_test_server(vec![]);
        let html = r#"<img src="/missing.png"><p>text</p>"#;
        let captured = capture_snapshot(&format!("{}/post", base), html)
            .await
            .expect("capture");
        assert_eq!(captured.assets.len(), 0);
        assert_eq!(captured.skipped, 1);
        // Unfetched refs keep their original URL (resolved by <base> live).
        assert!(captured.html.contains("/missing.png"));
    }
}
