import { create } from "zustand";
import { generateText } from "ai";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { buildToolModePrompt } from "@/lib/ai-prompts";
import { useAnnotationStore } from "@/stores/annotation-store";
import { usePdfStore } from "@/stores/pdf-store";
import type { Annotation, DocumentInfo } from "@/types";

type AiRole = "user" | "assistant";
type VoiceMode = "off" | "push-to-talk";

type ToolAction =
  | {
      tool: "goToPage";
      args: { pageNumber: number };
    }
  | {
      tool: "addNote";
      args: {
        pageNumber: number;
        text: string;
        x?: number;
        y?: number;
      };
    }
  | {
      tool: "addHighlight";
      args: {
        pageNumber: number;
        text?: string;
        color?: string;
        x?: number;
        y?: number;
        width?: number;
        height?: number;
      };
    };

interface AiMessage {
  id: string;
  role: AiRole;
  content: string;
  createdAt: string;
}

interface AiSettings {
  model: string;
  apiKey: string;
  voiceMode: VoiceMode;
  ttsEnabled: boolean;
}

interface AiPageImageSnapshot {
  pageNumber: number;
  base64Data: string;
  mediaType: string;
  width: number;
  height: number;
}

interface AiContextSnapshot {
  title: string | null;
  numPages: number;
  currentPage: number;
  visiblePages: number[];
  annotations: Annotation[];
  currentPageImage?: AiPageImageSnapshot | null;
}

interface AiState {
  messages: AiMessage[];
  isThinking: boolean;
  error: string | null;
  pageTexts: Record<number, string>;
  settings: AiSettings;
  setSettings: (patch: Partial<AiSettings>) => void;
  addLocalMessage: (
    role: AiRole,
    content: string,
    id?: string,
  ) => string;
  updateLocalMessage: (id: string, content: string) => void;
  setThinkingState: (thinking: boolean) => void;
  setErrorState: (error: string | null) => void;
  loadConversationForDocument: (document: DocumentInfo | null) => void;
  clearConversation: () => void;
  clearDocumentContext: () => void;
  setPageText: (page: number, text: string) => void;
  sendMessage: (input: string, context: AiContextSnapshot) => Promise<void>;
}

const SETTINGS_STORAGE_KEY = "research-reader-ai-settings-v1";
const CONVERSATIONS_STORAGE_KEY = "research-reader-ai-conversations-v1";
const MAX_CONTEXT_CHARS = 120_000;
const DEFAULT_PAGE_WIDTH = 612;
const DEFAULT_PAGE_HEIGHT = 792;
const MAX_STORED_MESSAGES_PER_DOCUMENT = 120;
const MAX_STORED_MESSAGE_CHARS = 12_000;
const MAX_STORED_DOCUMENTS = 25;

const DEFAULT_SETTINGS: AiSettings = {
  model: "gemini-3.1-flash-lite",
  apiKey: "",
  voiceMode: "off",
  ttsEnabled: false,
};

function makeId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `msg_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

function normalizeVoiceMode(value: unknown): VoiceMode {
  return value === "push-to-talk" ? "push-to-talk" : "off";
}

function readSettingsFromStorage(): AiSettings {
  try {
    const raw = localStorage.getItem(SETTINGS_STORAGE_KEY);
    if (!raw) return DEFAULT_SETTINGS;
    const parsed = JSON.parse(raw) as Partial<AiSettings>;
    return {
      ...DEFAULT_SETTINGS,
      ...parsed,
      voiceMode: normalizeVoiceMode(parsed.voiceMode),
    };
  } catch {
    return DEFAULT_SETTINGS;
  }
}

function writeSettingsToStorage(settings: AiSettings) {
  try {
    localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify(settings));
  } catch {
    // Ignore persistence errors.
  }
}

function getConversationDocumentKey(document: DocumentInfo | null): string | null {
  const rawKey = document?.rr_path?.trim() || document?.pdf_path?.trim() || null;
  if (!rawKey) return null;
  return rawKey;
}

function sanitizeStoredMessage(raw: unknown): AiMessage | null {
  if (!raw || typeof raw !== "object") return null;
  const candidate = raw as Partial<AiMessage>;
  const role = candidate.role === "assistant" ? "assistant" : candidate.role === "user" ? "user" : null;
  const content = typeof candidate.content === "string" ? candidate.content : null;
  if (!role || content === null) return null;

  const id =
    typeof candidate.id === "string" && candidate.id.trim().length > 0
      ? candidate.id
      : makeId();
  const createdAt =
    typeof candidate.createdAt === "string" && candidate.createdAt.trim().length > 0
      ? candidate.createdAt
      : new Date().toISOString();

  return { id, role, content, createdAt };
}

function limitMessagesForStorage(messages: AiMessage[]): AiMessage[] {
  return messages
    .slice(-MAX_STORED_MESSAGES_PER_DOCUMENT)
    .map((message) => ({
      ...message,
      content:
        message.content.length > MAX_STORED_MESSAGE_CHARS
          ? `${message.content.slice(0, MAX_STORED_MESSAGE_CHARS)}\n[truncated]`
          : message.content,
    }));
}

function readConversationsFromStorage(): Record<string, AiMessage[]> {
  try {
    const raw = localStorage.getItem(CONVERSATIONS_STORAGE_KEY);
    if (!raw) return {};

    const parsed = JSON.parse(raw) as Record<string, unknown>;
    if (!parsed || typeof parsed !== "object") return {};

    const out: Record<string, AiMessage[]> = {};
    for (const [docKey, value] of Object.entries(parsed)) {
      if (!Array.isArray(value)) continue;
      const messages = value
        .map(sanitizeStoredMessage)
        .filter((message): message is AiMessage => message !== null);
      if (messages.length > 0) {
        out[docKey] = limitMessagesForStorage(messages);
      }
    }

    return out;
  } catch {
    return {};
  }
}

function writeConversationsToStorage(conversations: Record<string, AiMessage[]>) {
  try {
    localStorage.setItem(CONVERSATIONS_STORAGE_KEY, JSON.stringify(conversations));
  } catch {
    // Ignore persistence errors.
  }
}

function loadConversationFromStorage(document: DocumentInfo | null): AiMessage[] {
  const docKey = getConversationDocumentKey(document);
  if (!docKey) return [];

  const conversations = readConversationsFromStorage();
  return limitMessagesForStorage(conversations[docKey] ?? []);
}

function saveConversationToStorage(document: DocumentInfo | null, messages: AiMessage[]) {
  const docKey = getConversationDocumentKey(document);
  if (!docKey) return;

  const conversations = readConversationsFromStorage();
  const bounded = limitMessagesForStorage(messages);

  if (bounded.length === 0) {
    delete conversations[docKey];
    writeConversationsToStorage(conversations);
    return;
  }

  conversations[docKey] = bounded;

  const keys = Object.keys(conversations);
  while (keys.length > MAX_STORED_DOCUMENTS) {
    const oldest = keys.shift();
    if (!oldest) break;
    delete conversations[oldest];
  }

  writeConversationsToStorage(conversations);
}

function clampPage(page: number): number {
  const total = usePdfStore.getState().numPages;
  if (total <= 0) return 1;
  return Math.max(1, Math.min(total, Math.round(page)));
}

function extractJsonObject(text: string): string | null {
  const first = text.indexOf("{");
  const last = text.lastIndexOf("}");
  if (first === -1 || last === -1 || last <= first) return null;
  return text.slice(first, last + 1);
}

function parseModelResponse(rawText: string): {
  reply: string;
  actions: ToolAction[];
} {
  const jsonText = extractJsonObject(rawText) ?? rawText;
  try {
    const parsed = JSON.parse(jsonText) as {
      reply?: unknown;
      actions?: unknown;
    };
    const reply =
      typeof parsed.reply === "string" && parsed.reply.trim().length > 0
        ? parsed.reply.trim()
        : rawText.trim();

    const actions = Array.isArray(parsed.actions)
      ? parsed.actions.filter(
          (a): a is ToolAction =>
            typeof a === "object" &&
            a !== null &&
            "tool" in a &&
            "args" in a &&
            typeof (a as { tool: unknown }).tool === "string",
        )
      : [];

    return { reply, actions };
  } catch {
    return { reply: rawText.trim(), actions: [] };
  }
}

function buildContextBlock(
  pageTexts: Record<number, string>,
  context: AiContextSnapshot,
): string {
  const orderedPages = Object.keys(pageTexts)
    .map(Number)
    .filter((n) => Number.isFinite(n))
    .sort((a, b) => a - b);
  const fullText = orderedPages
    .map((page) => `[Page ${page}] ${pageTexts[page]}`)
    .join("\n");
  const boundedFullText =
    fullText.length > MAX_CONTEXT_CHARS
      ? `${fullText.slice(0, MAX_CONTEXT_CHARS)}\n[truncated]`
      : fullText;

  const visiblePageText = context.visiblePages
    .map((page) => `[Page ${page}] ${pageTexts[page] ?? ""}`)
    .join("\n");

  const annotationSummary = context.annotations
    .slice(-200)
    .map((a) => {
      const text = a.position_data?.selected_text ?? "";
      const note = a.content ?? "";
      return `- (${a.type}) p.${a.page_number} color=${a.color ?? "none"} text="${text}" note="${note}"`;
    })
    .join("\n");

  const currentPageAnnotations = context.annotations
    .filter((a) => a.page_number === context.currentPage)
    .slice(-50)
    .map((a) => {
      const text = a.position_data?.selected_text ?? "";
      const note = a.content ?? "";
      return `- (${a.type}) color=${a.color ?? "none"} text="${text}" note="${note}"`;
    })
    .join("\n");

  const imageSummary = context.currentPageImage
    ? `attached (${context.currentPageImage.width}x${context.currentPageImage.height}, ${context.currentPageImage.mediaType})`
    : "none";

  return [
    `Document title: ${context.title ?? "Untitled"}`,
    `Total pages: ${context.numPages}`,
    `Current page: ${context.currentPage}`,
    `Visible pages: ${context.visiblePages.join(", ") || "none"}`,
    `Current page image: ${imageSummary}`,
    "",
    "Visible page text:",
    visiblePageText || "(none)",
    "",
    "Current page annotations:",
    currentPageAnnotations || "(none)",
    "",
    "Annotations:",
    annotationSummary || "(none)",
    "",
    "Full PDF text:",
    boundedFullText || "(text extraction pending)",
  ].join("\n");
}

function buildConversationBlock(messages: AiMessage[]): string {
  return messages
    .slice(-10)
    .map((m) => `${m.role.toUpperCase()}: ${m.content}`)
    .join("\n");
}

async function callGemini(opts: {
  apiKey: string;
  model: string;
  prompt: string;
  currentPageImage?: AiPageImageSnapshot | null;
}): Promise<{ reply: string; actions: ToolAction[] }> {
  const google = createGoogleGenerativeAI({
    apiKey: opts.apiKey,
  });

  const userContent: Array<
    | { type: "text"; text: string }
    | { type: "image"; image: string; mediaType?: string }
  > = [{ type: "text", text: opts.prompt }];

  if (opts.currentPageImage?.base64Data) {
    userContent.push({
      type: "image",
      image: opts.currentPageImage.base64Data,
      mediaType: opts.currentPageImage.mediaType,
    });
  }

  const { text: rawText } = await generateText({
    model: google(opts.model),
    messages: [{ role: "user", content: userContent }],
    temperature: 0.2,
    maxRetries: 1,
  });

  if (!rawText.trim()) {
    return {
      reply: "I couldn't produce a response.",
      actions: [],
    };
  }

  return parseModelResponse(rawText);
}

async function executeToolAction(action: ToolAction): Promise<string> {
  if (action.tool === "goToPage") {
    const pageNumber = clampPage(action.args.pageNumber);
    usePdfStore.getState().goToPage(pageNumber);
    return `Navigated to page ${pageNumber}.`;
  }

  if (action.tool === "addNote") {
    const pageNumber = clampPage(action.args.pageNumber);
    const noteText = action.args.text?.trim();
    if (!noteText) return "Skipped addNote: empty text.";

    await useAnnotationStore.getState().addNote({
      type: "note",
      page_number: pageNumber,
      content: noteText,
      position_data: {
        rects: [
          {
            x: action.args.x ?? 72,
            y: action.args.y ?? 96,
            width: 0,
            height: 0,
          },
        ],
        page_width: DEFAULT_PAGE_WIDTH,
        page_height: DEFAULT_PAGE_HEIGHT,
        selected_text: null,
        start_offset: null,
        end_offset: null,
      },
    });
    return `Added note on page ${pageNumber}.`;
  }

  const pageNumber = clampPage(action.args.pageNumber);
  const width = action.args.width ?? 220;
  const height = action.args.height ?? 24;
  const x = action.args.x ?? 72;
  const y = action.args.y ?? 96;
  const color = action.args.color ?? "#fef08a";

  await useAnnotationStore.getState().addHighlight({
    type: "highlight",
    page_number: pageNumber,
    color,
    position_data: {
      rects: [{ x, y, width, height }],
      page_width: DEFAULT_PAGE_WIDTH,
      page_height: DEFAULT_PAGE_HEIGHT,
      selected_text: action.args.text ?? null,
      start_offset: null,
      end_offset: null,
    },
  });
  return `Added highlight on page ${pageNumber}.`;
}

export const useAiStore = create<AiState>((set, get) => ({
  messages: [],
  isThinking: false,
  error: null,
  pageTexts: {},
  settings: readSettingsFromStorage(),

  setSettings: (patch) => {
    const next = { ...get().settings, ...patch };
    writeSettingsToStorage(next);
    set({ settings: next });
  },

  addLocalMessage: (role, content, id) => {
    const messageId = id ?? makeId();
    const message: AiMessage = {
      id: messageId,
      role,
      content,
      createdAt: new Date().toISOString(),
    };

    set((state) => ({
      messages: [...state.messages, message],
    }));
    saveConversationToStorage(usePdfStore.getState().document, get().messages);
    return messageId;
  },

  updateLocalMessage: (id, content) => {
    set((state) => ({
      messages: state.messages.map((message) =>
        message.id === id ? { ...message, content } : message,
      ),
    }));
    saveConversationToStorage(usePdfStore.getState().document, get().messages);
  },

  setThinkingState: (thinking) => {
    set({ isThinking: thinking });
  },

  setErrorState: (error) => {
    set({ error });
  },

  loadConversationForDocument: (document) => {
    const messages = loadConversationFromStorage(document);
    set({ messages, error: null });
  },

  clearConversation: () => {
    const currentDoc = usePdfStore.getState().document;
    saveConversationToStorage(currentDoc, []);
    set({ messages: [], error: null });
  },

  clearDocumentContext: () => {
    set({ pageTexts: {}, messages: [], error: null });
  },

  setPageText: (page, text) => {
    const normalized = text.replace(/\s+/g, " ").trim();
    set((state) => {
      if (state.pageTexts[page] === normalized) return state;
      return {
        pageTexts: {
          ...state.pageTexts,
          [page]: normalized,
        },
      };
    });
  },

  sendMessage: async (input, context) => {
    const trimmed = input.trim();
    if (!trimmed) return;

    const { settings, pageTexts } = get();
    if (!settings.apiKey.trim()) {
      set({ error: "Set your Gemini API key in AI settings." });
      return;
    }

    const userMessage: AiMessage = {
      id: makeId(),
      role: "user",
      content: trimmed,
      createdAt: new Date().toISOString(),
    };

    set((state) => ({
      messages: [...state.messages, userMessage],
      isThinking: true,
      error: null,
    }));
    saveConversationToStorage(usePdfStore.getState().document, get().messages);

    try {
      const conversation = buildConversationBlock(get().messages);
      const contextBlock = buildContextBlock(pageTexts, context);
      const prompt = buildToolModePrompt({
        conversation: conversation || "(start of conversation)",
        context: contextBlock,
        latestUserRequest: trimmed,
      });

      const modelOutput = await callGemini({
        apiKey: settings.apiKey.trim(),
        model: settings.model.trim() || DEFAULT_SETTINGS.model,
        prompt,
        currentPageImage: context.currentPageImage,
      });

      const actionResults: string[] = [];
      for (const action of modelOutput.actions.slice(0, 5)) {
        try {
          const result = await executeToolAction(action);
          actionResults.push(result);
        } catch (err) {
          actionResults.push(`Action failed: ${String(err)}`);
        }
      }

      const assistantContent =
        actionResults.length > 0
          ? `${modelOutput.reply}\n\nActions:\n${actionResults.map((r) => `- ${r}`).join("\n")}`
          : modelOutput.reply;

      const assistantMessage: AiMessage = {
        id: makeId(),
        role: "assistant",
        content: assistantContent.trim(),
        createdAt: new Date().toISOString(),
      };

      set((state) => ({
        messages: [...state.messages, assistantMessage],
        isThinking: false,
      }));
      saveConversationToStorage(usePdfStore.getState().document, get().messages);
    } catch (err) {
      const message = String(err);
      set((state) => ({
        isThinking: false,
        error: message,
        messages: [
          ...state.messages,
          {
            id: makeId(),
            role: "assistant",
            content: `I couldn't complete that request: ${message}`,
            createdAt: new Date().toISOString(),
          },
        ],
      }));
      saveConversationToStorage(usePdfStore.getState().document, get().messages);
    }
  },
}));

export type { AiMessage, AiSettings, AiContextSnapshot, VoiceMode };
