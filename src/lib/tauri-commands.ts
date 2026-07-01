// Tauri IPC bridge — calls Rust commands from the frontend

import { invoke } from "@tauri-apps/api/core";
import type {
  Annotation,
  CreateAnnotationInput,
  DocumentInfo,
  UpdateAnnotationInput,
} from "@/types";

export interface ChatGptLoginResult {
  account_id: string;
  email: string | null;
}

export interface ChatGptAccessToken {
  access_token: string;
  account_id: string;
}

export interface ChatGptOauthStatus {
  signed_in: boolean;
  email: string | null;
  account_id: string | null;
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

// --- "Sign in with ChatGPT" OAuth ---
// Secrets stay in Rust/keychain; the renderer only ever sees short-lived tokens.

export async function chatgptOauthLogin(): Promise<ChatGptLoginResult> {
  return invoke<ChatGptLoginResult>("chatgpt_oauth_login");
}

export async function chatgptGetAccessToken(): Promise<ChatGptAccessToken> {
  return invoke<ChatGptAccessToken>("chatgpt_get_access_token");
}

export async function chatgptOauthStatus(): Promise<ChatGptOauthStatus> {
  return invoke<ChatGptOauthStatus>("chatgpt_oauth_status");
}

export async function chatgptOauthLogout(): Promise<void> {
  return invoke("chatgpt_oauth_logout");
}
