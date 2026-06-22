use std::fs;
use std::path::{Path, PathBuf};

/// Session state for a currently open PDF file.
/// Annotations and document metadata are embedded in the PDF itself.
pub struct PdfSession {
    /// Path to the PDF on disk.
    pub pdf_path: PathBuf,
}

impl PdfSession {
    /// Path to the opened PDF.
    pub fn pdf_path(&self) -> PathBuf {
        self.pdf_path.clone()
    }
}

/// Open a PDF in place and validate that it can be parsed for annotation editing.
pub fn open_pdf(pdf_path: &Path) -> Result<PdfSession, String> {
    let canonical_pdf_path = fs::canonicalize(pdf_path)
        .map_err(|e| format!("Failed to resolve PDF path {}: {}", pdf_path.display(), e))?;

    if !canonical_pdf_path.is_file() {
        return Err(format!(
            "PDF path is not a file: {}",
            canonical_pdf_path.display()
        ));
    }

    lopdf::Document::load(&canonical_pdf_path)
        .map_err(|e| format!("Failed to parse PDF: {}", e))?;

    Ok(PdfSession {
        pdf_path: canonical_pdf_path,
    })
}

/// Annotation mutations are written immediately, so save is a synchronization point.
pub fn save_session(_session: &PdfSession) -> Result<(), String> {
    Ok(())
}
