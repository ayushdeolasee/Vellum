import { useState, useMemo } from "react";
import { useAnnotationStore } from "@/stores/annotation-store";
import { usePdfStore } from "@/stores/pdf-store";
import type { Annotation, AnnotationType, PositionData } from "@/types";
import { cn } from "@/lib/utils";
import {
  Highlighter,
  MessageSquare,
  Bookmark,
  Trash2,
  Filter,
} from "lucide-react";

const TYPE_ICONS: Record<AnnotationType, typeof Highlighter> = {
  highlight: Highlighter,
  note: MessageSquare,
  bookmark: Bookmark,
};

const TYPE_LABELS: Record<AnnotationType, string> = {
  highlight: "Highlights",
  note: "Notes",
  bookmark: "Bookmarks",
};

export function AnnotationSidebar() {
  // Individual Zustand selectors — only re-render when specific values change
  const annotations = useAnnotationStore((s) => s.annotations);
  const selectedAnnotationId = useAnnotationStore(
    (s) => s.selectedAnnotationId,
  );
  const selectAnnotation = useAnnotationStore((s) => s.selectAnnotation);
  const deleteAnnotation = useAnnotationStore((s) => s.deleteAnnotation);
  const updateAnnotation = useAnnotationStore((s) => s.updateAnnotation);
  const goToPage = usePdfStore((s) => s.goToPage);

  const [filter, setFilter] = useState<AnnotationType | "all">("all");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editText, setEditText] = useState("");

  // Memoize type counts — single O(N) pass instead of 3x .filter() per render
  const counts = useMemo(() => {
    const map: Record<AnnotationType, number> = {
      highlight: 0,
      note: 0,
      bookmark: 0,
    };
    for (const a of annotations) map[a.type]++;
    return map;
  }, [annotations]);

  // Memoize filtered list
  const filtered = useMemo(
    () =>
      filter === "all"
        ? annotations
        : annotations.filter((a) => a.type === filter),
    [annotations, filter],
  );

  const handleClick = (annotation: Annotation) => {
    selectAnnotation(annotation.id);
    // Web annotations anchored to a text position scroll to that exact spot;
    // everything else jumps to the page.
    const globals = window as unknown as Record<string, unknown>;
    const scrollToWebPosition = globals.__scrollToWebPosition as
      | ((pd: PositionData, page?: number) => boolean)
      | undefined;
    if (
      scrollToWebPosition &&
      annotation.position_data?.start_offset != null &&
      annotation.type !== "highlight" &&
      scrollToWebPosition(annotation.position_data, annotation.page_number)
    ) {
      return;
    }
    goToPage(annotation.page_number);
    const scrollToPage = globals.__scrollToPage as
      | ((page: number) => void)
      | undefined;
    scrollToPage?.(annotation.page_number);
  };

  const handleStartEdit = (annotation: Annotation) => {
    setEditingId(annotation.id);
    setEditText(annotation.content ?? "");
  };

  const handleSaveEdit = async (id: string) => {
    await updateAnnotation({ id, content: editText });
    setEditingId(null);
  };

  if (annotations.length === 0) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center">
        <span className="flex h-12 w-12 items-center justify-center rounded-full border border-border bg-muted text-muted-foreground">
          <Highlighter size={20} strokeWidth={1.75} />
        </span>
        <div>
          <p className="text-sm font-medium text-foreground">No annotations yet</p>
          <p className="mt-1 text-xs text-muted-foreground">
            Select text on the page to highlight it, or press{" "}
            <kbd className="rounded border border-border-strong bg-surface px-1 py-0.5 font-mono text-[10px]">
              N
            </kbd>{" "}
            to drop a note.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col">
      {/* Filter bar */}
      <div className="flex flex-wrap items-center gap-1.5 border-b p-2.5">
        <Filter size={13} className="text-muted-foreground" />
        <button
          className={cn(
            "focus-ring rounded-full px-2.5 py-1 text-xs font-medium transition-colors",
            filter === "all"
              ? "bg-primary text-primary-foreground"
              : "bg-muted text-muted-foreground hover:bg-accent hover:text-foreground",
          )}
          onClick={() => setFilter("all")}
        >
          All · {annotations.length}
        </button>
        {(["highlight", "note", "bookmark"] as const).map((type) => {
          const count = counts[type];
          if (count === 0) return null;
          const Icon = TYPE_ICONS[type];
          return (
            <button
              key={type}
              className={cn(
                "focus-ring flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium transition-colors",
                filter === type
                  ? "bg-primary text-primary-foreground"
                  : "bg-muted text-muted-foreground hover:bg-accent hover:text-foreground",
              )}
              onClick={() => setFilter(type)}
              title={TYPE_LABELS[type]}
            >
              <Icon size={12} />
              {count}
            </button>
          );
        })}
      </div>

      {/* Annotation list */}
      <div className="min-h-0 flex-1 overflow-auto overscroll-contain p-1.5">
        {filtered.map((annotation) => {
          const Icon = TYPE_ICONS[annotation.type];
          const isSelected = selectedAnnotationId === annotation.id;
          const isEditing = editingId === annotation.id;

          return (
            <div
              key={annotation.id}
              className={cn(
                "group cursor-pointer rounded-lg border border-transparent p-2.5 transition-colors hover:bg-accent",
                isSelected && "border-border-strong bg-accent",
              )}
              onClick={() => handleClick(annotation)}
            >
              <div className="flex items-start gap-2.5">
                <div className="mt-0.5 flex-shrink-0">
                  {annotation.type === "highlight" && annotation.color ? (
                    <div
                      className="h-4 w-4 rounded-full ring-1 ring-border-strong"
                      style={{ backgroundColor: annotation.color }}
                    />
                  ) : (
                    <Icon size={16} className="text-muted-foreground" />
                  )}
                </div>

                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5 text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
                    <span>{TYPE_LABELS[annotation.type]}</span>
                    <span aria-hidden>·</span>
                    <span className="normal-case tracking-normal">
                      p.{annotation.page_number}
                    </span>
                  </div>

                  {/* Highlighted text */}
                  {annotation.position_data?.selected_text && (
                    <p className="mt-1 line-clamp-2 text-sm italic text-muted-foreground">
                      &ldquo;
                      {annotation.position_data.selected_text}
                      &rdquo;
                    </p>
                  )}

                  {/* Note content */}
                  {isEditing ? (
                    <div className="mt-1 flex gap-1">
                      <input
                        type="text"
                        className="flex-1 rounded border bg-muted px-2 py-0.5 text-sm outline-none focus:ring-1 focus:ring-primary"
                        value={editText}
                        onChange={(e) => setEditText(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter")
                            handleSaveEdit(annotation.id);
                          if (e.key === "Escape") setEditingId(null);
                        }}
                        onClick={(e) => e.stopPropagation()}
                        autoFocus
                      />
                    </div>
                  ) : annotation.content ? (
                    <p
                      className="mt-1 line-clamp-3 text-sm"
                      onDoubleClick={(e) => {
                        e.stopPropagation();
                        handleStartEdit(annotation);
                      }}
                    >
                      {annotation.content}
                    </p>
                  ) : null}
                </div>

                {/* Delete button */}
                <button
                  className="flex-shrink-0 rounded p-1 text-muted-foreground opacity-0 transition-opacity hover:bg-destructive/10 hover:text-destructive group-hover:opacity-100"
                  onClick={(e) => {
                    e.stopPropagation();
                    deleteAnnotation(annotation.id);
                  }}
                  title="Delete annotation"
                >
                  <Trash2 size={14} />
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
