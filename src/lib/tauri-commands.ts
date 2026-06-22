// Tauri IPC bridge — calls Rust commands from the frontend

import { invoke } from "@tauri-apps/api/core";
import type {
  Annotation,
  CreateAnnotationInput,
  DocumentInfo,
  UpdateAnnotationInput,
} from "@/types";

interface CodexAiImageInput {
  base64_data: string;
  media_type: string;
}

export async function openFile(path: string): Promise<DocumentInfo> {
  return invoke<DocumentInfo>("open_file", { path });
}

export async function saveFile(): Promise<void> {
  return invoke("save_file");
}

export async function closeFile(): Promise<void> {
  return invoke("close_file");
}

export async function readPdfBytes(): Promise<ArrayBuffer> {
  return invoke<ArrayBuffer>("read_pdf_bytes");
}

export async function getAnnotations(
  pageNumber?: number,
): Promise<Annotation[]> {
  return invoke<Annotation[]>("get_annotations", {
    pageNumber: pageNumber ?? null,
  });
}

export async function createAnnotation(
  input: CreateAnnotationInput,
): Promise<Annotation> {
  return invoke<Annotation>("create_annotation", { input });
}

export async function updateAnnotation(
  input: UpdateAnnotationInput,
): Promise<boolean> {
  return invoke<boolean>("update_annotation", { input });
}

export async function deleteAnnotation(id: string): Promise<boolean> {
  return invoke<boolean>("delete_annotation", { id });
}

export async function setDocumentMetadata(
  key: string,
  value: string,
): Promise<void> {
  return invoke("set_document_metadata", { key, value });
}

export async function runCodexAi(
  prompt: string,
  model: string,
  image?: CodexAiImageInput | null,
): Promise<string> {
  return invoke<string>("run_codex_ai", {
    prompt,
    model,
    image: image ?? null,
  });
}
