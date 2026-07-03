use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use tauri::ipc::Response;
use tauri::State;

use crate::models::*;
use crate::pdf_annotations;
use crate::pdf_session::{self, PdfSession};
use crate::web_archive;
use crate::web_page::{self, WebLibraryEntry, WebSession};

/// A tab session: either an on-disk PDF or a proxied webpage.
pub enum Session {
    Pdf(PdfSession),
    Web(WebSession),
}

/// Application state holding all open tab sessions.
pub struct AppState {
    pub sessions: Mutex<HashMap<String, Session>>,
}

fn web_store_dir(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    use tauri::Manager;
    app.path()
        .app_data_dir()
        .map_err(|e| format!("Failed to resolve app data dir: {}", e))
}

fn close_session(session: &Session) -> Result<(), String> {
    match session {
        Session::Pdf(pdf) => pdf_session::save_session(pdf),
        // Webpage mutations are written to the sidecar immediately.
        Session::Web(_) => Ok(()),
    }
}

/// Open a PDF without creating a custom document container.
#[tauri::command]
pub fn open_file(
    path: String,
    session_id: String,
    state: State<AppState>,
) -> Result<DocumentInfo, String> {
    let path = PathBuf::from(&path);
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    let session = match ext.as_str() {
        "pdf" => pdf_session::open_pdf(&path)?,
        _ => return Err(format!("Unsupported file type: .{}", ext)),
    };

    let pdf_path = session.pdf_path().to_string_lossy().to_string();
    let (title, page_count, last_page) = pdf_annotations::document_info(&session.pdf_path)?;

    let info = DocumentInfo {
        kind: "pdf".to_string(),
        pdf_path,
        title,
        page_count: Some(page_count),
        last_page,
    };

    let mut sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = sessions.remove(&session_id) {
        close_session(&prev)?;
    }
    sessions.insert(session_id, Session::Pdf(session));

    Ok(info)
}

/// Open a webpage as a tab session. Re-invoking with an existing session id
/// rebinds that tab to a new URL (in-tab navigation).
#[tauri::command]
pub fn open_web_document(
    url: String,
    session_id: String,
    app: tauri::AppHandle,
    state: State<AppState>,
) -> Result<DocumentInfo, String> {
    let data_dir = web_store_dir(&app)?;
    let (session, record) = web_page::open_session(&data_dir, &url)?;
    let (title, page_count, last_page) = web_page::document_info(&record);

    let info = DocumentInfo {
        kind: "web".to_string(),
        pdf_path: session.url.clone(),
        title,
        page_count,
        last_page,
    };

    let mut sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = sessions.remove(&session_id) {
        close_session(&prev)?;
    }
    sessions.insert(session_id, Session::Web(session));

    Ok(info)
}

/// Synchronize a tab session. Annotation mutations are saved immediately.
#[tauri::command]
pub fn save_file(session_id: String, state: State<AppState>) -> Result<(), String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    close_session(session)
}

/// Close a tab session.
#[tauri::command]
pub fn close_file(session_id: String, state: State<AppState>) -> Result<(), String> {
    let mut sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = sessions.remove(&session_id) {
        close_session(&prev)?;
    }
    Ok(())
}

/// Get all annotations, optionally filtered by page
#[tauri::command]
pub fn get_annotations(
    session_id: String,
    page_number: Option<u32>,
    state: State<AppState>,
) -> Result<Vec<Annotation>, String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    match session {
        Session::Pdf(pdf) => pdf_annotations::get_annotations(&pdf.pdf_path, page_number),
        Session::Web(web) => web_page::get_annotations(web, page_number),
    }
}

/// Create a new annotation
#[tauri::command]
pub fn create_annotation(
    session_id: String,
    input: CreateAnnotationInput,
    state: State<AppState>,
) -> Result<Annotation, String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    match session {
        Session::Pdf(pdf) => pdf_annotations::create_annotation(&pdf.pdf_path, &input),
        Session::Web(web) => web_page::create_annotation(web, &input),
    }
}

/// Update an existing annotation
#[tauri::command]
pub fn update_annotation(
    session_id: String,
    input: UpdateAnnotationInput,
    state: State<AppState>,
) -> Result<bool, String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    match session {
        Session::Pdf(pdf) => pdf_annotations::update_annotation(&pdf.pdf_path, &input),
        Session::Web(web) => web_page::update_annotation(web, &input),
    }
}

/// Delete an annotation
#[tauri::command]
pub fn delete_annotation(
    session_id: String,
    id: String,
    state: State<AppState>,
) -> Result<bool, String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    match session {
        Session::Pdf(pdf) => pdf_annotations::delete_annotation(&pdf.pdf_path, &id),
        Session::Web(web) => web_page::delete_annotation(web, &id),
    }
}

/// Set document metadata (e.g., page_count, last_page, title)
#[tauri::command]
pub fn set_document_metadata(
    session_id: String,
    key: String,
    value: String,
    state: State<AppState>,
) -> Result<(), String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    match session {
        Session::Pdf(pdf) => pdf_annotations::set_metadata(&pdf.pdf_path, &key, &value),
        Session::Web(web) => web_page::set_metadata(web, &key, &value),
    }
}

/// Read the PDF bytes for a tab session.
/// Returns raw bytes via IPC Response (efficient binary transfer).
#[tauri::command]
pub fn read_pdf_bytes(session_id: String, state: State<AppState>) -> Result<Response, String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    let pdf = match session {
        Session::Pdf(pdf) => pdf,
        Session::Web(_) => return Err("This tab is a webpage, not a PDF".to_string()),
    };
    let pdf_path = pdf.pdf_path();
    let bytes = std::fs::read(&pdf_path)
        .map_err(|e| format!("Failed to read PDF at {}: {}", pdf_path.display(), e))?;
    Ok(Response::new(bytes))
}

/// Mark the current webpage tab as saved (or unsaved) in the library.
#[tauri::command]
pub fn set_webpage_saved(
    session_id: String,
    saved: bool,
    state: State<AppState>,
) -> Result<(), String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    match session {
        Session::Web(web) => web_page::set_saved(web, saved),
        Session::Pdf(_) => Err("This tab is a PDF, not a webpage".to_string()),
    }
}

/// Whether the current webpage tab is saved in the library.
#[tauri::command]
pub fn get_webpage_saved(session_id: String, state: State<AppState>) -> Result<bool, String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    match session {
        Session::Web(web) => Ok(web_page::is_saved(web)),
        Session::Pdf(_) => Ok(false),
    }
}

/// List all saved webpages for the welcome screen library.
#[tauri::command]
pub fn list_saved_webpages(app: tauri::AppHandle) -> Result<Vec<WebLibraryEntry>, String> {
    let data_dir = web_store_dir(&app)?;
    Ok(web_page::list_saved(&data_dir))
}

/// Remove a webpage from the saved library (annotations are kept).
#[tauri::command]
pub fn remove_saved_webpage(url: String, app: tauri::AppHandle) -> Result<(), String> {
    let data_dir = web_store_dir(&app)?;
    web_page::remove_saved(&data_dir, &url)
}

/// Export (or update) a `.vellumweb` archive for a webpage tab.
///
/// Prefers a fresh live capture; falls back to the locally installed
/// self-contained snapshot, then the plain saved snapshot. `pages` is the
/// virtual-page text currently extracted by the reader (the AI context),
/// bundled so external consumers get the text without re-parsing HTML.
#[tauri::command]
pub async fn export_vellumweb(
    session_id: String,
    dest_path: String,
    pages: Vec<web_archive::PageText>,
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<web_archive::ExportSummary, String> {
    let (url, record_path, snapshot_path) = web_session_paths(&state, &session_id)?;
    let data_dir = web_store_dir(&app)?;
    let dest = PathBuf::from(&dest_path);
    write_web_archive(&url, &record_path, &snapshot_path, &data_dir, pages, &dest).await
}

/// Session-tab lookup shared by the archive commands.
fn web_session_paths(
    state: &State<AppState>,
    session_id: &str,
) -> Result<(String, PathBuf, PathBuf), String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    match sessions.get(session_id) {
        Some(Session::Web(web)) => Ok((
            web.url.clone(),
            web.record_path.clone(),
            web.snapshot_path.clone(),
        )),
        Some(Session::Pdf(_)) => {
            Err("PDFs are already portable — archiving applies to webpage tabs".into())
        }
        None => Err(format!("No session found for tab {}", session_id)),
    }
}

/// Capture the best available snapshot, refresh the installed archive dir, and
/// write a `.vellumweb` archive to `dest` atomically. Shared by the explicit
/// export command and the automatic on-open archiver.
async fn write_web_archive(
    url: &str,
    record_path: &Path,
    snapshot_path: &Path,
    data_dir: &Path,
    pages: Vec<web_archive::PageText>,
    dest: &Path,
) -> Result<web_archive::ExportSummary, String> {
    let key = web_page::page_key(url);
    let record = web_page::load_record(record_path);

    // Best available snapshot: live capture > installed archive dir > plain
    // saved snapshot (assets skipped when offline).
    let captured = match web_page::fetch_page(url).await {
        Ok(web_page::FetchedPage::Html { html, final_url }) => {
            // Resolve relative asset URLs against where the page actually
            // came from (after redirects), not the requested URL.
            let base = web_page::normalize_url(&final_url).unwrap_or_else(|_| url.to_string());
            web_archive::capture_snapshot(&base, &html).await?
        }
        _ => {
            if let Some((html, assets)) = web_archive::load_archive_dir(data_dir, &key) {
                web_archive::CapturedSnapshot {
                    html,
                    assets: assets
                        .into_iter()
                        .map(|(name, bytes)| web_archive::CapturedAsset {
                            content_type: web_archive::content_type_for_name(&name).to_string(),
                            url: String::new(),
                            name,
                            bytes,
                        })
                        .collect(),
                    skipped: 0,
                }
            } else if let Ok(html) = std::fs::read_to_string(snapshot_path) {
                web_archive::capture_snapshot(url, &html).await?
            } else {
                return Err("The page could not be fetched and no local snapshot exists yet".into());
            }
        }
    };

    let pages_json =
        serde_json::to_vec(&pages).map_err(|e| format!("Failed to serialize page text: {}", e))?;

    let (title, mut page_count, last_page) = match &record {
        Some(record) => web_page::document_info(record),
        None => (None, None, None),
    };
    if !pages.is_empty() {
        page_count = Some(pages.len() as u32);
    }
    let annotations = record.map(|r| r.annotations).unwrap_or_default();

    let manifest = web_archive::build_manifest(
        url,
        title,
        page_count,
        last_page,
        "live-first",
        &captured.html,
        &pages_json,
        &captured.assets,
        captured.skipped,
    );

    // Refresh the local self-contained snapshot so offline fallback matches
    // what was just archived.
    let dir_assets: Vec<(String, Vec<u8>)> = captured
        .assets
        .iter()
        .map(|a| (a.name.clone(), a.bytes.clone()))
        .collect();
    web_archive::install_archive_dir(data_dir, &key, &captured.html, &dir_assets, Some(&manifest))?;

    let asset_count = captured.assets.len() as u32;
    let assets_skipped = captured.skipped;
    let dest = dest.to_path_buf();
    let dest_display = dest.to_string_lossy().to_string();
    let bytes = tauri::async_runtime::spawn_blocking(move || {
        web_archive::write_archive(
            &dest,
            &manifest,
            &captured.html,
            &captured.assets,
            &pages_json,
            &annotations,
        )
    })
    .await
    .map_err(|e| format!("Archive task failed: {}", e))??;

    Ok(web_archive::ExportSummary {
        path: dest_display,
        bytes,
        asset_count,
        assets_skipped,
    })
}

/// Automatically archive a freshly opened webpage into the managed library as
/// a `.vellumweb` file. This is the default persistence path: every opened
/// page becomes a portable archive without a save dialog. Fire-and-forget from
/// the frontend once the page's text has been extracted. No-op semantics are
/// signalled by returning `false` when the tab isn't a live webpage.
#[tauri::command]
pub async fn archive_webpage_default(
    session_id: String,
    pages: Vec<web_archive::PageText>,
    expected_url: Option<String>,
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<bool, String> {
    let (url, record_path, snapshot_path) = web_session_paths(&state, &session_id)?;
    // The frontend debounces this call; if the tab navigated in the meantime,
    // the session is bound to a different URL than the page texts describe —
    // skip rather than archive mismatched content.
    if let Some(expected) = expected_url {
        let expected_normalized = web_page::normalize_url(&expected).unwrap_or(expected);
        if expected_normalized != url {
            return Ok(false);
        }
    }
    let data_dir = web_store_dir(&app)?;
    let dest = web_page::managed_archive_path(&data_dir, &web_page::page_key(&url));

    write_web_archive(&url, &record_path, &snapshot_path, &data_dir, pages, &dest).await?;

    // Opening a page now means it's kept: mark it saved so it lands in the
    // library, without disturbing an existing saved_at timestamp.
    web_page::mark_saved_if_absent(&record_path, &url)?;
    Ok(true)
}

/// Open a `.vellumweb` archive: install its snapshot locally, merge its
/// annotations into the sidecar, and open the page as a normal web tab
/// (live-first with automatic snapshot fallback).
#[tauri::command]
pub async fn open_vellumweb_file(
    path: String,
    session_id: String,
    app: tauri::AppHandle,
    state: State<'_, AppState>,
) -> Result<DocumentInfo, String> {
    let archive_path = PathBuf::from(&path);
    let imported =
        tauri::async_runtime::spawn_blocking(move || web_archive::read_archive(&archive_path))
            .await
            .map_err(|e| format!("Archive task failed: {}", e))??;

    let data_dir = web_store_dir(&app)?;
    let (session, mut record) = web_page::open_session(&data_dir, &imported.manifest.url)?;
    let key = web_page::page_key(&session.url);

    web_archive::install_archive_dir(
        &data_dir,
        &key,
        &imported.snapshot_html,
        &imported.assets,
        Some(&imported.manifest),
    )?;

    // Merge archive metadata without clobbering local reading state.
    if record.title.is_none() {
        record.title = imported.manifest.title.clone();
    }
    if record.page_count.is_none() {
        record.page_count = imported.manifest.page_count;
    }
    if record.last_page.is_none() {
        record.last_page = imported.manifest.last_page;
    }
    if imported.manifest.loading_policy == "snapshot-only" {
        record.loading_policy = Some("snapshot-only".to_string());
    }
    record.saved = true;
    if record.saved_at.is_none() {
        record.saved_at = Some(chrono::Utc::now().to_rfc3339());
    }
    web_archive::merge_annotations(&mut record.annotations, &imported.annotations);
    web_page::save_record(&session.record_path, &record)?;

    let (title, page_count, last_page) = web_page::document_info(&record);
    let info = DocumentInfo {
        kind: "web".to_string(),
        pdf_path: session.url.clone(),
        title,
        page_count,
        last_page,
    };

    let mut sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = sessions.remove(&session_id) {
        close_session(&prev)?;
    }
    sessions.insert(session_id, Session::Web(session));

    Ok(info)
}

#[derive(Debug, Deserialize)]
pub struct CodexAiImageInput {
    pub base64_data: String,
    pub media_type: String,
}

/// Run the local Codex CLI using the user's existing Codex authentication.
#[tauri::command]
pub async fn run_codex_ai(
    prompt: String,
    model: String,
    image: Option<CodexAiImageInput>,
) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || run_codex_ai_blocking(prompt, model, image))
        .await
        .map_err(|e| format!("Codex task failed: {}", e))?
}

fn run_codex_ai_blocking(
    prompt: String,
    model: String,
    image: Option<CodexAiImageInput>,
) -> Result<String, String> {
    let temp_dir = tempfile::tempdir().map_err(|e| format!("Failed to create temp dir: {}", e))?;
    let schema_path = temp_dir.path().join("codex-output-schema.json");
    let output_path = temp_dir.path().join("codex-response.json");
    let schema = codex_output_schema();
    let schema_bytes = serde_json::to_vec_pretty(&schema)
        .map_err(|e| format!("Failed to serialize Codex schema: {}", e))?;
    fs::write(&schema_path, schema_bytes)
        .map_err(|e| format!("Failed to write Codex schema: {}", e))?;

    let image_path = if let Some(image) = image {
        let extension = codex_image_extension(&image.media_type);
        let image_path = temp_dir.path().join(format!("current-page.{}", extension));
        let image_bytes = base64::engine::general_purpose::STANDARD
            .decode(image.base64_data.trim())
            .map_err(|e| format!("Failed to decode page image: {}", e))?;
        fs::write(&image_path, image_bytes)
            .map_err(|e| format!("Failed to write page image: {}", e))?;
        Some(image_path)
    } else {
        None
    };

    let model = model.trim();
    let model = if model.is_empty() { "gpt-5.5" } else { model };

    let mut command = Command::new("codex");
    command
        .arg("exec")
        .arg("--model")
        .arg(model)
        .arg("--sandbox")
        .arg("read-only")
        .arg("--skip-git-repo-check")
        .arg("--ephemeral")
        .arg("--cd")
        .arg(temp_dir.path())
        .arg("--output-schema")
        .arg(&schema_path)
        .arg("--output-last-message")
        .arg(&output_path);

    if let Some(image_path) = &image_path {
        command.arg("--image").arg(image_path);
    }

    command.arg("-");
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command
        .spawn()
        .map_err(|e| format!("Failed to start Codex CLI. Is `codex` installed? {}", e))?;

    let mut stdin = child.stdin.take().ok_or("Failed to open Codex stdin")?;
    stdin
        .write_all(prompt.as_bytes())
        .map_err(|e| format!("Failed to write prompt to Codex: {}", e))?;
    drop(stdin);

    let output = child
        .wait_with_output()
        .map_err(|e| format!("Failed to read Codex output: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let details = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        return Err(format!(
            "Codex CLI exited with status {}: {}",
            output.status,
            truncate_for_error(details, 1_200)
        ));
    }

    let response = fs::read_to_string(&output_path)
        .or_else(|_| String::from_utf8(output.stdout).map_err(std::io::Error::other))
        .map_err(|e| format!("Failed to read Codex final response: {}", e))?;
    let response = response.trim();
    if response.is_empty() {
        return Err("Codex returned an empty response.".to_string());
    }

    Ok(response.to_string())
}

fn codex_image_extension(media_type: &str) -> &'static str {
    match media_type {
        "image/png" => "png",
        "image/webp" => "webp",
        _ => "jpg",
    }
}

fn truncate_for_error(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }

    format!("{}...", value.chars().take(max_chars).collect::<String>())
}

fn codex_output_schema() -> serde_json::Value {
    serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "reply": {
                "type": "string"
            },
            "actions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "tool": {
                            "type": "string",
                            "enum": ["goToPage", "addNote", "addHighlight"]
                        },
                        "args": {
                            "type": "object",
                            "additionalProperties": false,
                            "properties": {
                                "pageNumber": { "type": "number" },
                                "text": { "type": ["string", "null"] },
                                "color": { "type": ["string", "null"] },
                                "x": { "type": ["number", "null"] },
                                "y": { "type": ["number", "null"] }
                            },
                            "required": [
                                "pageNumber",
                                "text",
                                "color",
                                "x",
                                "y"
                            ]
                        }
                    },
                    "required": ["tool", "args"]
                }
            }
        },
        "required": ["reply", "actions"]
    })
}

fn default_document_kind() -> String {
    "pdf".to_string()
}

/// Response for open_file / open_web_document.
/// `pdf_path` doubles as the generic document URI: a filesystem path for PDFs,
/// a normalized URL for webpages (the field name is kept for compatibility
/// with stored conversations and recents keyed on it).
#[derive(Debug, Serialize, Deserialize)]
pub struct DocumentInfo {
    #[serde(default = "default_document_kind")]
    pub kind: String,
    pub pdf_path: String,
    pub title: Option<String>,
    pub page_count: Option<u32>,
    pub last_page: Option<u32>,
}
