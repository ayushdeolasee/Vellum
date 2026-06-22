import { useCallback, useEffect, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { usePdfStore } from "@/stores/pdf-store";
import type { AppUpdate, AppUpdateDownloadEvent } from "@/lib/app-updates";
import { checkForAppUpdate, relaunchForUpdate } from "@/lib/app-updates";
import * as commands from "@/lib/tauri-commands";
import {
  FolderOpen,
  ZoomIn,
  ZoomOut,
  ChevronLeft,
  ChevronRight,
  Save,
  Bookmark,
  StickyNote,
  Download,
  LoaderCircle,
  RefreshCw,
} from "lucide-react";
import { useAnnotationStore } from "@/stores/annotation-store";
import { cn } from "@/lib/utils";

export function Toolbar() {
  const {
    document: doc,
    currentPage,
    numPages,
    zoom,
    mode,
    openFile,
    zoomIn,
    zoomOut,
    setZoom,
    goToPage,
    setMode,
  } = usePdfStore();

  const { addBookmark, annotations, deleteAnnotation } = useAnnotationStore();

  // Find existing bookmark for the current page
  const currentBookmark = annotations.find(
    (a) => a.type === "bookmark" && a.page_number === currentPage,
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
      multiple: false,
      filters: [
        {
          name: "PDF",
          extensions: ["pdf"],
        },
      ],
    });
    const selectedPath = Array.isArray(selected) ? selected[0] : selected;
    if (!selectedPath) return;
    await openFile(selectedPath);
  };

  const handleSave = async () => {
    try {
      await commands.saveFile();
    } catch {
      // TODO: show error toast
    }
  };

  const handleBookmark = async () => {
    if (currentBookmark) {
      await deleteAnnotation(currentBookmark.id);
    } else {
      await addBookmark(currentPage);
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
    <div className="flex h-10 items-center gap-1 border-b bg-background px-2">
      {/* File operations */}
      <button
        className="flex h-7 w-7 items-center justify-center rounded text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
        onClick={handleOpen}
        title="Open file (Ctrl+O)"
      >
        <FolderOpen size={16} />
      </button>

      {doc && (
        <button
          className="flex h-7 w-7 items-center justify-center rounded text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
          onClick={handleSave}
          title="Save (Ctrl+S)"
        >
          <Save size={16} />
        </button>
      )}

      {doc && (
        <>
          <div className="mx-1 h-5 w-px bg-border" />

          {/* Page navigation */}
          <button
            className="flex h-7 w-7 items-center justify-center rounded text-muted-foreground transition-colors hover:bg-accent hover:text-foreground disabled:opacity-30"
            onClick={() => goToPage(currentPage - 1)}
            disabled={currentPage <= 1}
            title="Previous page"
          >
            <ChevronLeft size={16} />
          </button>

          <div className="flex items-center gap-1 text-sm">
            <input
              type="number"
              className="w-12 rounded border bg-muted px-1 py-0.5 text-center text-sm outline-none focus:ring-1 focus:ring-primary"
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

          <button
            className="flex h-7 w-7 items-center justify-center rounded text-muted-foreground transition-colors hover:bg-accent hover:text-foreground disabled:opacity-30"
            onClick={() => goToPage(currentPage + 1)}
            disabled={currentPage >= numPages}
            title="Next page"
          >
            <ChevronRight size={16} />
          </button>

          <div className="mx-1 h-5 w-px bg-border" />

          {/* Zoom */}
          <button
            className="flex h-7 w-7 items-center justify-center rounded text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            onClick={zoomOut}
            title="Zoom out"
          >
            <ZoomOut size={16} />
          </button>

          <button
            className="min-w-[3rem] rounded px-1 py-0.5 text-center text-sm text-muted-foreground hover:bg-accent"
            onClick={() => setZoom(1.0)}
            title="Reset zoom"
          >
            {Math.round(zoom * 100)}%
          </button>

          <button
            className="flex h-7 w-7 items-center justify-center rounded text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            onClick={zoomIn}
            title="Zoom in"
          >
            <ZoomIn size={16} />
          </button>

          <div className="mx-1 h-5 w-px bg-border" />

          {/* Bookmark */}
          <button
            className={cn(
              "flex h-7 w-7 items-center justify-center rounded transition-colors",
              isBookmarked
                ? "text-orange-500 hover:bg-accent"
                : "text-muted-foreground hover:bg-accent hover:text-foreground",
            )}
            onClick={handleBookmark}
            title={isBookmarked ? "Remove bookmark" : "Bookmark this page"}
          >
            <Bookmark size={16} fill={isBookmarked ? "currentColor" : "none"} />
          </button>

          {/* Sticky Note tool */}
          <button
            className={cn(
              "flex h-7 w-7 items-center justify-center rounded transition-colors",
              mode === "note"
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent hover:text-foreground",
            )}
            onClick={() => setMode(mode === "note" ? "view" : "note")}
            title="Sticky note tool (N) — click on the page to place a note"
          >
            <StickyNote size={16} />
          </button>

          <div className="ml-2 min-w-0 flex-1 truncate text-sm text-muted-foreground">
            {doc.title ?? "Untitled"}
          </div>
        </>
      )}

      <div className="ml-auto flex items-center gap-2">
        {showUpdateStatusChip && (
          <button
            className={cn(
              "flex h-7 items-center gap-1 rounded-full border px-2 text-xs transition-colors",
              updateStatus === "available" &&
                "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 hover:bg-emerald-500/15 dark:text-emerald-300",
              updateStatus === "downloading" &&
                "border-primary/20 bg-primary/10 text-foreground",
              updateStatus === "restarting" &&
                "border-primary/20 bg-primary/10 text-foreground",
              updateStatus === "error" &&
                "border-destructive/20 bg-destructive/10 text-destructive",
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

        <button
          className="flex h-7 w-7 items-center justify-center rounded text-muted-foreground transition-colors hover:bg-accent hover:text-foreground disabled:opacity-50"
          onClick={() => void handleCheckForUpdates()}
          disabled={updateDisabled}
          title={updateButtonTitle}
        >
          {updateStatus === "checking" ? (
            <LoaderCircle size={16} className="animate-spin" />
          ) : (
            <RefreshCw size={16} />
          )}
        </button>
      </div>
    </div>
  );
}
