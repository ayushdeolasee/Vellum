import { useEffect, useCallback, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { usePdfStore } from "@/stores/pdf-store";
import { useAnnotationStore } from "@/stores/annotation-store";
import { useAiStore } from "@/stores/ai-store";
import { PdfViewer } from "@/components/pdf/PdfViewer";
import { WebViewer } from "@/components/web/WebViewer";
import { Toolbar } from "@/components/pdf/Toolbar";
import { TabBar } from "@/components/pdf/TabBar";
import { AnnotationSidebar } from "@/components/annotations/AnnotationSidebar";
import { AiPanel } from "@/components/ai/AiPanel";
import { WelcomeScreen } from "@/components/WelcomeScreen";
import * as commands from "@/lib/tauri-commands";
import { MessageSquare, Sparkles } from "lucide-react";
import { cn } from "@/lib/utils";

export default function App() {
  // Only subscribe to what drives rendering decisions
  const doc = usePdfStore((s) => s.document);
  const activeTabId = usePdfStore((s) => s.activeTabId);
  const loadAnnotations = useAnnotationStore((s) => s.loadAnnotations);
  const clearAnnotations = useAnnotationStore((s) => s.clearAnnotations);
  const clearDocumentContext = useAiStore((s) => s.clearDocumentContext);
  const loadConversationForDocument = useAiStore((s) => s.loadConversationForDocument);

  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [sidebarTab, setSidebarTab] = useState<"annotations" | "ai">("annotations");

  // Load annotations when the document identity changes. Keyed on the path
  // rather than the document object so metadata updates (e.g. a webpage
  // reporting its title) don't wipe the AI context and annotations.
  const docPath = doc?.pdf_path ?? null;
  useEffect(() => {
    if (docPath) {
      clearAnnotations();
      clearDocumentContext();
      loadAnnotations();
      loadConversationForDocument(usePdfStore.getState().document);
    } else {
      clearAnnotations();
      clearDocumentContext();
    }
  }, [
    activeTabId,
    docPath,
    loadAnnotations,
    clearAnnotations,
    clearDocumentContext,
    loadConversationForDocument,
  ]);

  // Auto-save every 30 seconds
  useEffect(() => {
    if (!doc || !activeTabId) return;
    const interval = setInterval(() => {
      commands.saveFile(activeTabId).catch(() => {});
    }, 30000);
    return () => clearInterval(interval);
  }, [activeTabId, doc]);

  // Keyboard shortcuts — uses getState() so the callback never changes
  const handleKeyDown = useCallback(async (e: KeyboardEvent) => {
    const isCtrl = e.ctrlKey || e.metaKey;

    if (isCtrl && e.key === "o") {
      e.preventDefault();
      const selected = await open({
        multiple: true,
        filters: [
          { name: "Documents", extensions: ["pdf", "vellumweb"] },
          { name: "PDF", extensions: ["pdf"] },
          { name: "Vellum Web Archive", extensions: ["vellumweb"] },
        ],
      });
      if (!selected) return;
      await usePdfStore
        .getState()
        .openFiles(Array.isArray(selected) ? selected : [selected]);
    }

    if (isCtrl && e.key === "l") {
      e.preventDefault();
      window.dispatchEvent(new CustomEvent("vellum:add-webpage"));
    }

    if (isCtrl && e.key === "s") {
      e.preventDefault();
      const { activeTabId: sessionId } = usePdfStore.getState();
      if (sessionId) {
        commands.saveFile(sessionId).catch(() => {});
      }
    }

    if (isCtrl && e.key.toLowerCase() === "w") {
      e.preventDefault();
      usePdfStore.getState().closeFile();
    }

    if (isCtrl && /^[1-9]$/.test(e.key)) {
      const index = Number(e.key) - 1;
      const tab = usePdfStore.getState().tabs[index];
      if (tab) {
        e.preventDefault();
        usePdfStore.getState().activateTab(tab.id);
      }
    }

    if (isCtrl && e.key === "=") {
      e.preventDefault();
      usePdfStore.getState().zoomIn();
    }

    if (isCtrl && e.key === "-") {
      e.preventDefault();
      usePdfStore.getState().zoomOut();
    }

    if (isCtrl && e.key === "b") {
      e.preventDefault();
      if (usePdfStore.getState().document) {
        void useAnnotationStore.getState().toggleBookmark();
      }
    }

    if (e.key === "Escape") {
      useAnnotationStore.getState().selectAnnotation(null);
      usePdfStore.getState().setMode("view");
    }

    // N key toggles sticky note mode (only when not typing in an input)
    if (
      e.key === "n" &&
      !isCtrl &&
      !(e.target instanceof HTMLInputElement) &&
      !(e.target instanceof HTMLTextAreaElement)
    ) {
      const { document: d, mode, setMode } = usePdfStore.getState();
      if (d) {
        e.preventDefault();
        setMode(mode === "note" ? "view" : "note");
      }
    }
  }, []);

  useEffect(() => {
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [handleKeyDown]);

  // Reload annotations when an external mutation (e.g. a .vellumweb import
  // merging into the already-active tab) changes them outside the store.
  useEffect(() => {
    const reload = () => {
      if (usePdfStore.getState().document) {
        loadAnnotations();
      }
    };
    window.addEventListener("vellum:annotations-updated", reload);
    return () => window.removeEventListener("vellum:annotations-updated", reload);
  }, [loadAnnotations]);

  if (!doc) {
    return (
      <div className="flex h-screen w-screen flex-col overflow-hidden">
        <TabBar />
        <Toolbar />
        <WelcomeScreen />
      </div>
    );
  }

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden">
      <TabBar />
      <Toolbar
        sidebarOpen={sidebarOpen}
        onToggleSidebar={() => setSidebarOpen((v) => !v)}
      />
      <div className="flex min-h-0 flex-1 overflow-hidden">
        {/* Document viewer (main area) */}
        {doc.kind === "web" ? (
          <WebViewer key={activeTabId} />
        ) : (
          <PdfViewer key={activeTabId} />
        )}

        {/* Annotation / AI side panel */}
        {sidebarOpen && (
          <div className="flex min-h-0 w-80 flex-shrink-0 flex-col overflow-hidden border-l bg-background">
            {/* Segmented control */}
            <div className="flex-shrink-0 p-2">
              <div className="flex gap-1 rounded-lg bg-muted p-1">
                <button
                  className={cn(
                    "focus-ring flex flex-1 items-center justify-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium transition-colors",
                    sidebarTab === "annotations"
                      ? "bg-surface text-foreground shadow-soft"
                      : "text-muted-foreground hover:text-foreground",
                  )}
                  onClick={() => setSidebarTab("annotations")}
                >
                  <MessageSquare size={13} />
                  Annotations
                </button>
                <button
                  className={cn(
                    "focus-ring flex flex-1 items-center justify-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium transition-colors",
                    sidebarTab === "ai"
                      ? "bg-surface text-foreground shadow-soft"
                      : "text-muted-foreground hover:text-foreground",
                  )}
                  onClick={() => setSidebarTab("ai")}
                >
                  <Sparkles size={13} />
                  AI
                </button>
              </div>
            </div>

            <div className="min-h-0 flex-1 overflow-hidden overscroll-contain border-t">
              {sidebarTab === "annotations" ? <AnnotationSidebar /> : <AiPanel />}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
