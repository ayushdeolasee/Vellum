use serde::{Deserialize, Serialize};

/// Represents a highlight/note/bookmark annotation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Annotation {
    pub id: String,
    #[serde(rename = "type")]
    pub annotation_type: AnnotationType,
    pub page_number: u32,
    pub color: Option<String>,
    pub content: Option<String>,
    pub position_data: Option<PositionData>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnnotationType {
    Highlight,
    Note,
    Bookmark,
}

/// Position data for an annotation on a PDF page.
/// Coordinates are normalized to zoom=1.0.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PositionData {
    pub rects: Vec<Rect>,
    pub page_width: f64,
    pub page_height: f64,
    pub selected_text: Option<String>,
    pub start_offset: Option<u32>,
    pub end_offset: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Input for creating a new annotation from the frontend
#[derive(Debug, Deserialize)]
pub struct CreateAnnotationInput {
    #[serde(rename = "type")]
    pub annotation_type: AnnotationType,
    pub page_number: u32,
    pub color: Option<String>,
    pub content: Option<String>,
    pub position_data: Option<PositionData>,
}

/// Input for updating an existing annotation
#[derive(Debug, Deserialize)]
pub struct UpdateAnnotationInput {
    pub id: String,
    pub color: Option<String>,
    pub content: Option<String>,
    pub position_data: Option<PositionData>,
}

/// Metadata about the opened PDF document.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocumentMetadata {
    pub title: Option<String>,
    pub page_count: Option<u32>,
    pub last_page: Option<u32>,
}
