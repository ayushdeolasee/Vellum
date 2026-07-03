use std::fs;
use std::path::Path;

use chrono::Utc;
use lopdf::{decode_text_string, text_string, Dictionary, Document, Object, ObjectId};

use crate::models::{
    Annotation, AnnotationType, CreateAnnotationInput, PositionData, Rect, UpdateAnnotationInput,
};

const DEFAULT_HIGHLIGHT_COLOR: &str = "#fef08a";
const DEFAULT_NOTE_COLOR: &str = "#fde68a";
const NOTE_SIZE: f64 = 18.0;

struct PageGeometry {
    left: f64,
    bottom: f64,
    width: f64,
    height: f64,
    rotation: i32,
    user_unit: f64,
}

impl PageGeometry {
    fn right(&self) -> f64 {
        self.left + self.width
    }

    fn top(&self) -> f64 {
        self.bottom + self.height
    }

    fn display_width(&self) -> f64 {
        if self.rotation == 90 || self.rotation == 270 {
            self.height * self.user_unit
        } else {
            self.width * self.user_unit
        }
    }

    fn display_height(&self) -> f64 {
        if self.rotation == 90 || self.rotation == 270 {
            self.width * self.user_unit
        } else {
            self.height * self.user_unit
        }
    }

    fn pdf_to_ui(&self, x: f64, y: f64) -> (f64, f64) {
        match self.rotation {
            90 => (
                (y - self.bottom) * self.user_unit,
                (x - self.left) * self.user_unit,
            ),
            180 => (
                (self.right() - x) * self.user_unit,
                (y - self.bottom) * self.user_unit,
            ),
            270 => (
                (self.top() - y) * self.user_unit,
                (self.right() - x) * self.user_unit,
            ),
            _ => (
                (x - self.left) * self.user_unit,
                (self.top() - y) * self.user_unit,
            ),
        }
    }

    fn ui_to_pdf(&self, x: f64, y: f64, page_width: f64, page_height: f64) -> (f64, f64) {
        let display_x = x * self.display_width() / page_width.max(f64::EPSILON);
        let display_y = y * self.display_height() / page_height.max(f64::EPSILON);
        let x_units = display_x / self.user_unit;
        let y_units = display_y / self.user_unit;

        match self.rotation {
            90 => (self.left + y_units, self.bottom + x_units),
            180 => (self.right() - x_units, self.bottom + y_units),
            270 => (self.right() - y_units, self.top() - x_units),
            _ => (self.left + x_units, self.top() - y_units),
        }
    }
}

struct AnnotationEntry {
    index: usize,
    object_id: Option<ObjectId>,
    annots_object_id: Option<ObjectId>,
    dictionary: Dictionary,
}

/// Read the document title, page count, and Vellum reading position from the PDF.
pub fn document_info(path: &Path) -> Result<(Option<String>, u32, Option<u32>), String> {
    let document = load_document(path)?;
    let title = info_dictionary(&document)
        .and_then(|dict| dict.get(b"Title").ok())
        .and_then(|value| decode_text_string(value).ok())
        .or_else(|| {
            path.file_stem()
                .and_then(|stem| stem.to_str())
                .map(str::to_owned)
        });
    let last_page = info_dictionary(&document)
        .and_then(|dict| dict.get(b"VellumLastPage").ok())
        .and_then(object_u32);

    Ok((title, document.get_pages().len() as u32, last_page))
}

/// Read supported standard PDF annotations from every page.
pub fn get_annotations(path: &Path, page_number: Option<u32>) -> Result<Vec<Annotation>, String> {
    let document = load_document(path)?;
    let pages = document.get_pages();
    let mut annotations = Vec::new();

    for (page, page_id) in pages {
        if page_number.is_some_and(|requested| requested != page) {
            continue;
        }

        let geometry = page_geometry(&document, page_id)?;
        for entry in annotation_entries(&document, page_id)? {
            if let Some(annotation) = dictionary_to_annotation(&document, page, &geometry, &entry) {
                annotations.push(annotation);
            }
        }
    }
    annotations.extend(read_bookmarks(&document, page_number));

    annotations.sort_by(|left, right| {
        left.page_number
            .cmp(&right.page_number)
            .then_with(|| left.created_at.cmp(&right.created_at))
    });
    Ok(annotations)
}

/// Create and embed a standard PDF annotation.
pub fn create_annotation(path: &Path, input: &CreateAnnotationInput) -> Result<Annotation, String> {
    let mut document = load_document(path)?;
    let page_id = document
        .get_pages()
        .get(&input.page_number)
        .copied()
        .ok_or_else(|| format!("Page {} does not exist", input.page_number))?;
    if matches!(input.annotation_type, AnnotationType::Bookmark) {
        return create_bookmark(document, path, input.page_number, page_id);
    }

    let geometry = page_geometry(&document, page_id)?;
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let (mut dictionary, position_data, color, content) =
        create_dictionary(input, &geometry, &id, &now)?;
    dictionary.set("P", page_id);
    let annotation_id = document.add_object(Object::Dictionary(dictionary));
    append_annotation(&mut document, page_id, annotation_id)?;
    save_document(&mut document, path)?;

    Ok(Annotation {
        id,
        annotation_type: input.annotation_type.clone(),
        page_number: input.page_number,
        color,
        content,
        position_data: Some(position_data),
        created_at: now.clone(),
        updated_at: now,
    })
}

/// Update an embedded annotation by its standard PDF `/NM` identifier.
pub fn update_annotation(path: &Path, input: &UpdateAnnotationInput) -> Result<bool, String> {
    let mut document = load_document(path)?;
    let Some((page_id, geometry, entry)) = find_annotation(&document, &input.id)? else {
        return Ok(false);
    };

    let dictionary = annotation_dictionary_mut(&mut document, page_id, &entry)?;
    dictionary.set("NM", text_string(&input.id));
    dictionary.set("M", text_string(&pdf_date_now()));
    dictionary.set("VellumUpdatedAt", text_string(&Utc::now().to_rfc3339()));

    if let Some(color) = input.color.as_deref() {
        dictionary.set("C", color_array(color));
    }
    if let Some(content) = input.content.as_deref() {
        dictionary.set("Contents", text_string(content));
    }
    if let Some(position) = input.position_data.as_ref() {
        apply_position(dictionary, &geometry, position)?;
        if let Some(selected_text) = position.selected_text.as_deref() {
            dictionary.set("VellumSelectedText", text_string(selected_text));
        }
    }

    save_document(&mut document, path)?;
    Ok(true)
}

/// Delete an embedded annotation by its standard PDF `/NM` identifier.
pub fn delete_annotation(path: &Path, id: &str) -> Result<bool, String> {
    let mut document = load_document(path)?;
    if delete_bookmark(&mut document, id)? {
        save_document(&mut document, path)?;
        return Ok(true);
    }

    let Some((page_id, _, entry)) = find_annotation(&document, id)? else {
        return Ok(false);
    };

    let array = annotation_array_mut(&mut document, page_id, entry.annots_object_id)?;
    if entry.index >= array.len() {
        return Ok(false);
    }
    array.remove(entry.index);
    if let Some(object_id) = entry.object_id {
        document.objects.remove(&object_id);
    }
    save_document(&mut document, path)?;
    Ok(true)
}

/// Embed Vellum reading metadata in the PDF information dictionary.
pub fn set_metadata(path: &Path, key: &str, value: &str) -> Result<(), String> {
    if key == "page_count" {
        return Ok(());
    }

    let mut document = load_document(path)?;
    let info_id = ensure_info_dictionary(&mut document)?;
    let info = document
        .get_object_mut(info_id)
        .and_then(Object::as_dict_mut)
        .map_err(|e| format!("Failed to edit PDF metadata: {}", e))?;

    match key {
        "title" => info.set("Title", text_string(value)),
        "last_page" => {
            let page = value
                .parse::<u32>()
                .map_err(|e| format!("Invalid last_page value: {}", e))?;
            info.set("VellumLastPage", page);
        }
        _ => info.set(
            format!("Vellum{}", metadata_key_suffix(key)),
            text_string(value),
        ),
    }

    save_document(&mut document, path)
}

fn load_document(path: &Path) -> Result<Document, String> {
    match Document::load(path) {
        Ok(document) => Ok(document),
        Err(original_error) => {
            let mut bytes =
                fs::read(path).map_err(|e| format!("Failed to read PDF for recovery: {}", e))?;
            if !bytes
                .windows(b"VellumCreatedAt".len())
                .any(|window| window == b"VellumCreatedAt")
                || !strip_stale_xref_links(&mut bytes)
            {
                return Err(format!("Failed to parse PDF: {}", original_error));
            }
            Document::load_mem(&bytes).map_err(|recovery_error| {
                format!(
                    "Failed to parse PDF: {}; recovery also failed: {}",
                    original_error, recovery_error
                )
            })
        }
    }
}

fn save_document(document: &mut Document, path: &Path) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("PDF has no parent directory: {}", path.display()))?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("document.pdf");
    let nonce = uuid::Uuid::new_v4();
    let temporary_path = parent.join(format!(".{}.vellum-{}.tmp", file_name, nonce));
    let permissions = fs::metadata(path)
        .map_err(|e| format!("Failed to read PDF permissions: {}", e))?
        .permissions();

    // A full rewrite must not retain pointers to cross-reference sections from
    // the original file. Those offsets no longer exist in the rewritten PDF.
    document.trailer.remove(b"Prev");
    document.trailer.remove(b"XRefStm");

    if let Err(error) = document.save(&temporary_path) {
        let _ = fs::remove_file(&temporary_path);
        return Err(format!("Failed to write annotated PDF: {}", error));
    }
    if let Err(error) = fs::set_permissions(&temporary_path, permissions) {
        let _ = fs::remove_file(&temporary_path);
        return Err(format!("Failed to preserve PDF permissions: {}", error));
    }

    replace_file(&temporary_path, path, file_name, nonce)
}

fn strip_stale_xref_links(bytes: &mut [u8]) -> bool {
    let (trailer_start, trailer_end) = if let Some(trailer_start) = rfind_bytes(bytes, b"trailer") {
        let Some(relative_end) = find_bytes(&bytes[trailer_start..], b"startxref") else {
            return false;
        };
        (trailer_start, trailer_start + relative_end)
    } else {
        let Some(xref_marker) = rfind_bytes(bytes, b"/Type/XRef") else {
            return false;
        };
        let Some(dictionary_start) = rfind_bytes(&bytes[..xref_marker], b"<<") else {
            return false;
        };
        let Some(relative_end) = find_bytes(&bytes[xref_marker..], b"stream") else {
            return false;
        };
        (dictionary_start, xref_marker + relative_end)
    };
    let mut changed = false;

    for key in [b"/Prev".as_slice(), b"/XRefStm".as_slice()] {
        let mut search_start = trailer_start;
        while search_start < trailer_end {
            let Some(relative_key) = find_bytes(&bytes[search_start..trailer_end], key) else {
                break;
            };
            let key_start = search_start + relative_key;
            let mut value_end = key_start + key.len();
            while value_end < trailer_end && bytes[value_end].is_ascii_whitespace() {
                value_end += 1;
            }
            let number_start = value_end;
            while value_end < trailer_end && bytes[value_end].is_ascii_digit() {
                value_end += 1;
            }
            if value_end == number_start {
                search_start = key_start + key.len();
                continue;
            }
            bytes[key_start..value_end].fill(b' ');
            changed = true;
            search_start = value_end;
        }
    }
    changed
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn rfind_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .rposition(|window| window == needle)
}

#[cfg(unix)]
fn replace_file(
    temporary_path: &Path,
    path: &Path,
    _file_name: &str,
    _nonce: uuid::Uuid,
) -> Result<(), String> {
    fs::rename(temporary_path, path).map_err(|error| {
        let _ = fs::remove_file(temporary_path);
        format!("Failed to replace PDF with annotated copy: {}", error)
    })
}

#[cfg(windows)]
fn replace_file(
    temporary_path: &Path,
    path: &Path,
    file_name: &str,
    nonce: uuid::Uuid,
) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("PDF has no parent directory: {}", path.display()))?;
    let backup_path = parent.join(format!(".{}.vellum-{}.bak", file_name, nonce));
    fs::rename(path, &backup_path)
        .map_err(|e| format!("Failed to prepare PDF replacement: {}", e))?;
    if let Err(error) = fs::rename(temporary_path, path) {
        let _ = fs::rename(&backup_path, path);
        let _ = fs::remove_file(temporary_path);
        return Err(format!(
            "Failed to replace PDF with annotated copy: {}",
            error
        ));
    }
    let _ = fs::remove_file(backup_path);
    Ok(())
}

fn info_dictionary(document: &Document) -> Option<&Dictionary> {
    let info = document.trailer.get(b"Info").ok()?;
    match info {
        Object::Reference(id) => document.get_dictionary(*id).ok(),
        Object::Dictionary(dictionary) => Some(dictionary),
        _ => None,
    }
}

fn ensure_info_dictionary(document: &mut Document) -> Result<ObjectId, String> {
    if let Ok(Object::Reference(id)) = document.trailer.get(b"Info") {
        return Ok(*id);
    }

    let dictionary = match document.trailer.get(b"Info") {
        Ok(Object::Dictionary(dictionary)) => dictionary.clone(),
        _ => Dictionary::new(),
    };
    let info_id = document.add_object(Object::Dictionary(dictionary));
    document.trailer.set("Info", info_id);
    Ok(info_id)
}

fn metadata_key_suffix(key: &str) -> String {
    key.split('_')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

fn create_bookmark(
    mut document: Document,
    path: &Path,
    page_number: u32,
    page_id: ObjectId,
) -> Result<Annotation, String> {
    let outlines_id = ensure_outlines_root(&mut document)?;
    let last_id = document
        .get_dictionary(outlines_id)
        .ok()
        .and_then(|root| root.get(b"Last").ok())
        .and_then(|value| value.as_reference().ok());
    let bookmark_id = document.new_object_id();
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let mut bookmark = Dictionary::new();
    bookmark.set(
        "Title",
        text_string(&format!("Bookmark - page {}", page_number)),
    );
    bookmark.set("Parent", outlines_id);
    bookmark.set(
        "Dest",
        Object::Array(vec![
            Object::Reference(page_id),
            Object::Name(b"Fit".to_vec()),
        ]),
    );
    bookmark.set("VellumType", Object::Name(b"Bookmark".to_vec()));
    bookmark.set("VellumNM", text_string(&id));
    bookmark.set("VellumCreatedAt", text_string(&now));
    bookmark.set("VellumUpdatedAt", text_string(&now));

    if let Some(last_id) = last_id {
        document
            .get_object_mut(last_id)
            .and_then(Object::as_dict_mut)
            .map_err(|e| format!("Failed to update PDF outline: {}", e))?
            .set("Next", bookmark_id);
        bookmark.set("Prev", last_id);
    }
    document
        .objects
        .insert(bookmark_id, Object::Dictionary(bookmark));

    let root = document
        .get_object_mut(outlines_id)
        .and_then(Object::as_dict_mut)
        .map_err(|e| format!("Failed to update PDF outlines: {}", e))?;
    if last_id.is_none() {
        root.set("First", bookmark_id);
    }
    root.set("Last", bookmark_id);
    adjust_outline_count(root, 1);

    save_document(&mut document, path)?;
    Ok(Annotation {
        id,
        annotation_type: AnnotationType::Bookmark,
        page_number,
        color: None,
        content: None,
        position_data: None,
        created_at: now.clone(),
        updated_at: now,
    })
}

fn read_bookmarks(document: &Document, page_number: Option<u32>) -> Vec<Annotation> {
    let page_numbers = document
        .get_pages()
        .into_iter()
        .map(|(page, id)| (id, page))
        .collect::<std::collections::HashMap<_, _>>();
    let mut bookmarks = Vec::new();

    for dictionary in document
        .objects
        .values()
        .filter_map(|object| object.as_dict().ok())
    {
        if !is_vellum_outline(dictionary) {
            continue;
        }
        let Some(page_id) = outline_page_id(document, dictionary) else {
            continue;
        };
        let Some(page) = page_numbers.get(&page_id).copied() else {
            continue;
        };
        if page_number.is_some_and(|requested| requested != page) {
            continue;
        }
        let Some(id) = dictionary
            .get(b"VellumNM")
            .ok()
            .and_then(|value| dereferenced_text(document, value))
        else {
            continue;
        };
        let now = Utc::now().to_rfc3339();
        let created_at = dictionary
            .get(b"VellumCreatedAt")
            .ok()
            .and_then(|value| dereferenced_text(document, value))
            .unwrap_or_else(|| now.clone());
        let updated_at = dictionary
            .get(b"VellumUpdatedAt")
            .ok()
            .and_then(|value| dereferenced_text(document, value))
            .unwrap_or(now);
        bookmarks.push(Annotation {
            id,
            annotation_type: AnnotationType::Bookmark,
            page_number: page,
            color: None,
            content: None,
            position_data: None,
            created_at,
            updated_at,
        });
    }
    bookmarks
}

fn delete_bookmark(document: &mut Document, id: &str) -> Result<bool, String> {
    let bookmark_id = document.objects.iter().find_map(|(object_id, object)| {
        let dictionary = object.as_dict().ok()?;
        if !is_vellum_outline(dictionary) {
            return None;
        }
        let bookmark_id = dictionary
            .get(b"VellumNM")
            .ok()
            .and_then(|value| decode_text_string(value).ok())?;
        (bookmark_id == id).then_some(*object_id)
    });
    let Some(bookmark_id) = bookmark_id else {
        return Ok(false);
    };

    let bookmark = document
        .get_dictionary(bookmark_id)
        .map_err(|e| format!("Failed to read PDF bookmark: {}", e))?
        .clone();
    let parent_id = bookmark
        .get(b"Parent")
        .and_then(Object::as_reference)
        .map_err(|e| format!("PDF bookmark has no outline parent: {}", e))?;
    let previous_id = bookmark
        .get(b"Prev")
        .ok()
        .and_then(|value| value.as_reference().ok());
    let next_id = bookmark
        .get(b"Next")
        .ok()
        .and_then(|value| value.as_reference().ok());

    if let Some(previous_id) = previous_id {
        let previous = document
            .get_object_mut(previous_id)
            .and_then(Object::as_dict_mut)
            .map_err(|e| format!("Failed to update previous PDF bookmark: {}", e))?;
        match next_id {
            Some(next_id) => previous.set("Next", next_id),
            None => {
                previous.remove(b"Next");
            }
        }
    } else {
        let parent = document
            .get_object_mut(parent_id)
            .and_then(Object::as_dict_mut)
            .map_err(|e| format!("Failed to update PDF outline root: {}", e))?;
        match next_id {
            Some(next_id) => parent.set("First", next_id),
            None => {
                parent.remove(b"First");
            }
        }
    }

    if let Some(next_id) = next_id {
        let next = document
            .get_object_mut(next_id)
            .and_then(Object::as_dict_mut)
            .map_err(|e| format!("Failed to update next PDF bookmark: {}", e))?;
        match previous_id {
            Some(previous_id) => next.set("Prev", previous_id),
            None => {
                next.remove(b"Prev");
            }
        }
    } else {
        let parent = document
            .get_object_mut(parent_id)
            .and_then(Object::as_dict_mut)
            .map_err(|e| format!("Failed to update PDF outline root: {}", e))?;
        match previous_id {
            Some(previous_id) => parent.set("Last", previous_id),
            None => {
                parent.remove(b"Last");
            }
        }
    }

    let parent = document
        .get_object_mut(parent_id)
        .and_then(Object::as_dict_mut)
        .map_err(|e| format!("Failed to update PDF outline count: {}", e))?;
    adjust_outline_count(parent, -1);
    document.objects.remove(&bookmark_id);
    Ok(true)
}

fn ensure_outlines_root(document: &mut Document) -> Result<ObjectId, String> {
    let catalog_id = document
        .trailer
        .get(b"Root")
        .and_then(Object::as_reference)
        .map_err(|e| format!("PDF has no catalog: {}", e))?;
    let existing = document
        .get_dictionary(catalog_id)
        .ok()
        .and_then(|catalog| catalog.get(b"Outlines").ok())
        .cloned();

    match existing {
        Some(Object::Reference(id)) => Ok(id),
        Some(Object::Dictionary(dictionary)) => {
            let outlines_id = document.add_object(Object::Dictionary(dictionary));
            document
                .get_object_mut(catalog_id)
                .and_then(Object::as_dict_mut)
                .map_err(|e| format!("Failed to update PDF catalog: {}", e))?
                .set("Outlines", outlines_id);
            Ok(outlines_id)
        }
        _ => {
            let mut outlines = Dictionary::new();
            outlines.set("Type", Object::Name(b"Outlines".to_vec()));
            outlines.set("Count", 0_i64);
            let outlines_id = document.add_object(Object::Dictionary(outlines));
            document
                .get_object_mut(catalog_id)
                .and_then(Object::as_dict_mut)
                .map_err(|e| format!("Failed to update PDF catalog: {}", e))?
                .set("Outlines", outlines_id);
            Ok(outlines_id)
        }
    }
}

fn is_vellum_outline(dictionary: &Dictionary) -> bool {
    !dictionary.has(b"Subtype")
        && dictionary
            .get(b"VellumType")
            .and_then(Object::as_name)
            .is_ok_and(|name| name == b"Bookmark")
        && dictionary.has(b"VellumNM")
        && dictionary.has(b"Title")
}

fn outline_page_id(document: &Document, dictionary: &Dictionary) -> Option<ObjectId> {
    let destination = dictionary.get(b"Dest").ok()?;
    let values = dereferenced_array(document, destination)?;
    values.first()?.as_reference().ok()
}

fn adjust_outline_count(dictionary: &mut Dictionary, delta: i64) {
    let count = dictionary
        .get(b"Count")
        .ok()
        .and_then(|value| value.as_i64().ok())
        .unwrap_or(0);
    let next = if count < 0 {
        count - delta
    } else {
        (count + delta).max(0)
    };
    dictionary.set("Count", next);
}

fn create_dictionary(
    input: &CreateAnnotationInput,
    geometry: &PageGeometry,
    id: &str,
    now: &str,
) -> Result<(Dictionary, PositionData, Option<String>, Option<String>), String> {
    let mut dictionary = Dictionary::new();
    dictionary.set("Type", Object::Name(b"Annot".to_vec()));
    dictionary.set("NM", text_string(id));
    dictionary.set("M", text_string(&pdf_date_now()));
    dictionary.set("F", 4_i64);
    dictionary.set("T", text_string("Vellum"));
    dictionary.set("VellumCreatedAt", text_string(now));
    dictionary.set("VellumUpdatedAt", text_string(now));

    let position = input
        .position_data
        .clone()
        .unwrap_or_else(|| default_position(input, geometry));
    let color = input.color.clone().or_else(|| {
        Some(
            match input.annotation_type {
                AnnotationType::Highlight => DEFAULT_HIGHLIGHT_COLOR,
                _ => DEFAULT_NOTE_COLOR,
            }
            .to_string(),
        )
    });
    dictionary.set(
        "C",
        color_array(color.as_deref().unwrap_or(DEFAULT_HIGHLIGHT_COLOR)),
    );

    match input.annotation_type {
        AnnotationType::Highlight => {
            dictionary.set("Subtype", Object::Name(b"Highlight".to_vec()));
            dictionary.set("CA", 0.4_f64);
        }
        AnnotationType::Note => {
            dictionary.set("Subtype", Object::Name(b"Text".to_vec()));
            dictionary.set("Name", Object::Name(b"Note".to_vec()));
        }
        AnnotationType::Bookmark => {
            dictionary.set("Subtype", Object::Name(b"Text".to_vec()));
            dictionary.set("Name", Object::Name(b"Key".to_vec()));
            dictionary.set("VellumType", Object::Name(b"Bookmark".to_vec()));
            dictionary.set("Contents", text_string("Bookmark"));
        }
    }

    if let Some(content) = input.content.as_deref() {
        dictionary.set("Contents", text_string(content));
    }
    if let Some(selected_text) = position.selected_text.as_deref() {
        dictionary.set("VellumSelectedText", text_string(selected_text));
    }
    apply_position(&mut dictionary, geometry, &position)?;

    Ok((dictionary, position, color, input.content.clone()))
}

fn default_position(input: &CreateAnnotationInput, geometry: &PageGeometry) -> PositionData {
    let x = if matches!(input.annotation_type, AnnotationType::Bookmark) {
        (geometry.display_width() - NOTE_SIZE).max(0.0)
    } else {
        0.0
    };
    PositionData {
        rects: vec![Rect {
            x,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        }],
        page_width: geometry.display_width(),
        page_height: geometry.display_height(),
        selected_text: None,
        start_offset: None,
        end_offset: None,
        prefix: None,
        suffix: None,
        viewport_offset: None,
    }
}

fn apply_position(
    dictionary: &mut Dictionary,
    geometry: &PageGeometry,
    position: &PositionData,
) -> Result<(), String> {
    let subtype = dictionary
        .get(b"Subtype")
        .and_then(Object::as_name)
        .unwrap_or_default();

    if subtype == b"Highlight" {
        if position.rects.is_empty() {
            return Err("Highlight has no rectangles".to_string());
        }
        let mut quad_points = Vec::with_capacity(position.rects.len() * 8);
        let mut all_points = Vec::with_capacity(position.rects.len() * 4);
        for rect in &position.rects {
            let top_left =
                geometry.ui_to_pdf(rect.x, rect.y, position.page_width, position.page_height);
            let top_right = geometry.ui_to_pdf(
                rect.x + rect.width,
                rect.y,
                position.page_width,
                position.page_height,
            );
            let bottom_left = geometry.ui_to_pdf(
                rect.x,
                rect.y + rect.height,
                position.page_width,
                position.page_height,
            );
            let bottom_right = geometry.ui_to_pdf(
                rect.x + rect.width,
                rect.y + rect.height,
                position.page_width,
                position.page_height,
            );
            for (x, y) in [top_left, top_right, bottom_left, bottom_right] {
                quad_points.push(Object::from(x));
                quad_points.push(Object::from(y));
                all_points.push((x, y));
            }
        }
        dictionary.set("QuadPoints", Object::Array(quad_points));
        dictionary.set("Rect", points_bounding_rect(&all_points));
    } else {
        let anchor = position
            .rects
            .first()
            .ok_or_else(|| "Note has no position".to_string())?;
        let top_left = geometry.ui_to_pdf(
            anchor.x,
            anchor.y,
            position.page_width,
            position.page_height,
        );
        let bottom_right = geometry.ui_to_pdf(
            anchor.x + NOTE_SIZE,
            anchor.y + NOTE_SIZE,
            position.page_width,
            position.page_height,
        );
        dictionary.set("Rect", points_bounding_rect(&[top_left, bottom_right]));
    }
    Ok(())
}

fn dictionary_to_annotation(
    document: &Document,
    page_number: u32,
    geometry: &PageGeometry,
    entry: &AnnotationEntry,
) -> Option<Annotation> {
    let subtype = entry
        .dictionary
        .get(b"Subtype")
        .ok()
        .and_then(|value| dereferenced_name(document, value))?;
    let annotation_type = match subtype.as_slice() {
        b"Highlight" => AnnotationType::Highlight,
        b"Text" | b"FreeText" => {
            if entry
                .dictionary
                .get(b"VellumType")
                .ok()
                .and_then(|value| dereferenced_name(document, value))
                .is_some_and(|name| name == b"Bookmark")
            {
                AnnotationType::Bookmark
            } else {
                AnnotationType::Note
            }
        }
        _ => return None,
    };

    let id = annotation_id(page_number, entry);
    let color = read_color(document, &entry.dictionary).or_else(|| {
        Some(
            match annotation_type {
                AnnotationType::Highlight => DEFAULT_HIGHLIGHT_COLOR,
                _ => DEFAULT_NOTE_COLOR,
            }
            .to_string(),
        )
    });
    let content = entry
        .dictionary
        .get(b"Contents")
        .ok()
        .and_then(|value| dereferenced_text(document, value))
        .filter(|value| {
            !matches!(annotation_type, AnnotationType::Bookmark) || value != "Bookmark"
        });
    let selected_text = entry
        .dictionary
        .get(b"VellumSelectedText")
        .ok()
        .and_then(|value| dereferenced_text(document, value));
    let position_data = read_position(
        document,
        &entry.dictionary,
        &annotation_type,
        geometry,
        selected_text,
    )?;
    let now = Utc::now().to_rfc3339();
    let created_at = entry
        .dictionary
        .get(b"VellumCreatedAt")
        .ok()
        .and_then(|value| dereferenced_text(document, value))
        .unwrap_or_else(|| now.clone());
    let updated_at = entry
        .dictionary
        .get(b"VellumUpdatedAt")
        .ok()
        .and_then(|value| dereferenced_text(document, value))
        .unwrap_or(now);

    Some(Annotation {
        id,
        annotation_type,
        page_number,
        color,
        content,
        position_data: Some(position_data),
        created_at,
        updated_at,
    })
}

fn read_position(
    document: &Document,
    dictionary: &Dictionary,
    annotation_type: &AnnotationType,
    geometry: &PageGeometry,
    selected_text: Option<String>,
) -> Option<PositionData> {
    let rects = if matches!(annotation_type, AnnotationType::Highlight) {
        let quad_points = dictionary
            .get(b"QuadPoints")
            .ok()
            .and_then(|value| dereferenced_array(document, value))
            .map(|values| {
                values
                    .chunks_exact(8)
                    .filter_map(|chunk| {
                        let points = chunk
                            .chunks_exact(2)
                            .filter_map(|pair| {
                                Some((
                                    object_f64(document, &pair[0])?,
                                    object_f64(document, &pair[1])?,
                                ))
                            })
                            .map(|(x, y)| geometry.pdf_to_ui(x, y))
                            .collect::<Vec<_>>();
                        ui_bounding_rect(&points)
                    })
                    .collect::<Vec<_>>()
            })
            .filter(|rects| !rects.is_empty());

        quad_points.or_else(|| {
            read_pdf_rect(document, dictionary)
                .and_then(|points| ui_bounding_rect(&pdf_points_to_ui(geometry, &points)))
                .map(|rect| vec![rect])
        })?
    } else {
        let points = read_pdf_rect(document, dictionary)?;
        let rect = ui_bounding_rect(&pdf_points_to_ui(geometry, &points))?;
        vec![Rect {
            x: rect.x,
            y: rect.y,
            width: 0.0,
            height: 0.0,
        }]
    };

    Some(PositionData {
        rects,
        page_width: geometry.display_width(),
        page_height: geometry.display_height(),
        selected_text,
        start_offset: None,
        end_offset: None,
        prefix: None,
        suffix: None,
        viewport_offset: None,
    })
}

fn read_pdf_rect(document: &Document, dictionary: &Dictionary) -> Option<Vec<(f64, f64)>> {
    let values = dictionary
        .get(b"Rect")
        .ok()
        .and_then(|value| dereferenced_array(document, value))?;
    if values.len() < 4 {
        return None;
    }
    let x1 = object_f64(document, &values[0])?;
    let y1 = object_f64(document, &values[1])?;
    let x2 = object_f64(document, &values[2])?;
    let y2 = object_f64(document, &values[3])?;
    Some(vec![(x1, y1), (x2, y2)])
}

fn pdf_points_to_ui(geometry: &PageGeometry, points: &[(f64, f64)]) -> Vec<(f64, f64)> {
    points
        .iter()
        .map(|(x, y)| geometry.pdf_to_ui(*x, *y))
        .collect()
}

fn ui_bounding_rect(points: &[(f64, f64)]) -> Option<Rect> {
    let first = points.first()?;
    let (mut min_x, mut min_y) = *first;
    let (mut max_x, mut max_y) = *first;
    for (x, y) in points.iter().skip(1) {
        min_x = min_x.min(*x);
        min_y = min_y.min(*y);
        max_x = max_x.max(*x);
        max_y = max_y.max(*y);
    }
    Some(Rect {
        x: min_x,
        y: min_y,
        width: max_x - min_x,
        height: max_y - min_y,
    })
}

fn points_bounding_rect(points: &[(f64, f64)]) -> Object {
    let (mut min_x, mut min_y) = points[0];
    let (mut max_x, mut max_y) = points[0];
    for (x, y) in points.iter().skip(1) {
        min_x = min_x.min(*x);
        min_y = min_y.min(*y);
        max_x = max_x.max(*x);
        max_y = max_y.max(*y);
    }
    Object::Array(vec![
        Object::from(min_x),
        Object::from(min_y),
        Object::from(max_x),
        Object::from(max_y),
    ])
}

fn find_annotation(
    document: &Document,
    id: &str,
) -> Result<Option<(ObjectId, PageGeometry, AnnotationEntry)>, String> {
    for (page_number, page_id) in document.get_pages() {
        let geometry = page_geometry(document, page_id)?;
        for entry in annotation_entries(document, page_id)? {
            if annotation_id(page_number, &entry) == id {
                return Ok(Some((page_id, geometry, entry)));
            }
        }
    }
    Ok(None)
}

fn annotation_id(page_number: u32, entry: &AnnotationEntry) -> String {
    entry
        .dictionary
        .get(b"NM")
        .ok()
        .and_then(|value| decode_text_string(value).ok())
        .unwrap_or_else(|| match entry.object_id {
            Some((object, generation)) => format!("pdf-{}-{}", object, generation),
            None => format!("pdf-direct-{}-{}", page_number, entry.index),
        })
}

fn annotation_entries(
    document: &Document,
    page_id: ObjectId,
) -> Result<Vec<AnnotationEntry>, String> {
    let page = document
        .get_dictionary(page_id)
        .map_err(|e| format!("Failed to read PDF page: {}", e))?;
    let Ok(annots) = page.get(b"Annots") else {
        return Ok(Vec::new());
    };
    let (annots_object_id, array) = match annots {
        Object::Array(array) => (None, array),
        Object::Reference(id) => (
            Some(*id),
            document
                .get_object(*id)
                .and_then(Object::as_array)
                .map_err(|e| format!("Failed to read page annotations: {}", e))?,
        ),
        _ => return Ok(Vec::new()),
    };

    Ok(array
        .iter()
        .enumerate()
        .filter_map(|(index, value)| match value {
            Object::Reference(id) => document
                .get_dictionary(*id)
                .ok()
                .cloned()
                .map(|dictionary| AnnotationEntry {
                    index,
                    object_id: Some(*id),
                    annots_object_id,
                    dictionary,
                }),
            Object::Dictionary(dictionary) => Some(AnnotationEntry {
                index,
                object_id: None,
                annots_object_id,
                dictionary: dictionary.clone(),
            }),
            _ => None,
        })
        .collect())
}

fn append_annotation(
    document: &mut Document,
    page_id: ObjectId,
    annotation_id: ObjectId,
) -> Result<(), String> {
    let annots = document
        .get_dictionary(page_id)
        .ok()
        .and_then(|page| page.get(b"Annots").ok())
        .cloned();

    match annots {
        Some(Object::Reference(id)) => document
            .get_object_mut(id)
            .and_then(Object::as_array_mut)
            .map_err(|e| format!("Failed to edit page annotations: {}", e))?
            .push(Object::Reference(annotation_id)),
        Some(Object::Array(_)) => document
            .get_object_mut(page_id)
            .and_then(Object::as_dict_mut)
            .and_then(|page| page.get_mut(b"Annots"))
            .and_then(Object::as_array_mut)
            .map_err(|e| format!("Failed to edit page annotations: {}", e))?
            .push(Object::Reference(annotation_id)),
        _ => document
            .get_object_mut(page_id)
            .and_then(Object::as_dict_mut)
            .map_err(|e| format!("Failed to edit PDF page: {}", e))?
            .set(
                "Annots",
                Object::Array(vec![Object::Reference(annotation_id)]),
            ),
    }
    Ok(())
}

fn annotation_dictionary_mut<'a>(
    document: &'a mut Document,
    page_id: ObjectId,
    entry: &AnnotationEntry,
) -> Result<&'a mut Dictionary, String> {
    if let Some(object_id) = entry.object_id {
        return document
            .get_object_mut(object_id)
            .and_then(Object::as_dict_mut)
            .map_err(|e| format!("Failed to edit annotation: {}", e));
    }

    annotation_array_mut(document, page_id, entry.annots_object_id)?
        .get_mut(entry.index)
        .ok_or_else(|| "Annotation no longer exists".to_string())?
        .as_dict_mut()
        .map_err(|e| format!("Failed to edit annotation: {}", e))
}

fn annotation_array_mut(
    document: &mut Document,
    page_id: ObjectId,
    annots_object_id: Option<ObjectId>,
) -> Result<&mut Vec<Object>, String> {
    match annots_object_id {
        Some(id) => document
            .get_object_mut(id)
            .and_then(Object::as_array_mut)
            .map_err(|e| format!("Failed to edit page annotations: {}", e)),
        None => document
            .get_object_mut(page_id)
            .and_then(Object::as_dict_mut)
            .and_then(|page| page.get_mut(b"Annots"))
            .and_then(Object::as_array_mut)
            .map_err(|e| format!("Failed to edit page annotations: {}", e)),
    }
}

fn page_geometry(document: &Document, page_id: ObjectId) -> Result<PageGeometry, String> {
    let media_box = inherited_object(document, page_id, b"CropBox")
        .or_else(|| inherited_object(document, page_id, b"MediaBox"))
        .ok_or_else(|| "PDF page has no MediaBox".to_string())?;
    let values = dereferenced_array(document, &media_box)
        .ok_or_else(|| "PDF page has an invalid MediaBox".to_string())?;
    if values.len() < 4 {
        return Err("PDF page has an invalid MediaBox".to_string());
    }
    let left = object_f64(document, &values[0]).unwrap_or(0.0);
    let bottom = object_f64(document, &values[1]).unwrap_or(0.0);
    let right = object_f64(document, &values[2]).unwrap_or(612.0);
    let top = object_f64(document, &values[3]).unwrap_or(792.0);
    let rotation = inherited_object(document, page_id, b"Rotate")
        .and_then(|value| object_i64(document, &value))
        .unwrap_or(0)
        .rem_euclid(360) as i32;
    let user_unit = inherited_object(document, page_id, b"UserUnit")
        .and_then(|value| object_f64(document, &value))
        .filter(|value| *value > 0.0)
        .unwrap_or(1.0);

    Ok(PageGeometry {
        left,
        bottom,
        width: (right - left).abs(),
        height: (top - bottom).abs(),
        rotation,
        user_unit,
    })
}

fn inherited_object(document: &Document, mut object_id: ObjectId, key: &[u8]) -> Option<Object> {
    loop {
        let dictionary = document.get_dictionary(object_id).ok()?;
        if let Ok(value) = dictionary.get(key) {
            return Some(value.clone());
        }
        object_id = dictionary.get(b"Parent").ok()?.as_reference().ok()?;
    }
}

fn dereferenced_array<'a>(document: &'a Document, value: &'a Object) -> Option<&'a Vec<Object>> {
    document
        .dereference(value)
        .ok()
        .and_then(|(_, value)| value.as_array().ok())
}

fn dereferenced_text(document: &Document, value: &Object) -> Option<String> {
    document
        .dereference(value)
        .ok()
        .and_then(|(_, value)| decode_text_string(value).ok())
}

fn dereferenced_name(document: &Document, value: &Object) -> Option<Vec<u8>> {
    document
        .dereference(value)
        .ok()
        .and_then(|(_, value)| value.as_name().ok())
        .map(ToOwned::to_owned)
}

fn object_f64(document: &Document, value: &Object) -> Option<f64> {
    document
        .dereference(value)
        .ok()
        .and_then(|(_, value)| value.as_float().ok())
        .map(f64::from)
}

fn object_i64(document: &Document, value: &Object) -> Option<i64> {
    document
        .dereference(value)
        .ok()
        .and_then(|(_, value)| value.as_i64().ok())
}

fn object_u32(value: &Object) -> Option<u32> {
    match value {
        Object::Integer(number) => u32::try_from(*number).ok(),
        Object::String(_, _) => decode_text_string(value).ok()?.parse().ok(),
        _ => None,
    }
}

fn read_color(document: &Document, dictionary: &Dictionary) -> Option<String> {
    let values = dictionary
        .get(b"C")
        .ok()
        .and_then(|value| dereferenced_array(document, value))?;
    if values.len() < 3 {
        return None;
    }
    let channels = values
        .iter()
        .take(3)
        .map(|value| object_f64(document, value))
        .collect::<Option<Vec<_>>>()?;
    Some(format!(
        "#{:02x}{:02x}{:02x}",
        (channels[0].clamp(0.0, 1.0) * 255.0).round() as u8,
        (channels[1].clamp(0.0, 1.0) * 255.0).round() as u8,
        (channels[2].clamp(0.0, 1.0) * 255.0).round() as u8,
    ))
}

fn color_array(color: &str) -> Object {
    let (red, green, blue) = parse_hex_color(color).unwrap_or((254, 240, 138));
    Object::Array(vec![
        Object::from(f64::from(red) / 255.0),
        Object::from(f64::from(green) / 255.0),
        Object::from(f64::from(blue) / 255.0),
    ])
}

fn parse_hex_color(color: &str) -> Option<(u8, u8, u8)> {
    let hex = color.strip_prefix('#').unwrap_or(color);
    if hex.len() != 6 {
        return None;
    }
    Some((
        u8::from_str_radix(&hex[0..2], 16).ok()?,
        u8::from_str_radix(&hex[2..4], 16).ok()?,
        u8::from_str_radix(&hex[4..6], 16).ok()?,
    ))
}

fn pdf_date_now() -> String {
    format!("D:{}", Utc::now().format("%Y%m%d%H%M%SZ"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use lopdf::{dictionary, Stream};
    use std::path::PathBuf;

    fn create_test_pdf(path: &Path, rotation: i64) {
        let mut document = Document::with_version("1.7");
        let pages_id = document.new_object_id();
        let page_id = document.new_object_id();
        let content_id = document.add_object(Stream::new(Dictionary::new(), Vec::new()));
        let page = dictionary! {
            "Type" => "Page",
            "Parent" => pages_id,
            "MediaBox" => vec![0.into(), 0.into(), 612.into(), 792.into()],
            "Rotate" => rotation,
            "Contents" => content_id,
            "Resources" => Dictionary::new(),
        };
        let pages = dictionary! {
            "Type" => "Pages",
            "Kids" => vec![page_id.into()],
            "Count" => 1,
        };
        let catalog_id = document.add_object(dictionary! {
            "Type" => "Catalog",
            "Pages" => pages_id,
        });
        document.objects.insert(page_id, Object::Dictionary(page));
        document.objects.insert(pages_id, Object::Dictionary(pages));
        document.trailer.set("Root", catalog_id);
        document.compress();
        document.save(path).unwrap();
    }

    fn test_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "vellum-pdf-annotations-{}-{}.pdf",
            name,
            uuid::Uuid::new_v4()
        ))
    }

    fn position(rect: Rect, page_width: f64, page_height: f64) -> PositionData {
        PositionData {
            rects: vec![rect],
            page_width,
            page_height,
            selected_text: Some("selected text".to_string()),
            start_offset: None,
            end_offset: None,
            prefix: None,
            suffix: None,
            viewport_offset: None,
        }
    }

    fn assert_close(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < 0.02,
            "expected {expected}, got {actual}"
        );
    }

    #[test]
    fn annotations_are_embedded_editable_and_path_independent() {
        let original_path = test_path("original");
        let moved_path = test_path("moved");
        create_test_pdf(&original_path, 0);

        let highlight = create_annotation(
            &original_path,
            &CreateAnnotationInput {
                annotation_type: AnnotationType::Highlight,
                page_number: 1,
                color: Some("#fef08a".to_string()),
                content: None,
                position_data: Some(position(
                    Rect {
                        x: 72.0,
                        y: 100.0,
                        width: 180.0,
                        height: 16.0,
                    },
                    612.0,
                    792.0,
                )),
            },
        )
        .unwrap();
        let note = create_annotation(
            &original_path,
            &CreateAnnotationInput {
                annotation_type: AnnotationType::Note,
                page_number: 1,
                color: None,
                content: Some("First note".to_string()),
                position_data: Some(position(
                    Rect {
                        x: 300.0,
                        y: 400.0,
                        width: 0.0,
                        height: 0.0,
                    },
                    612.0,
                    792.0,
                )),
            },
        )
        .unwrap();

        let raw_document = Document::load(&original_path).unwrap();
        let page_id = raw_document.get_pages()[&1];
        let dictionaries = raw_document.get_page_annotations(page_id).unwrap();
        assert!(dictionaries.iter().any(|dictionary| {
            dictionary
                .get(b"Subtype")
                .and_then(Object::as_name)
                .is_ok_and(|name| name == b"Highlight")
                && dictionary.has(b"QuadPoints")
        }));
        assert!(dictionaries.iter().any(|dictionary| {
            dictionary
                .get(b"Subtype")
                .and_then(Object::as_name)
                .is_ok_and(|name| name == b"Text")
                && dictionary
                    .get(b"Contents")
                    .ok()
                    .and_then(|value| decode_text_string(value).ok())
                    .is_some_and(|content| content == "First note")
        }));

        fs::rename(&original_path, &moved_path).unwrap();
        let reopened = get_annotations(&moved_path, None).unwrap();
        assert_eq!(reopened.len(), 2);
        let reopened_highlight = reopened
            .iter()
            .find(|annotation| annotation.id == highlight.id)
            .unwrap();
        let rect = &reopened_highlight.position_data.as_ref().unwrap().rects[0];
        assert_close(rect.x, 72.0);
        assert_close(rect.y, 100.0);
        assert_close(rect.width, 180.0);
        assert_close(rect.height, 16.0);

        update_annotation(
            &moved_path,
            &UpdateAnnotationInput {
                id: note.id.clone(),
                color: None,
                content: Some("Edited note".to_string()),
                position_data: Some(position(
                    Rect {
                        x: 320.0,
                        y: 420.0,
                        width: 0.0,
                        height: 0.0,
                    },
                    612.0,
                    792.0,
                )),
            },
        )
        .unwrap();
        let edited = get_annotations(&moved_path, None).unwrap();
        let edited_note = edited
            .iter()
            .find(|annotation| annotation.id == note.id)
            .unwrap();
        assert_eq!(edited_note.content.as_deref(), Some("Edited note"));
        let note_rect = &edited_note.position_data.as_ref().unwrap().rects[0];
        assert_close(note_rect.x, 320.0);
        assert_close(note_rect.y, 420.0);

        assert!(delete_annotation(&moved_path, &highlight.id).unwrap());
        assert_eq!(get_annotations(&moved_path, None).unwrap().len(), 1);
        set_metadata(&moved_path, "last_page", "1").unwrap();
        assert_eq!(document_info(&moved_path).unwrap().2, Some(1));

        let _ = fs::remove_file(moved_path);
    }

    #[test]
    fn rotated_page_coordinates_round_trip() {
        for rotation in [90_i64, 180, 270] {
            let path = test_path(&format!("rotation-{rotation}"));
            create_test_pdf(&path, rotation);
            let (page_width, page_height) = if rotation == 90 || rotation == 270 {
                (792.0, 612.0)
            } else {
                (612.0, 792.0)
            };
            let created = create_annotation(
                &path,
                &CreateAnnotationInput {
                    annotation_type: AnnotationType::Highlight,
                    page_number: 1,
                    color: None,
                    content: None,
                    position_data: Some(position(
                        Rect {
                            x: 50.0,
                            y: 60.0,
                            width: 120.0,
                            height: 14.0,
                        },
                        page_width,
                        page_height,
                    )),
                },
            )
            .unwrap();
            let annotations = get_annotations(&path, None).unwrap();
            let rect = &annotations
                .iter()
                .find(|annotation| annotation.id == created.id)
                .unwrap()
                .position_data
                .as_ref()
                .unwrap()
                .rects[0];
            assert_close(rect.x, 50.0);
            assert_close(rect.y, 60.0);
            assert_close(rect.width, 120.0);
            assert_close(rect.height, 14.0);
            let _ = fs::remove_file(path);
        }
    }

    #[test]
    fn third_party_standard_highlight_can_be_read_and_edited() {
        let path = test_path("third-party");
        create_test_pdf(&path, 0);
        let mut document = Document::load(&path).unwrap();
        let page_id = document.get_pages()[&1];
        let annotation_id = document.add_object(dictionary! {
            "Type" => "Annot",
            "Subtype" => "Highlight",
            "NM" => text_string("external-highlight"),
            "Rect" => vec![72.into(), 676.into(), 252.into(), 692.into()],
            "QuadPoints" => vec![
                72.into(), 692.into(), 252.into(), 692.into(),
                72.into(), 676.into(), 252.into(), 676.into(),
            ],
            "C" => vec![1.0.into(), 1.0.into(), 0.0.into()],
            "Contents" => text_string("External comment"),
        });
        append_annotation(&mut document, page_id, annotation_id).unwrap();
        document.save(&path).unwrap();

        let annotations = get_annotations(&path, None).unwrap();
        let annotation = annotations
            .iter()
            .find(|annotation| annotation.id == "external-highlight")
            .unwrap();
        assert!(matches!(
            annotation.annotation_type,
            AnnotationType::Highlight
        ));
        assert_eq!(annotation.content.as_deref(), Some("External comment"));
        assert_eq!(annotation.color.as_deref(), Some("#ffff00"));
        let rect = &annotation.position_data.as_ref().unwrap().rects[0];
        assert_close(rect.x, 72.0);
        assert_close(rect.y, 100.0);
        assert_close(rect.width, 180.0);
        assert_close(rect.height, 16.0);

        assert!(update_annotation(
            &path,
            &UpdateAnnotationInput {
                id: "external-highlight".to_string(),
                color: Some("#bbf7d0".to_string()),
                content: Some("Edited in Vellum".to_string()),
                position_data: None,
            },
        )
        .unwrap());
        let edited = get_annotations(&path, None).unwrap();
        let annotation = edited
            .iter()
            .find(|annotation| annotation.id == "external-highlight")
            .unwrap();
        assert_eq!(annotation.content.as_deref(), Some("Edited in Vellum"));
        assert_eq!(annotation.color.as_deref(), Some("#bbf7d0"));

        let _ = fs::remove_file(path);
    }

    #[test]
    fn bookmarks_use_standard_pdf_outlines() {
        let path = test_path("bookmark-outline");
        create_test_pdf(&path, 0);
        let bookmark = create_annotation(
            &path,
            &CreateAnnotationInput {
                annotation_type: AnnotationType::Bookmark,
                page_number: 1,
                color: None,
                content: None,
                position_data: None,
            },
        )
        .unwrap();
        assert!(get_annotations(&path, None)
            .unwrap()
            .iter()
            .any(|annotation| annotation.id == bookmark.id));

        let document = Document::load(&path).unwrap();
        let outline = document
            .objects
            .values()
            .filter_map(|object| object.as_dict().ok())
            .find(|dictionary| {
                dictionary
                    .get(b"VellumNM")
                    .ok()
                    .and_then(|value| decode_text_string(value).ok())
                    .is_some_and(|id| id == bookmark.id)
            })
            .unwrap();
        assert!(!outline.has(b"Subtype"));
        assert!(outline.has(b"Title"));
        assert!(outline.has(b"Dest"));

        assert!(delete_annotation(&path, &bookmark.id).unwrap());
        assert!(get_annotations(&path, None)
            .unwrap()
            .iter()
            .all(|annotation| annotation.id != bookmark.id));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn stale_incremental_xref_links_are_recovered_and_removed() {
        let path = test_path("stale-prev");
        create_test_pdf(&path, 0);
        let mut document = Document::load(&path).unwrap();
        let marker_id = document.add_object(dictionary! {
            "VellumCreatedAt" => text_string("2026-06-20T00:00:00Z"),
        });
        document.trailer.set("Info", marker_id);
        document.trailer.set("Prev", 1_i64);
        document.save(&path).unwrap();

        assert!(Document::load(&path).is_err());
        let note = create_annotation(
            &path,
            &CreateAnnotationInput {
                annotation_type: AnnotationType::Note,
                page_number: 1,
                color: None,
                content: Some("Recovered note".to_string()),
                position_data: Some(position(
                    Rect {
                        x: 120.0,
                        y: 160.0,
                        width: 0.0,
                        height: 0.0,
                    },
                    612.0,
                    792.0,
                )),
            },
        )
        .unwrap();
        let bookmark = create_annotation(
            &path,
            &CreateAnnotationInput {
                annotation_type: AnnotationType::Bookmark,
                page_number: 1,
                color: None,
                content: None,
                position_data: None,
            },
        )
        .unwrap();
        assert!(update_annotation(
            &path,
            &UpdateAnnotationInput {
                id: note.id,
                color: None,
                content: Some("Edited recovered note".to_string()),
                position_data: None,
            },
        )
        .unwrap());
        assert!(delete_annotation(&path, &bookmark.id).unwrap());
        let repaired = Document::load(&path).unwrap();
        assert!(!repaired.trailer.has(b"Prev"));
        assert!(!repaired.trailer.has(b"XRefStm"));
        let _ = fs::remove_file(path);
    }
}
