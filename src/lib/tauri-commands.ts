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

export async function openFile(
  path: string,
  sessionId: string,
): Promise<DocumentInfo> {
  return invoke<DocumentInfo>("open_file", { path, sessionId });
}

export async function saveFile(sessionId: string): Promise<void> {
  return invoke("save_file", { sessionId });
}

export async function closeFile(sessionId: string): Promise<void> {
  return invoke("close_file", { sessionId });
}

export async function readPdfBytes(sessionId: string): Promise<ArrayBuffer> {
  return invoke<ArrayBuffer>("read_pdf_bytes", { sessionId });
}

export async function getAnnotations(
  sessionId: string,
  pageNumber?: number,
): Promise<Annotation[]> {
  return invoke<Annotation[]>("get_annotations", {
    sessionId,
    pageNumber: pageNumber ?? null,
  });
}

export async function createAnnotation(
  sessionId: string,
  input: CreateAnnotationInput,
): Promise<Annotation> {
  return invoke<Annotation>("create_annotation", { sessionId, input });
}

export async function updateAnnotation(
  sessionId: string,
  input: UpdateAnnotationInput,
): Promise<boolean> {
  return invoke<boolean>("update_annotation", { sessionId, input });
}

export async function deleteAnnotation(
  sessionId: string,
  id: string,
): Promise<boolean> {
  return invoke<boolean>("delete_annotation", { sessionId, id });
}

export async function setDocumentMetadata(
  sessionId: string,
  key: string,
  value: string,
): Promise<void> {
  return invoke("set_document_metadata", { sessionId, key, value });
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
