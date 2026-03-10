import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Bot,
  MessageSquare,
  Mic,
  Send,
  Settings,
  Square,
  Trash2,
} from "lucide-react";
import { MarkdownMessage } from "@/components/ai/MarkdownMessage";
import { useAiStore } from "@/stores/ai-store";
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

const MODELS = [
  "gemini-3.1-flash-lite",
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
const SNAPSHOT_MAX_DIMENSION = 1280;
const SNAPSHOT_JPEG_QUALITY = 0.72;

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
          <Bot size={15} />
          AI Assistant
        </div>
        <div className="flex items-center gap-1">
          <button
            className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={() => setSettingsOpen((v) => !v)}
            title="AI settings"
          >
            <Settings size={14} />
          </button>
          <button
            className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
            onClick={clearConversation}
            title="Clear conversation"
          >
            <Trash2 size={14} />
          </button>
        </div>
      </div>

      {settingsOpen && (
        <div className="space-y-2 border-b bg-muted/50 p-3 text-xs">
          <label className="block">
            <span className="mb-1 block text-muted-foreground">Gemini API key</span>
            <input
              type="password"
              className="w-full rounded border bg-background px-2 py-1 outline-none focus:ring-1 focus:ring-primary"
              value={settings.apiKey}
              onChange={(e) => setSettings({ apiKey: e.target.value })}
              placeholder="AIza..."
            />
          </label>

          <label className="block">
            <span className="mb-1 block text-muted-foreground">Model</span>
            <select
              className="w-full rounded border bg-background px-2 py-1 outline-none focus:ring-1 focus:ring-primary"
              value={settings.model}
              onChange={(e) => setSettings({ model: e.target.value })}
            >
              {MODELS.map((m) => (
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
          <div className="rounded border bg-muted/40 p-3 text-xs text-muted-foreground">
            Ask anything about the PDF. The assistant can navigate pages and create
            notes/highlights.
          </div>
        )}

        {messages.map((msg) => (
          <div
            key={msg.id}
            className={cn(
              "max-w-[90%] rounded-lg px-3 py-2 text-sm",
              msg.role === "user"
                ? "ml-auto bg-primary text-primary-foreground"
                : "bg-muted text-foreground",
            )}
          >
            <div className="mb-1 flex items-center gap-1 text-[11px] opacity-70">
              {msg.role === "user" ? <MessageSquare size={12} /> : <Bot size={12} />}
              {msg.role === "user" ? "You" : "Assistant"}
            </div>
            <MarkdownMessage content={msg.content} />
          </div>
        ))}

        {isThinking && (
          <div className="inline-flex items-center gap-2 rounded bg-muted px-3 py-2 text-xs text-muted-foreground">
            <Bot size={12} />
            Thinking...
          </div>
        )}

        {error && (
          <div className="rounded border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive">
            {error}
          </div>
        )}
      </div>

      <div className="border-t p-3">
        <form className="flex items-end gap-2" onSubmit={handleSubmit}>
          <textarea
            className="min-h-[2.5rem] min-w-0 flex-1 resize-none rounded border bg-background px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-primary"
            placeholder="Ask about this document..."
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
                "flex h-10 w-10 items-center justify-center rounded border transition-colors",
                isListening
                  ? "border-red-400 bg-red-100 text-red-600"
                  : "border-border bg-background text-muted-foreground hover:bg-accent hover:text-foreground",
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
              {isListening ? <Square size={14} /> : <Mic size={14} />}
            </button>
          )}

          <button
            type="submit"
            className="flex h-10 w-10 items-center justify-center rounded bg-primary text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
            disabled={!input.trim() || isThinking}
            title="Send"
          >
            <Send size={14} />
          </button>
        </form>
      </div>
    </div>
  );
}
