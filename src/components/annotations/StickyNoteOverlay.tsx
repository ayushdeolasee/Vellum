import { useState, useRef, useEffect, useCallback, memo } from "react";
import type { Annotation, PositionData } from "@/types";
import { useAnnotationStore } from "@/stores/annotation-store";
import { cn } from "@/lib/utils";
import { StickyNote, X, Trash2, GripHorizontal } from "lucide-react";

interface StickyNoteOverlayProps {
  annotation: Annotation;
  zoom: number;
}

const ZERO_OFFSET = { x: 0, y: 0 };

function hasValidPositionData(
  position: Annotation["position_data"],
): position is PositionData {
  return !!position && Array.isArray(position.rects) && position.rects.length > 0;
}

export const StickyNoteOverlay = memo(function StickyNoteOverlay({
  annotation,
  zoom,
}: StickyNoteOverlayProps) {
  const selectedAnnotationId = useAnnotationStore((s) => s.selectedAnnotationId);
  const selectAnnotation = useAnnotationStore((s) => s.selectAnnotation);
  const updateAnnotation = useAnnotationStore((s) => s.updateAnnotation);
  const deleteAnnotation = useAnnotationStore((s) => s.deleteAnnotation);

  const [isEditing, setIsEditing] = useState(false);
  const [editText, setEditText] = useState(annotation.content ?? "");
  const [dragOffset, setDragOffset] = useState(ZERO_OFFSET);

  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const dragOffsetRef = useRef(ZERO_OFFSET);
  const dragRafId = useRef(0);
  const isSelected = selectedAnnotationId === annotation.id;
  const isExpanded = isSelected || isEditing;

  const wasJustCreated = useRef(!annotation.content);

  const startEditing = useCallback(() => {
    setEditText(annotation.content ?? "");
    setIsEditing(true);
  }, [annotation.content]);

  useEffect(() => {
    if (!wasJustCreated.current || !isSelected) return;
    wasJustCreated.current = false;

    const raf = window.requestAnimationFrame(() => {
      startEditing();
    });

    return () => window.cancelAnimationFrame(raf);
  }, [isSelected, startEditing]);

  useEffect(() => {
    if (!isEditing) return;
    textareaRef.current?.focus();
  }, [isEditing]);

  useEffect(() => {
    return () => {
      if (dragRafId.current) {
        window.cancelAnimationFrame(dragRafId.current);
      }
    };
  }, []);

  const persistEditIfChanged = useCallback(() => {
    const trimmed = editText.trim();
    if (trimmed !== (annotation.content ?? "")) {
      updateAnnotation({
        id: annotation.id,
        content: trimmed,
      });
    }
  }, [annotation.content, annotation.id, editText, updateAnnotation]);

  const handleSave = useCallback(() => {
    persistEditIfChanged();
    setIsEditing(false);
  }, [persistEditIfChanged]);

  const handleClose = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      persistEditIfChanged();
      setIsEditing(false);
      selectAnnotation(null);
    },
    [persistEditIfChanged, selectAnnotation],
  );

  const handleDelete = useCallback(
    (e: React.MouseEvent) => {
      e.stopPropagation();
      deleteAnnotation(annotation.id);
    },
    [annotation.id, deleteAnnotation],
  );

  const startDrag = useCallback(
    (e: React.MouseEvent, onClickFallback?: () => void) => {
      const position = annotation.position_data;
      if (!hasValidPositionData(position)) return;

      e.preventDefault();
      e.stopPropagation();

      const startX = e.clientX;
      const startY = e.clientY;
      const DRAG_THRESHOLD = 3;
      let didDrag = false;

      const handleDragMove = (ev: MouseEvent) => {
        const dx = ev.clientX - startX;
        const dy = ev.clientY - startY;

        if (!didDrag) {
          if (Math.abs(dx) < DRAG_THRESHOLD && Math.abs(dy) < DRAG_THRESHOLD) {
            return;
          }
          didDrag = true;
        }

        dragOffsetRef.current = {
          x: dx / zoom,
          y: dy / zoom,
        };

        if (!dragRafId.current) {
          dragRafId.current = window.requestAnimationFrame(() => {
            dragRafId.current = 0;
            setDragOffset({ ...dragOffsetRef.current });
          });
        }
      };

      const handleDragEnd = () => {
        window.removeEventListener("mousemove", handleDragMove);
        window.removeEventListener("mouseup", handleDragEnd);

        if (!didDrag) {
          onClickFallback?.();
          return;
        }

        if (dragRafId.current) {
          window.cancelAnimationFrame(dragRafId.current);
          dragRafId.current = 0;
        }

        const offset = dragOffsetRef.current;
        if (offset.x !== 0 || offset.y !== 0) {
          const newRects = position.rects.map((r, i) =>
            i === 0 ? { ...r, x: r.x + offset.x, y: r.y + offset.y } : r,
          );

          updateAnnotation({
            id: annotation.id,
            position_data: { ...position, rects: newRects },
          });
        }

        setDragOffset(ZERO_OFFSET);
        dragOffsetRef.current = ZERO_OFFSET;
      };

      window.addEventListener("mousemove", handleDragMove);
      window.addEventListener("mouseup", handleDragEnd);
    },
    [annotation.id, annotation.position_data, updateAnnotation, zoom],
  );

  const handleDragStart = useCallback(
    (e: React.MouseEvent) => startDrag(e),
    [startDrag],
  );

  const handleCollapsedMouseDown = useCallback(
    (e: React.MouseEvent) => {
      startDrag(e, () => {
        if (!isSelected) {
          selectAnnotation(annotation.id);
          return;
        }
        if (!isEditing) {
          startEditing();
        }
      });
    },
    [annotation.id, isEditing, isSelected, selectAnnotation, startDrag, startEditing],
  );

  const position = annotation.position_data;
  if (!hasValidPositionData(position)) return null;
  const anchor = position.rects[0];

  return (
    <div
      className="pointer-events-auto absolute z-10"
      style={{
        left: (anchor.x + dragOffset.x) * zoom,
        top: (anchor.y + dragOffset.y) * zoom,
      }}
    >
      {!isExpanded && (
        <button
          className={cn(
            "group flex cursor-grab items-center gap-1 rounded-md border border-amber-300 bg-amber-100 px-1.5 py-1 shadow-md transition-all hover:scale-105 hover:shadow-lg active:cursor-grabbing",
            "dark:border-amber-600 dark:bg-amber-900/80",
          )}
          onMouseDown={handleCollapsedMouseDown}
          title={annotation.content || "Empty note - click to edit, drag to move"}
        >
          <StickyNote
            size={14}
            className="flex-shrink-0 text-amber-600 dark:text-amber-400"
          />
          {annotation.content ? (
            <span className="max-w-[120px] truncate text-xs text-amber-900 dark:text-amber-200">
              {annotation.content}
            </span>
          ) : (
            <span className="text-xs italic text-amber-500">Empty</span>
          )}
        </button>
      )}

      {isExpanded && (
        <div
          className={cn(
            "w-56 rounded-lg border border-amber-300 bg-amber-50 shadow-xl",
            "dark:border-amber-600 dark:bg-amber-950/90",
          )}
          onClick={(e) => e.stopPropagation()}
        >
          <div
            className="flex cursor-grab items-center justify-between border-b border-amber-200 px-2 py-1 active:cursor-grabbing dark:border-amber-700"
            onMouseDown={handleDragStart}
          >
            <div className="flex items-center gap-1">
              <GripHorizontal
                size={12}
                className="text-amber-400 dark:text-amber-600"
              />
              <StickyNote
                size={12}
                className="text-amber-600 dark:text-amber-400"
              />
              <span className="text-xs font-medium text-amber-700 dark:text-amber-300">
                Note - p.{annotation.page_number}
              </span>
            </div>
            <div className="flex items-center gap-0.5">
              <button
                className="rounded p-0.5 text-amber-500 transition-colors hover:bg-amber-200 hover:text-red-600 dark:hover:bg-amber-800"
                onClick={handleDelete}
                onMouseDown={(e) => e.stopPropagation()}
                title="Delete note"
              >
                <Trash2 size={12} />
              </button>
              <button
                className="rounded p-0.5 text-amber-500 transition-colors hover:bg-amber-200 hover:text-amber-800 dark:hover:bg-amber-800"
                onClick={handleClose}
                onMouseDown={(e) => e.stopPropagation()}
                title="Close"
              >
                <X size={12} />
              </button>
            </div>
          </div>

          <div className="p-2">
            {isEditing ? (
              <textarea
                ref={textareaRef}
                className="w-full resize-none rounded border border-amber-200 bg-amber-50 p-1.5 text-sm text-amber-900 outline-none placeholder:text-amber-400 focus:border-amber-400 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-100 dark:placeholder:text-amber-600"
                rows={4}
                placeholder="Type your note..."
                value={editText}
                onChange={(e) => setEditText(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Escape") {
                    handleSave();
                    selectAnnotation(null);
                  }
                }}
                onBlur={handleSave}
              />
            ) : (
              <p
                className="min-h-[3rem] cursor-text whitespace-pre-wrap text-sm text-amber-900 dark:text-amber-100"
                onClick={startEditing}
              >
                {annotation.content || (
                  <span className="italic text-amber-400">
                    Click to add note...
                  </span>
                )}
              </p>
            )}
          </div>

          {position.selected_text && (
            <div className="border-t border-amber-200 px-2 py-1 dark:border-amber-700">
              <p className="line-clamp-2 text-xs italic text-amber-600 dark:text-amber-500">
                &ldquo;{position.selected_text}&rdquo;
              </p>
            </div>
          )}
        </div>
      )}
    </div>
  );
});
