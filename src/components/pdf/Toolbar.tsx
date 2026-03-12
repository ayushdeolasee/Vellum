import { useState, useEffect } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { usePdfStore } from "@/stores/pdf-store";
import * as commands from "@/lib/tauri-commands";
import { confirmPdfImport } from "@/lib/pdf-import";
import {
  FolderOpen,
  ZoomIn,
  ZoomOut,
  ChevronLeft,
  ChevronRight,
  Save,
  Bookmark,
  StickyNote,
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
  useEffect(() => {
    setPageInput(String(currentPage));
  }, [currentPage]);

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
          name: "Vellum / PDF",
          extensions: ["rr", "pdf"],
        },
      ],
    });
    const selectedPath = Array.isArray(selected) ? selected[0] : selected;
    if (!selectedPath || !confirmPdfImport(selectedPath)) return;
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

          {/* Title */}
          <div className="ml-2 flex-1 truncate text-sm text-muted-foreground">
            {doc.title ?? "Untitled"}
          </div>
        </>
      )}
    </div>
  );
}
