import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Mic,
  Send,
  Settings,
  Sparkles,
  Square,
  Trash2,
  User,
} from "lucide-react";
import { MarkdownMessage } from "@/components/ai/MarkdownMessage";
import { IconButton } from "@/components/ui/IconButton";
import { useAiStore } from "@/stores/ai-store";
import * as commands from "@/lib/tauri-commands";
import { cn } from "@/lib/utils";
import { usePdfStore } from "@/stores/pdf-store";
import { useAnnotationStore } from "@/stores/annotation-store";

type SpeechRecognitionLike = {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: SpeechRecognitionEvent) => void) | null;
  onerror: ((event: Event) => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
};

const GEMINI_MODELS = [
  "gemini-3.1-flash-lite-preview",
  "gemini-3-pro-preview",
  "gemini-3-flash-preview",
  "gemini-2.5-pro",
  "gemini-2.5-flash",
  "gemini-2.5-flash-lite",
  "gemini-2.0-flash",
  "gemini-2.0-flash-lite",
  "gemini-1.5-pro",
  "gemini-1.5-flash",
];

const OPENAI_MODELS = [
  "gpt-5.5",
  "gpt-5.5-2026-04-23",
  "gpt-5.4-mini",
  "gpt-5.4",
  "gpt-5",
  "gpt-5-mini",
  "gpt-4.1",
  "gpt-4.1-mini",
];

// Models billable against a ChatGPT subscription via the codex/responses endpoint.
const CHATGPT_MODELS = [
  "gpt-5.5-codex",
  "gpt-5.5",
  "gpt-5.4-codex",
];

const SNAPSHOT_MAX_DIMENSION = 1280;
const SNAPSHOT_JPEG_QUALITY = 0.72;

function getProviderModels(provider: string): string[] {
  if (provider === "chatgpt") return CHATGPT_MODELS;
  return provider === "openai" ? OPENAI_MODELS : GEMINI_MODELS;
}

export function AiPanel() {
  const messages = useAiStore((s) => s.messages);
  const isThinking = useAiStore((s) => s.isThinking);
  const error = useAiStore((s) => s.error);
  const settings = useAiStore((s) => s.settings);
  const setSettings = useAiStore((s) => s.setSettings);
  const clearConversation = useAiStore((s) => s.clearConversation);
  const sendMessage = useAiStore((s) => s.sendMessage);
  const setErrorState = useAiStore((s) => s.setErrorState);

  const doc = usePdfStore((s) => s.document);
  const currentPage = usePdfStore((s) => s.currentPage);
  const numPages = usePdfStore((s) => s.numPages);
  const visiblePages = usePdfStore((s) => s.visiblePages);
  const annotations = useAnnotationStore((s) => s.annotations);

  const [input, setInput] = useState("");
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [isListening, setIsListening] = useState(false);
  const [chatgptStatus, setChatgptStatus] =
    useState<commands.ChatGptOauthStatus | null>(null);
  const [chatgptBusy, setChatgptBusy] = useState(false);

  const listRef = useRef<HTMLDivElement>(null);
  const lastSpokenMessageIdRef = useRef<string | null>(null);
  const pushToTalkRecognitionRef = useRef<SpeechRecognitionLike | null>(null);
  const pushToTalkListeningRef = useRef(false);

  useEffect(() => {
    if (!listRef.current) return;
    listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [messages, isThinking]);

  const latestAssistantMessage = useMemo(() => {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === "assistant") return messages[i];
    }
    return null;
  }, [messages]);

  const getSpeechRecognitionCtor = useCallback(() => {
    return (
      (window as unknown as { SpeechRecognition?: new () => SpeechRecognitionLike })
        .SpeechRecognition ??
      (window as unknown as {
        webkitSpeechRecognition?: new () => SpeechRecognitionLike;
      }).webkitSpeechRecognition
    );
  }, []);

  const captureCurrentPageImage = useCallback(() => {
    const pageRoot = window.document.querySelector(
      `[data-page-number="${currentPage}"]`,
    ) as HTMLElement | null;
    if (!pageRoot) return null;

    const sourceCanvas = pageRoot.querySelector("canvas");
    if (!(sourceCanvas instanceof HTMLCanvasElement)) return null;
    if (sourceCanvas.width < 2 || sourceCanvas.height < 2) return null;

    try {
      let outputCanvas: HTMLCanvasElement = sourceCanvas;
      const maxDimension = Math.max(sourceCanvas.width, sourceCanvas.height);

      if (maxDimension > SNAPSHOT_MAX_DIMENSION) {
        const scale = SNAPSHOT_MAX_DIMENSION / maxDimension;
        const targetWidth = Math.max(1, Math.round(sourceCanvas.width * scale));
        const targetHeight = Math.max(1, Math.round(sourceCanvas.height * scale));

        const resizedCanvas = window.document.createElement("canvas");
        resizedCanvas.width = targetWidth;
        resizedCanvas.height = targetHeight;
        const ctx = resizedCanvas.getContext("2d");
        if (!ctx) return null;

        ctx.drawImage(sourceCanvas, 0, 0, targetWidth, targetHeight);
        outputCanvas = resizedCanvas;
      }

      const dataUrl = outputCanvas.toDataURL("image/jpeg", SNAPSHOT_JPEG_QUALITY);
      const match = dataUrl.match(/^data:(.+);base64,(.+)$/);
      if (!match) return null;

      return {
        pageNumber: currentPage,
        mediaType: match[1],
        base64Data: match[2],
        width: outputCanvas.width,
        height: outputCanvas.height,
      };
    } catch {
      return null;
    }
  }, [currentPage]);

  const sendWithContext = useCallback(
    async (rawText: string) => {
      const trimmed = rawText.trim();
      if (!trimmed || isThinking) return;

      await sendMessage(trimmed, {
        title: doc?.title ?? null,
        numPages,
        currentPage,
        visiblePages,
        annotations,
        currentPageImage: captureCurrentPageImage(),
      });
    },
    [
      annotations,
      captureCurrentPageImage,
      currentPage,
      doc?.title,
      isThinking,
      numPages,
      sendMessage,
      visiblePages,
    ],
  );

  const createPushToTalkRecognition = useCallback(() => {
    const ctor = getSpeechRecognitionCtor();
    if (!ctor) return null;

    const recognition = new ctor();
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.lang = "en-US";

    recognition.onresult = (event) => {
      const transcript = Array.from(event.results)
        .map((result) => result[0]?.transcript ?? "")
        .join(" ")
        .trim();

      if (transcript) {
        setInput((prev) => (prev ? `${prev} ${transcript}` : transcript));
      }
    };

    recognition.onerror = () => {
      pushToTalkListeningRef.current = false;
      if (settings.voiceMode === "push-to-talk") {
        setIsListening(false);
      }
    };

    recognition.onend = () => {
      pushToTalkListeningRef.current = false;
      if (settings.voiceMode === "push-to-talk") {
        setIsListening(false);
      }
    };

    return recognition;
  }, [getSpeechRecognitionCtor, settings.voiceMode]);

  const handlePushToTalkStart = useCallback(() => {
    if (settings.voiceMode !== "push-to-talk") return;
    if (pushToTalkListeningRef.current) return;

    const recognition =
      pushToTalkRecognitionRef.current ?? createPushToTalkRecognition();
    if (!recognition) {
      setErrorState("Speech recognition is not available in this environment.");
      return;
    }
    pushToTalkRecognitionRef.current = recognition;

    try {
      pushToTalkListeningRef.current = true;
      setErrorState(null);
      setIsListening(true);
      recognition.start();
    } catch {
      pushToTalkListeningRef.current = false;
      setIsListening(false);
    }
  }, [createPushToTalkRecognition, setErrorState, settings.voiceMode]);

  const handlePushToTalkStop = useCallback(() => {
    if (!pushToTalkListeningRef.current) return;

    pushToTalkListeningRef.current = false;
    if (settings.voiceMode === "push-to-talk") {
      setIsListening(false);
    }

    try {
      pushToTalkRecognitionRef.current?.stop();
    } catch {
      // Ignore recognition stop errors.
    }
  }, [settings.voiceMode]);

  useEffect(() => {
    if (!settings.ttsEnabled) return;
    if (isThinking) return;
    if (!latestAssistantMessage) return;
    if (latestAssistantMessage.id === lastSpokenMessageIdRef.current) return;
    if (!("speechSynthesis" in window)) return;

    lastSpokenMessageIdRef.current = latestAssistantMessage.id;
    const synth = window.speechSynthesis;
    synth.cancel();

    const utterance = new SpeechSynthesisUtterance(latestAssistantMessage.content);
    utterance.rate = 1;
    utterance.pitch = 1;
    synth.speak(utterance);
  }, [isThinking, latestAssistantMessage, settings.ttsEnabled]);

  useEffect(() => {
    return () => {
      handlePushToTalkStop();
      if ("speechSynthesis" in window) {
        window.speechSynthesis.cancel();
      }
    };
  }, [handlePushToTalkStop]);

  // Load the current ChatGPT sign-in state for the settings UI.
  useEffect(() => {
    let cancelled = false;
    commands
      .chatgptOauthStatus()
      .then((status) => {
        if (cancelled) return;
        setChatgptStatus(status);
        // Mirror the (non-secret) email into settings for display continuity.
        setSettings({ chatgptAccountEmail: status.email });
      })
      .catch(() => {
        if (!cancelled) setChatgptStatus({ signed_in: false, email: null, account_id: null });
      });
    return () => {
      cancelled = true;
    };
  }, [setSettings]);

  const handleChatgptSignIn = useCallback(async () => {
    setChatgptBusy(true);
    setErrorState(null);
    try {
      const result = await commands.chatgptOauthLogin();
      setChatgptStatus({
        signed_in: true,
        email: result.email,
        account_id: result.account_id,
      });
      setSettings({ chatgptAccountEmail: result.email });
    } catch (err) {
      setErrorState(`ChatGPT sign-in failed: ${String(err)}`);
    } finally {
      setChatgptBusy(false);
    }
  }, [setErrorState, setSettings]);

  const handleChatgptSignOut = useCallback(async () => {
    setChatgptBusy(true);
    try {
      await commands.chatgptOauthLogout();
    } catch {
      // Ignore logout errors; treat as signed out regardless.
    } finally {
      setChatgptStatus({ signed_in: false, email: null, account_id: null });
      setSettings({ chatgptAccountEmail: null });
      setChatgptBusy(false);
    }
  }, [setSettings]);

  const handleSubmit = useCallback(
    async (e?: React.FormEvent) => {
      e?.preventDefault();
      const trimmed = input.trim();
      if (!trimmed || isThinking) return;

      setInput("");
      await sendWithContext(trimmed);
    },
    [input, isThinking, sendWithContext],
  );

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between border-b px-3 py-2">
        <div className="flex items-center gap-2 text-sm font-medium">
          <Sparkles size={15} className="text-primary" />
          AI Assistant
        </div>
        <div className="flex items-center gap-0.5">
          <IconButton
            variant={settingsOpen ? "active" : "ghost"}
            onClick={() => setSettingsOpen((v) => !v)}
            title="AI settings"
          >
            <Settings size={15} />
          </IconButton>
          <IconButton onClick={clearConversation} title="Clear conversation">
            <Trash2 size={15} />
          </IconButton>
        </div>
      </div>

      {settingsOpen && (
        <div className="space-y-2.5 border-b bg-surface-muted p-3 text-xs">
          <label className="block">
            <span className="mb-1 block text-muted-foreground">Provider</span>
            <select
              className="w-full rounded border bg-background px-2 py-1 outline-none focus:ring-1 focus:ring-primary"
              value={settings.provider}
              onChange={(e) => {
                const provider =
                  e.target.value === "chatgpt"
                    ? "chatgpt"
                    : e.target.value === "openai"
                    ? "openai"
                    : "gemini";
                setSettings({ provider });
              }}
            >
              <option value="gemini">Gemini</option>
              <option value="openai">OpenAI API</option>
              <option value="chatgpt">ChatGPT (subscription)</option>
            </select>
          </label>

          {settings.provider === "chatgpt" ? (
            <div className="space-y-1.5">
              <span className="block text-muted-foreground">ChatGPT account</span>
              {chatgptStatus?.signed_in ? (
                <div className="flex items-center justify-between gap-2 rounded border bg-background px-2 py-1.5">
                  <span className="min-w-0 truncate text-foreground">
                    {chatgptStatus.email ?? "Signed in"}
                  </span>
                  <button
                    type="button"
                    className="focus-ring flex-shrink-0 rounded border px-2 py-0.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground disabled:opacity-40"
                    onClick={handleChatgptSignOut}
                    disabled={chatgptBusy}
                  >
                    Sign out
                  </button>
                </div>
              ) : (
                <button
                  type="button"
                  className="focus-ring w-full rounded bg-primary px-2 py-1.5 text-primary-foreground transition-colors hover:bg-primary-hover disabled:opacity-40"
                  onClick={handleChatgptSignIn}
                  disabled={chatgptBusy}
                >
                  {chatgptBusy ? "Waiting for browser…" : "Sign in with ChatGPT"}
                </button>
              )}
            </div>
          ) : (
            <label className="block">
              <span className="mb-1 block text-muted-foreground">
                {settings.provider === "openai" ? "OpenAI API key" : "Gemini API key"}
              </span>
              <input
                type="password"
                className="w-full rounded border bg-background px-2 py-1 outline-none focus:ring-1 focus:ring-primary"
                value={
                  settings.provider === "openai"
                    ? settings.openaiApiKey
                    : settings.apiKey
                }
                onChange={(e) =>
                  setSettings(
                    settings.provider === "openai"
                      ? { openaiApiKey: e.target.value }
                      : { apiKey: e.target.value },
                  )
                }
                placeholder={settings.provider === "openai" ? "sk-..." : "AIza..."}
              />
            </label>
          )}

          <label className="block">
            <span className="mb-1 block text-muted-foreground">Model</span>
            <select
              className="w-full rounded border bg-background px-2 py-1 outline-none focus:ring-1 focus:ring-primary"
              value={
                settings.provider === "chatgpt"
                  ? settings.chatgptModel
                  : settings.provider === "openai"
                  ? settings.openaiModel
                  : settings.model
              }
              onChange={(e) =>
                setSettings(
                  settings.provider === "chatgpt"
                    ? { chatgptModel: e.target.value }
                    : settings.provider === "openai"
                    ? { openaiModel: e.target.value }
                    : { model: e.target.value },
                )
              }
            >
              {getProviderModels(settings.provider).map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
            </select>
          </label>

          <label className="block">
            <span className="mb-1 block text-muted-foreground">Voice mode</span>
            <select
              className="w-full rounded border bg-background px-2 py-1 outline-none focus:ring-1 focus:ring-primary"
              value={settings.voiceMode}
              onChange={(e) => {
                const nextVoiceMode = e.target.value as "off" | "push-to-talk";
                if (nextVoiceMode !== "push-to-talk") {
                  handlePushToTalkStop();
                }
                setSettings({ voiceMode: nextVoiceMode });
              }}
            >
              <option value="off">Off</option>
              <option value="push-to-talk">Push-to-talk</option>
            </select>
          </label>

          <label className="flex items-center gap-2 text-muted-foreground">
            <input
              type="checkbox"
              checked={settings.ttsEnabled}
              onChange={(e) => setSettings({ ttsEnabled: e.target.checked })}
            />
            Speak assistant responses (TTS)
          </label>
        </div>
      )}

      <div
        ref={listRef}
        className="min-h-0 flex-1 space-y-3 overflow-auto overscroll-contain px-3 py-3"
      >
        {messages.length === 0 && (
          <div className="flex flex-col items-center gap-3 px-4 py-8 text-center">
            <span className="flex h-12 w-12 items-center justify-center rounded-full border border-border bg-muted text-primary">
              <Sparkles size={20} strokeWidth={1.75} />
            </span>
            <p className="text-xs leading-relaxed text-muted-foreground">
              Ask anything about this document. The assistant can read the page,
              jump around, and create notes and highlights for you.
            </p>
          </div>
        )}

        {messages.map((msg) => (
          <div
            key={msg.id}
            className={cn(
              "flex flex-col gap-1",
              msg.role === "user" ? "items-end" : "items-start",
            )}
          >
            <div className="flex items-center gap-1 px-1 text-[11px] font-medium text-muted-foreground">
              {msg.role === "user" ? <User size={11} /> : <Sparkles size={11} />}
              {msg.role === "user" ? "You" : "Assistant"}
            </div>
            <div
              className={cn(
                "max-w-[92%] rounded-xl px-3 py-2 text-sm",
                msg.role === "user"
                  ? "rounded-tr-sm bg-primary text-primary-foreground"
                  : "rounded-tl-sm border border-border bg-surface text-foreground",
              )}
            >
              <MarkdownMessage content={msg.content} />
            </div>
          </div>
        ))}

        {isThinking && (
          <div className="inline-flex items-center gap-2 rounded-xl border border-border bg-surface px-3 py-2 text-xs text-muted-foreground">
            <Sparkles size={12} className="animate-pulse text-primary" />
            Thinking…
          </div>
        )}

        {error && (
          <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive">
            {error}
          </div>
        )}
      </div>

      <div className="border-t p-3">
        <form
          className="focus-within:border-primary/60 flex items-end gap-2 rounded-xl border border-border bg-surface p-1.5 transition-colors"
          onSubmit={handleSubmit}
        >
          <textarea
            className="min-h-[2.5rem] min-w-0 flex-1 resize-none bg-transparent px-2 py-1.5 text-sm text-foreground outline-none placeholder:text-muted-foreground"
            placeholder="Ask about this document…"
            value={input}
            rows={2}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                handleSubmit();
              }
            }}
          />

          {settings.voiceMode === "push-to-talk" && (
            <button
              type="button"
              className={cn(
                "focus-ring flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg transition-colors",
                isListening
                  ? "bg-destructive text-destructive-foreground"
                  : "text-muted-foreground hover:bg-accent hover:text-foreground",
              )}
              onMouseDown={handlePushToTalkStart}
              onMouseUp={handlePushToTalkStop}
              onMouseLeave={handlePushToTalkStop}
              onTouchStart={(e) => {
                e.preventDefault();
                handlePushToTalkStart();
              }}
              onTouchEnd={(e) => {
                e.preventDefault();
                handlePushToTalkStop();
              }}
              title="Push to talk"
            >
              {isListening ? <Square size={15} /> : <Mic size={15} />}
            </button>
          )}

          <button
            type="submit"
            className="focus-ring flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg bg-primary text-primary-foreground transition-colors hover:bg-primary-hover disabled:opacity-40"
            disabled={!input.trim() || isThinking}
            title="Send message"
          >
            <Send size={15} />
          </button>
        </form>
      </div>
    </div>
  );
}
