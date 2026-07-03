import { useCallback, useEffect, useRef, useState } from "react";
import { open, save } from "@tauri-apps/plugin-dialog";
import { usePdfStore } from "@/stores/pdf-store";
import { useAiStore } from "@/stores/ai-store";
import type { AppUpdate, AppUpdateDownloadEvent } from "@/lib/app-updates";
import { checkForAppUpdate, relaunchForUpdate } from "@/lib/app-updates";
import * as commands from "@/lib/tauri-commands";
import {
  FolderOpen,
  Globe,
  ZoomIn,
  ZoomOut,
  ArrowLeft,
  ArrowRight,
  ChevronLeft,
  ChevronRight,
  Save,
  Bookmark,
  BookmarkPlus,
  StickyNote,
  Download,
  FileDown,
  LoaderCircle,
  RefreshCw,
  PanelRight,
} from "lucide-react";
import { useAnnotationStore, findCurrentBookmark } from "@/stores/annotation-store";
import { IconButton } from "@/components/ui/IconButton";
import { ThemeToggle } from "@/components/ui/ThemeToggle";
import { cn, shortcut } from "@/lib/utils";

function Divider() {
  return <div className="mx-1.5 h-5 w-px flex-shrink-0 bg-border" aria-hidden />;
}

interface ToolbarProps {
  sidebarOpen?: boolean;
  onToggleSidebar?: () => void;
}

export function Toolbar({ sidebarOpen, onToggleSidebar }: ToolbarProps) {
  const {
    document: doc,
    activeTabId,
    currentPage,
    numPages,
    zoom,
    mode,
    openFiles,
    openUrl,
    zoomIn,
    zoomOut,
    setZoom,
    goToPage,
    setMode,
  } = usePdfStore();

  const { annotations, toggleBookmark } = useAnnotationStore();
  const webVisibleRange = usePdfStore((s) => s.webVisibleRange);
  const isWeb = doc?.kind === "web";

  // "Add webpage" URL prompt (also opened via Cmd/Ctrl+L)
  const [urlPromptOpen, setUrlPromptOpen] = useState(false);
  const [urlInput, setUrlInput] = useState("");
  const urlInputRef = useRef<HTMLInputElement>(null);

  // Saved-to-library state for the active webpage tab
  const [pageSaved, setPageSaved] = useState(false);

  useEffect(() => {
    const openPrompt = () => setUrlPromptOpen(true);
    window.addEventListener("vellum:add-webpage", openPrompt);
    return () => window.removeEventListener("vellum:add-webpage", openPrompt);
  }, []);

  useEffect(() => {
    if (urlPromptOpen) {
      setUrlInput("");
      requestAnimationFrame(() => urlInputRef.current?.focus());
    }
  }, [urlPromptOpen]);

  useEffect(() => {
    setPageSaved(false);
    if (!isWeb || !activeTabId) return;
    let cancelled = false;
    commands
      .getWebpageSaved(activeTabId)
      .then((saved) => {
        if (!cancelled) setPageSaved(saved);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [isWeb, activeTabId, doc?.pdf_path]);

  const handleSubmitUrl = async () => {
    const value = urlInput.trim();
    setUrlPromptOpen(false);
    if (!value) return;
    await openUrl(value);
  };

  const handleToggleSavedPage = async () => {
    if (!activeTabId) return;
    const next = !pageSaved;
    setPageSaved(next);
    try {
      await commands.setWebpageSaved(activeTabId, next);
    } catch {
      setPageSaved(!next);
    }
  };

  const handleWebHistory = (delta: number) => {
    const nav = (window as unknown as Record<string, unknown>).__webHistory as
      | ((delta: number) => void)
      | undefined;
    nav?.(delta);
  };

  // .vellumweb export state for the active web tab
  const [exportState, setExportState] = useState<{
    status: "idle" | "exporting" | "done" | "error";
    detail: string;
  }>({ status: "idle", detail: "" });

  useEffect(() => {
    setExportState({ status: "idle", detail: "" });
  }, [activeTabId, doc?.pdf_path]);

  const handleExportVellumweb = async () => {
    if (!activeTabId || !doc) return;

    const slug =
      (doc.title ?? "")
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "")
        .slice(0, 60) || "article";
    const destPath = await save({
      defaultPath: `${slug}.vellumweb`,
      filters: [{ name: "Vellum Web Archive", extensions: ["vellumweb"] }],
    });
    if (!destPath) return;

    const pageTexts = useAiStore.getState().pageTexts;
    const pages = Object.keys(pageTexts)
      .map(Number)
      .filter((n) => Number.isFinite(n))
      .sort((a, b) => a - b)
      .map((number) => ({ number, text: pageTexts[number] }));

    setExportState({ status: "exporting", detail: "Exporting…" });
    try {
      const summary = await commands.exportVellumweb(activeTabId, destPath, pages);
      const sizeMb = (summary.bytes / (1024 * 1024)).toFixed(2);
      setExportState({
        status: "done",
        detail: `Exported ${sizeMb} MB (${summary.asset_count} assets${
          summary.assets_skipped > 0 ? `, ${summary.assets_skipped} skipped` : ""
        })`,
      });
    } catch (err) {
      setExportState({ status: "error", detail: String(err) });
    }
  };

  // Find the bookmark at the current reading position (current page for PDFs,
  // the on-screen anchor for webpages).
  const currentBookmark = findCurrentBookmark(
    annotations,
    doc?.kind,
    currentPage,
    webVisibleRange,
  );
  const isBookmarked = !!currentBookmark;

  // Local state for the page number input so typing isn't interrupted
  const [pageInput, setPageInput] = useState(String(currentPage));
  const [updateStatus, setUpdateStatus] = useState<
    "idle" | "checking" | "available" | "downloading" | "restarting" | "error"
  >("idle");
  const [updateMessage, setUpdateMessage] = useState("Check for updates");
  const [availableUpdateVersion, setAvailableUpdateVersion] = useState<string | null>(
    null,
  );
  const [availableUpdateNotes, setAvailableUpdateNotes] = useState<string | null>(
    null,
  );
  const [downloadProgress, setDownloadProgress] = useState<number | null>(null);
  const pendingUpdateRef = useRef<AppUpdate | null>(null);

  useEffect(() => {
    setPageInput(String(currentPage));
  }, [currentPage]);

  const clearPendingUpdate = useCallback(async () => {
    const currentUpdate = pendingUpdateRef.current;
    pendingUpdateRef.current = null;

    if (currentUpdate) {
      await currentUpdate.close().catch(() => {});
    }
  }, []);

  const handleCheckForUpdates = useCallback(
    async (silent = false) => {
      setDownloadProgress(null);
      setUpdateStatus("checking");
      if (!silent) {
        setUpdateMessage("Checking for updates...");
      }

      try {
        const nextUpdate = await checkForAppUpdate();
        await clearPendingUpdate();

        if (!nextUpdate) {
          setAvailableUpdateVersion(null);
          setAvailableUpdateNotes(null);
          setUpdateStatus("idle");
          setUpdateMessage("You are up to date");
          return;
        }

        pendingUpdateRef.current = nextUpdate;
        setAvailableUpdateVersion(nextUpdate.version);
        setAvailableUpdateNotes(nextUpdate.body ?? null);
        setUpdateStatus("available");
        setUpdateMessage(`Update ${nextUpdate.version} is ready to install`);
      } catch (error) {
        console.error("[Toolbar] Failed to check for updates:", error);
        await clearPendingUpdate();
        setAvailableUpdateVersion(null);
        setAvailableUpdateNotes(null);

        if (silent) {
          setUpdateStatus("idle");
          setUpdateMessage("Check for updates");
          return;
        }

        setUpdateStatus("error");
        setUpdateMessage(
          error instanceof Error ? error.message : "Failed to check for updates",
        );
      }
    },
    [clearPendingUpdate],
  );

  const handleInstallUpdate = useCallback(async () => {
    const pendingUpdate = pendingUpdateRef.current;
    if (!pendingUpdate) {
      await handleCheckForUpdates();
      return;
    }

    let downloadedBytes = 0;
    let contentLength = 0;

    setDownloadProgress(0);
    setUpdateStatus("downloading");
    setUpdateMessage(`Downloading ${pendingUpdate.version}...`);

    try {
      await pendingUpdate.downloadAndInstall((event: AppUpdateDownloadEvent) => {
        switch (event.event) {
          case "Started":
            contentLength = event.data.contentLength ?? 0;
            setDownloadProgress(0);
            break;
          case "Progress":
            downloadedBytes += event.data.chunkLength;
            if (contentLength > 0) {
              setDownloadProgress(
                Math.min(100, Math.round((downloadedBytes / contentLength) * 100)),
              );
            }
            break;
          case "Finished":
            setDownloadProgress(100);
            break;
        }
      });

      setUpdateStatus("restarting");
      setUpdateMessage("Restarting to finish the update...");
      await clearPendingUpdate();
      await relaunchForUpdate();
    } catch (error) {
      console.error("[Toolbar] Failed to install update:", error);
      setUpdateStatus("error");
      setUpdateMessage(
        error instanceof Error ? error.message : "Failed to install update",
      );
    }
  }, [clearPendingUpdate, handleCheckForUpdates]);

  useEffect(() => {
    void handleCheckForUpdates(true);

    return () => {
      void clearPendingUpdate();
    };
  }, [clearPendingUpdate, handleCheckForUpdates]);

  const commitPageInput = () => {
    const val = parseInt(pageInput, 10);
    if (!isNaN(val) && val >= 1 && val <= numPages) {
      goToPage(val);
    } else {
      setPageInput(String(currentPage));
    }
  };

  const handleOpen = async () => {
    const selected = await open({
      multiple: true,
      filters: [
        { name: "Documents", extensions: ["pdf", "vellumweb"] },
        { name: "PDF", extensions: ["pdf"] },
        { name: "Vellum Web Archive", extensions: ["vellumweb"] },
      ],
    });
    if (!selected) return;
    await openFiles(Array.isArray(selected) ? selected : [selected]);
  };

  const handleSave = async () => {
    if (!activeTabId) return;
    try {
      await commands.saveFile(activeTabId);
    } catch {
      // TODO: show error toast
    }
  };

  const handleBookmark = async () => {
    await toggleBookmark();
  };

  const handleResetZoom = () => {
    const zoomTo = (window as unknown as Record<string, unknown>)
      .__zoomPdfTo as ((targetZoom: number) => void) | undefined;
    if (zoomTo) {
      zoomTo(1);
    } else {
      setZoom(1);
    }
  };

  const updateButtonTitle = availableUpdateNotes
    ? `${updateMessage}\n\n${availableUpdateNotes}`
    : updateMessage;

  const updateDisabled =
    updateStatus === "checking" ||
    updateStatus === "downloading" ||
    updateStatus === "restarting";

  const showUpdateStatusChip =
    updateStatus === "available" ||
    updateStatus === "downloading" ||
    updateStatus === "restarting" ||
    updateStatus === "error";

  let updateStatusLabel = "";
  if (updateStatus === "available" && availableUpdateVersion) {
    updateStatusLabel = `Update ${availableUpdateVersion}`;
  } else if (updateStatus === "downloading") {
    updateStatusLabel =
      downloadProgress === null
        ? "Downloading update"
        : `Downloading ${downloadProgress}%`;
  } else if (updateStatus === "restarting") {
    updateStatusLabel = "Restarting...";
  } else if (updateStatus === "error") {
    updateStatusLabel = "Update failed";
  }

  return (
    <div className="relative flex h-11 items-center gap-0.5 border-b bg-background px-2">
      {/* File operations */}
      <IconButton onClick={handleOpen} title={`Open file (${shortcut("O")})`}>
        <FolderOpen size={16} />
      </IconButton>

      <IconButton
        variant={urlPromptOpen ? "active" : "ghost"}
        onClick={() => setUrlPromptOpen((v) => !v)}
        title={`Add webpage (${shortcut("L")})`}
      >
        <Globe size={16} />
      </IconButton>

      {urlPromptOpen && (
        <div className="absolute left-2 top-11 z-50 mt-1 flex w-96 gap-1.5 rounded-lg border bg-background p-2 shadow-lg">
          <input
            ref={urlInputRef}
            type="text"
            className="focus-ring h-8 flex-1 rounded-md border border-border bg-surface px-2 text-sm text-foreground"
            placeholder="Paste an article URL…"
            value={urlInput}
            onChange={(e) => setUrlInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") void handleSubmitUrl();
              if (e.key === "Escape") setUrlPromptOpen(false);
            }}
          />
          <button
            className="focus-ring h-8 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90"
            onClick={() => void handleSubmitUrl()}
          >
            Open
          </button>
        </div>
      )}

      {doc && !isWeb && (
        <IconButton onClick={handleSave} title={`Save (${shortcut("S")})`}>
          <Save size={16} />
        </IconButton>
      )}

      {doc && isWeb && (
        <>
          <Divider />
          <IconButton onClick={() => handleWebHistory(-1)} title="Back">
            <ArrowLeft size={16} />
          </IconButton>
          <IconButton onClick={() => handleWebHistory(1)} title="Forward">
            <ArrowRight size={16} />
          </IconButton>
        </>
      )}

      {doc && (
        <>
          <Divider />

          {/* Page navigation */}
          <IconButton
            onClick={() => goToPage(currentPage - 1)}
            disabled={currentPage <= 1}
            title="Previous page"
          >
            <ChevronLeft size={16} />
          </IconButton>

          <div className="flex items-center gap-1.5 px-0.5 text-sm tabular-nums">
            <input
              type="number"
              className="focus-ring h-7 w-11 rounded-md border border-border bg-surface px-1 text-center text-sm text-foreground [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none"
              value={pageInput}
              min={1}
              max={numPages}
              onChange={(e) => setPageInput(e.target.value)}
              onBlur={commitPageInput}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  // Just blur — onBlur will call commitPageInput() once
                  (e.target as HTMLInputElement).blur();
                }
              }}
            />
            <span className="text-muted-foreground">/ {numPages}</span>
          </div>

          <IconButton
            onClick={() => goToPage(currentPage + 1)}
            disabled={currentPage >= numPages}
            title="Next page"
          >
            <ChevronRight size={16} />
          </IconButton>

          <Divider />

          {/* Zoom */}
          <IconButton onClick={zoomOut} title="Zoom out">
            <ZoomOut size={16} />
          </IconButton>

          <button
            className="focus-ring h-7 min-w-[3.25rem] rounded-md px-1 text-center text-sm tabular-nums text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            onClick={handleResetZoom}
            title="Reset zoom to 100%"
          >
            {Math.round(zoom * 100)}%
          </button>

          <IconButton onClick={zoomIn} title="Zoom in">
            <ZoomIn size={16} />
          </IconButton>

          <Divider />

          {/* Bookmark */}
          <IconButton
            onClick={handleBookmark}
            className={cn(isBookmarked && "text-gold hover:text-gold")}
            title={
              isBookmarked
                ? "Remove bookmark"
                : isWeb
                  ? "Bookmark this spot"
                  : "Bookmark this page"
            }
          >
            <Bookmark size={16} fill={isBookmarked ? "currentColor" : "none"} />
          </IconButton>

          {/* Sticky Note tool */}
          <IconButton
            variant={mode === "note" ? "active" : "ghost"}
            onClick={() => setMode(mode === "note" ? "view" : "note")}
            title={
              isWeb
                ? "Sticky note tool (N) — click in the page to attach a note to the text there"
                : "Sticky note tool (N) — click on the page to place a note"
            }
          >
            <StickyNote size={16} />
          </IconButton>

          {/* Save webpage to library */}
          {isWeb && (
            <IconButton
              onClick={() => void handleToggleSavedPage()}
              className={cn(pageSaved && "text-gold hover:text-gold")}
              title={
                pageSaved
                  ? "Remove from saved pages"
                  : "Save page to library (keeps an offline snapshot)"
              }
            >
              <BookmarkPlus size={16} fill={pageSaved ? "currentColor" : "none"} />
            </IconButton>
          )}

          {/* Export portable .vellumweb archive */}
          {isWeb && (
            <IconButton
              onClick={() => void handleExportVellumweb()}
              disabled={exportState.status === "exporting"}
              className={cn(
                exportState.status === "done" && "text-emerald-600",
                exportState.status === "error" && "text-destructive",
              )}
              title={
                exportState.status === "idle"
                  ? "Export as .vellumweb (portable archive with snapshot + annotations)"
                  : exportState.detail
              }
            >
              {exportState.status === "exporting" ? (
                <LoaderCircle size={16} className="animate-spin" />
              ) : (
                <FileDown size={16} />
              )}
            </IconButton>
          )}

          {/* Page URL (web tabs) */}
          {isWeb && (
            <span
              className="ml-1 max-w-[16rem] truncate text-xs text-muted-foreground"
              title={doc.pdf_path}
            >
              {doc.pdf_path.replace(/^https?:\/\//, "")}
            </span>
          )}
        </>
      )}

      <div className="ml-auto flex items-center gap-1.5">
        {showUpdateStatusChip && (
          <button
            className={cn(
              "focus-ring flex h-7 items-center gap-1.5 rounded-full border px-2.5 text-xs font-medium transition-colors",
              updateStatus === "available" &&
                "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 hover:bg-emerald-500/15 dark:text-emerald-300",
              (updateStatus === "downloading" || updateStatus === "restarting") &&
                "border-primary/20 bg-primary/10 text-foreground",
              updateStatus === "error" &&
                "border-destructive/30 bg-destructive/10 text-destructive",
            )}
            onClick={() => {
              if (updateStatus === "available") {
                void handleInstallUpdate();
              } else if (updateStatus === "error") {
                void handleCheckForUpdates();
              }
            }}
            disabled={updateStatus !== "available" && updateStatus !== "error"}
            title={updateButtonTitle}
          >
            {updateStatus === "available" && <Download size={12} />}
            {(updateStatus === "downloading" || updateStatus === "restarting") && (
              <LoaderCircle size={12} className="animate-spin" />
            )}
            {updateStatusLabel}
          </button>
        )}

        <IconButton
          onClick={() => void handleCheckForUpdates()}
          disabled={updateDisabled}
          title={updateButtonTitle}
        >
          {updateStatus === "checking" ? (
            <LoaderCircle size={16} className="animate-spin" />
          ) : (
            <RefreshCw size={16} />
          )}
        </IconButton>

        <ThemeToggle />

        {doc && onToggleSidebar && (
          <>
            <Divider />
            <IconButton
              variant={sidebarOpen ? "active" : "ghost"}
              onClick={onToggleSidebar}
              title={sidebarOpen ? "Hide side panel" : "Show side panel"}
              aria-label={sidebarOpen ? "Hide side panel" : "Show side panel"}
            >
              <PanelRight size={16} />
            </IconButton>
          </>
        )}
      </div>
    </div>
  );
}
