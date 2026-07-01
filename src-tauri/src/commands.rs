use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::ipc::Response;
use tauri::State;

use crate::models::*;
use crate::pdf_annotations;
use crate::pdf_session::{self, PdfSession};

/// Application state holding all open PDF tab sessions.
pub struct AppState {
    pub sessions: Mutex<HashMap<String, PdfSession>>,
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
        pdf_path,
        title,
        page_count: Some(page_count),
        last_page,
    };

    let mut sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = sessions.remove(&session_id) {
        pdf_session::save_session(&prev)?;
    }
    sessions.insert(session_id, session);

    Ok(info)
}

/// Synchronize a tab session. Annotation mutations are saved immediately.
#[tauri::command]
pub fn save_file(session_id: String, state: State<AppState>) -> Result<(), String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    pdf_session::save_session(session)
}

/// Close a tab session.
#[tauri::command]
pub fn close_file(session_id: String, state: State<AppState>) -> Result<(), String> {
    let mut sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    if let Some(prev) = sessions.remove(&session_id) {
        pdf_session::save_session(&prev)?;
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
    pdf_annotations::get_annotations(&session.pdf_path, page_number)
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
    pdf_annotations::create_annotation(&session.pdf_path, &input)
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
    pdf_annotations::update_annotation(&session.pdf_path, &input)
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
    pdf_annotations::delete_annotation(&session.pdf_path, &id)
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
    pdf_annotations::set_metadata(&session.pdf_path, &key, &value)
}

/// Read the PDF bytes for a tab session.
/// Returns raw bytes via IPC Response (efficient binary transfer).
#[tauri::command]
pub fn read_pdf_bytes(session_id: String, state: State<AppState>) -> Result<Response, String> {
    let sessions = state.sessions.lock().map_err(|e| e.to_string())?;
    let session = sessions
        .get(&session_id)
        .ok_or_else(|| format!("No session found for tab {}", session_id))?;
    let pdf_path = session.pdf_path();
    let bytes = std::fs::read(&pdf_path)
        .map_err(|e| format!("Failed to read PDF at {}: {}", pdf_path.display(), e))?;
    Ok(Response::new(bytes))
}

/// Response for open_file
#[derive(Debug, Serialize, Deserialize)]
pub struct DocumentInfo {
    pub pdf_path: String,
    pub title: Option<String>,
    pub page_count: Option<u32>,
    pub last_page: Option<u32>,
}
