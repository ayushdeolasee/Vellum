use base64::Engine;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Mutex;
use tauri::ipc::Response;
use tauri::State;

use crate::models::*;
use crate::pdf_annotations;
use crate::pdf_session::{self, PdfSession};

/// Application state holding the current session
pub struct AppState {
    pub session: Mutex<Option<PdfSession>>,
}

/// Open a PDF without creating a custom document container.
#[tauri::command]
pub fn open_file(path: String, state: State<AppState>) -> Result<DocumentInfo, String> {
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
        pdf_path,
        title,
        page_count: Some(page_count),
        last_page,
    };

    let mut state_session = state.session.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = state_session.take() {
        pdf_session::save_session(&prev)?;
    }
    *state_session = Some(session);

    Ok(info)
}

/// Synchronize the current session. Annotation mutations are saved immediately.
#[tauri::command]
pub fn save_file(state: State<AppState>) -> Result<(), String> {
    let session = state.session.lock().map_err(|e| e.to_string())?;
    let session = session.as_ref().ok_or("No file is open")?;
    pdf_session::save_session(session)
}

/// Close the current session
#[tauri::command]
pub fn close_file(state: State<AppState>) -> Result<(), String> {
    let mut session = state.session.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = session.take() {
        pdf_session::save_session(&prev)?;
    }
    Ok(())
}

/// Get all annotations, optionally filtered by page
#[tauri::command]
pub fn get_annotations(
    page_number: Option<u32>,
    state: State<AppState>,
) -> Result<Vec<Annotation>, String> {
    let session = state.session.lock().map_err(|e| e.to_string())?;
    let session = session.as_ref().ok_or("No file is open")?;
    pdf_annotations::get_annotations(&session.pdf_path, page_number)
}

/// Create a new annotation
#[tauri::command]
pub fn create_annotation(
    input: CreateAnnotationInput,
    state: State<AppState>,
) -> Result<Annotation, String> {
    let session = state.session.lock().map_err(|e| e.to_string())?;
    let session = session.as_ref().ok_or("No file is open")?;
    pdf_annotations::create_annotation(&session.pdf_path, &input)
}

/// Update an existing annotation
#[tauri::command]
pub fn update_annotation(
    input: UpdateAnnotationInput,
    state: State<AppState>,
) -> Result<bool, String> {
    let session = state.session.lock().map_err(|e| e.to_string())?;
    let session = session.as_ref().ok_or("No file is open")?;
    pdf_annotations::update_annotation(&session.pdf_path, &input)
}

/// Delete an annotation
#[tauri::command]
pub fn delete_annotation(id: String, state: State<AppState>) -> Result<bool, String> {
    let session = state.session.lock().map_err(|e| e.to_string())?;
    let session = session.as_ref().ok_or("No file is open")?;
    pdf_annotations::delete_annotation(&session.pdf_path, &id)
}

/// Set document metadata (e.g., page_count, last_page, title)
#[tauri::command]
pub fn set_document_metadata(
    key: String,
    value: String,
    state: State<AppState>,
) -> Result<(), String> {
    let session = state.session.lock().map_err(|e| e.to_string())?;
    let session = session.as_ref().ok_or("No file is open")?;
    pdf_annotations::set_metadata(&session.pdf_path, &key, &value)
}

/// Read the PDF bytes for the current session.
/// Returns raw bytes via IPC Response (efficient binary transfer).
#[tauri::command]
pub fn read_pdf_bytes(state: State<AppState>) -> Result<Response, String> {
    let session = state.session.lock().map_err(|e| e.to_string())?;
    let session = session.as_ref().ok_or("No file is open")?;
    let pdf_path = session.pdf_path();
    let bytes = std::fs::read(&pdf_path)
        .map_err(|e| format!("Failed to read PDF at {}: {}", pdf_path.display(), e))?;
    Ok(Response::new(bytes))
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
                            "additionalProperties": true
                        }
                    },
                    "required": ["tool", "args"]
                }
            }
        },
        "required": ["reply", "actions"]
    })
}

/// Response for open_file
#[derive(Debug, Serialize, Deserialize)]
pub struct DocumentInfo {
    pub pdf_path: String,
    pub title: Option<String>,
    pub page_count: Option<u32>,
    pub last_page: Option<u32>,
}
