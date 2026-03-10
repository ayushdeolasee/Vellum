import { useState, useMemo } from "react";
import { useAnnotationStore } from "@/stores/annotation-store";
import { usePdfStore } from "@/stores/pdf-store";
import type { Annotation, AnnotationType } from "@/types";
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
    goToPage(annotation.page_number);
    // Scroll to page
    const scrollToPage = (window as unknown as Record<string, unknown>)
      .__scrollToPage as ((page: number) => void) | undefined;
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
      <div className="flex h-full items-center justify-center p-4 text-center text-sm text-muted-foreground">
        No annotations yet. Select text on the PDF to create highlights.
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col">
      {/* Filter bar */}
      <div className="flex items-center gap-1 border-b p-2">
        <Filter size={14} className="text-muted-foreground" />
        <button
          className={cn(
            "rounded px-2 py-0.5 text-xs transition-colors",
            filter === "all"
              ? "bg-primary text-primary-foreground"
              : "text-muted-foreground hover:bg-accent",
          )}
          onClick={() => setFilter("all")}
        >
          All ({annotations.length})
        </button>
        {(["highlight", "note", "bookmark"] as const).map((type) => {
          const count = counts[type];
          if (count === 0) return null;
          const Icon = TYPE_ICONS[type];
          return (
            <button
              key={type}
              className={cn(
                "flex items-center gap-1 rounded px-2 py-0.5 text-xs transition-colors",
                filter === type
                  ? "bg-primary text-primary-foreground"
                  : "text-muted-foreground hover:bg-accent",
              )}
              onClick={() => setFilter(type)}
            >
              <Icon size={12} />
              {count}
            </button>
          );
        })}
      </div>

      {/* Annotation list */}
      <div className="min-h-0 flex-1 overflow-auto overscroll-contain">
        {filtered.map((annotation) => {
          const Icon = TYPE_ICONS[annotation.type];
          const isSelected = selectedAnnotationId === annotation.id;
          const isEditing = editingId === annotation.id;

          return (
            <div
              key={annotation.id}
              className={cn(
                "group cursor-pointer border-b p-3 transition-colors hover:bg-accent/50",
                isSelected && "bg-accent",
              )}
              onClick={() => handleClick(annotation)}
            >
              <div className="flex items-start gap-2">
                <div className="mt-0.5 flex-shrink-0">
                  {annotation.type === "highlight" && annotation.color ? (
                    <div
                      className="h-4 w-4 rounded-full border"
                      style={{ backgroundColor: annotation.color }}
                    />
                  ) : (
                    <Icon size={16} className="text-muted-foreground" />
                  )}
                </div>

                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1">
                    <span className="text-xs text-muted-foreground">
                      p.{annotation.page_number}
                    </span>
                    <span className="text-xs text-muted-foreground">
                      {TYPE_LABELS[annotation.type]}
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
