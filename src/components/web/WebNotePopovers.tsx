import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { useAnnotationStore } from "@/stores/annotation-store";
import { StickyNote, Trash2 } from "lucide-react";

/**
 * Note popovers for webpage tabs. The page lives in a sandboxed iframe, so
 * the PDF viewer's in-page sticky-note editor can't be composited over it;
 * these app-shell popovers (anchored at iframe coordinates mapped by the
 * caller) are the iframe-safe equivalent.
 */

type PopoverPlacement = "above" | "below" | "menu";

/**
 * Position a fixed popover near an anchor point, measured after render so the
 * whole box is clamped inside the window (anchors near an edge — e.g. note
 * markers in the left margin — must not push it offscreen). "above"/"below"
 * center horizontally and flip vertically when there's no room; "menu" hangs
 * from the point like a native context menu.
 */
function useAnchoredPosition(
  x: number,
  y: number,
  placement: PopoverPlacement,
): { ref: React.RefObject<HTMLDivElement | null>; style: CSSProperties } {
  const ref = useRef<HTMLDivElement | null>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;

    const measure = () => {
      const { offsetWidth: w, offsetHeight: h } = el;
      const margin = 8;

      let left: number;
      let top: number;
      if (placement === "menu") {
        left = x;
        top = y;
      } else {
        left = x - w / 2;
        top = placement === "above" ? y - h - 10 : y + 10;
        // Flip when the preferred side lacks room.
        if (placement === "above" && top < margin) top = y + 10;
        if (placement === "below" && top + h > window.innerHeight - margin) {
          top = y - h - 10;
        }
      }
      left = Math.min(Math.max(left, margin), Math.max(margin, window.innerWidth - w - margin));
      top = Math.min(Math.max(top, margin), Math.max(margin, window.innerHeight - h - margin));
      setPos({ left, top });
    };

    measure();
    // Re-clamp when the popover's own size changes (e.g. the viewer growing
    // when it enters edit mode) or the window is resized.
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    window.addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, [x, y, placement]);

  return {
    ref,
    style: pos
      ? { left: pos.left, top: pos.top }
      : // Render invisibly at the anchor for the measuring frame.
        { left: x, top: y, visibility: "hidden" as const },
  };
}

interface WebNoteComposerProps {
  x: number;
  y: number;
  onSubmit: (content: string) => void;
  onClose: () => void;
}

export function WebNoteComposer({ x, y, onSubmit, onClose }: WebNoteComposerProps) {
  const [text, setText] = useState("");
  const { ref, style } = useAnchoredPosition(x, y, "below");

  const submit = () => {
    const trimmed = text.trim();
    if (!trimmed) return;
    onSubmit(trimmed);
  };

  return (
    <div
      ref={ref}
      className="fixed z-50 w-72 rounded-lg border bg-background p-2 shadow-lg"
      style={style}
      onMouseDown={(e) => e.stopPropagation()}
    >
      <div className="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
        <StickyNote size={13} className="text-amber-500" />
        New note
      </div>
      <textarea
        className="h-20 w-full resize-none rounded border bg-muted px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-primary"
        placeholder="Write a note…"
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            submit();
          }
          if (e.key === "Escape") onClose();
        }}
        autoFocus
      />
      <div className="mt-1.5 flex justify-end gap-1.5">
        <button
          className="focus-ring rounded-md px-2.5 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
          onClick={onClose}
        >
          Cancel
        </button>
        <button
          className="focus-ring rounded-md bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          onClick={submit}
          disabled={!text.trim()}
        >
          Add note
        </button>
      </div>
    </div>
  );
}

interface WebContextMenuProps {
  x: number;
  y: number;
  canAddNote: boolean;
  onAddNote: () => void;
  onClose: () => void;
}

export function WebContextMenu({ x, y, canAddNote, onAddNote, onClose }: WebContextMenuProps) {
  const { ref, style } = useAnchoredPosition(x, y, "menu");

  // Dismiss on any app-shell click or Escape (clicks inside the iframe are
  // handled by the caller via content-script messages).
  useEffect(() => {
    const dismiss = () => onClose();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("click", dismiss);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", dismiss);
      window.removeEventListener("keydown", onKey);
    };
  }, [onClose]);

  return (
    <div
      ref={ref}
      className="fixed z-50 min-w-[160px] rounded-lg border bg-background py-1 shadow-lg"
      style={style}
      onClick={(e) => e.stopPropagation()}
    >
      <button
        className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-accent disabled:cursor-default disabled:opacity-50 disabled:hover:bg-transparent"
        onClick={onAddNote}
        disabled={!canAddNote}
        title={canAddNote ? undefined : "No text near this spot to attach a note to"}
      >
        <StickyNote size={14} className="text-amber-500" />
        Add note here
      </button>
    </div>
  );
}

interface WebNoteViewerProps {
  annotationId: string;
  x: number;
  y: number;
  onClose: () => void;
}

export function WebNoteViewer({ annotationId, x, y, onClose }: WebNoteViewerProps) {
  const annotation = useAnnotationStore((s) =>
    s.annotations.find((a) => a.id === annotationId),
  );
  const updateAnnotation = useAnnotationStore((s) => s.updateAnnotation);
  const deleteAnnotation = useAnnotationStore((s) => s.deleteAnnotation);

  // Open straight into editing when the note has no content yet.
  const [isEditing, setIsEditing] = useState(!annotation?.content);
  const [text, setText] = useState(annotation?.content ?? "");
  const { ref, style } = useAnchoredPosition(x, y, "above");

  if (!annotation) return null;

  const save = () => {
    const trimmed = text.trim();
    if (trimmed !== (annotation.content ?? "")) {
      void updateAnnotation({ id: annotation.id, content: trimmed });
    }
    setIsEditing(false);
  };

  return (
    <div
      ref={ref}
      className="fixed z-50 w-72 rounded-lg border bg-background p-2 shadow-lg"
      style={style}
      onMouseDown={(e) => e.stopPropagation()}
    >
      <div className="mb-1.5 flex items-center justify-between">
        <span className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
          <StickyNote size={13} className="text-amber-500" />
          Note
        </span>
        <button
          className="focus-ring flex h-6 w-6 items-center justify-center rounded text-muted-foreground hover:bg-accent hover:text-destructive"
          onClick={() => {
            void deleteAnnotation(annotation.id);
            onClose();
          }}
          title="Delete note"
        >
          <Trash2 size={13} />
        </button>
      </div>

      {isEditing ? (
        <>
          <textarea
            className="h-20 w-full resize-none rounded border bg-muted px-2 py-1.5 text-sm outline-none focus:ring-1 focus:ring-primary"
            placeholder="Write a note…"
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                save();
              }
              if (e.key === "Escape") onClose();
            }}
            autoFocus
          />
          <div className="mt-1.5 flex justify-end gap-1.5">
            <button
              className="focus-ring rounded-md px-2.5 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
              onClick={onClose}
            >
              Cancel
            </button>
            <button
              className="focus-ring rounded-md bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground hover:bg-primary/90"
              onClick={save}
            >
              Save
            </button>
          </div>
        </>
      ) : (
        <>
          <p className="max-h-40 overflow-auto whitespace-pre-wrap break-words px-0.5 text-sm text-foreground">
            {annotation.content}
          </p>
          {annotation.position_data?.selected_text && (
            <p className="mt-1.5 truncate border-l-2 border-amber-300 pl-2 text-xs italic text-muted-foreground">
              {annotation.position_data.selected_text}
            </p>
          )}
          <div className="mt-1.5 flex justify-end">
            <button
              className="focus-ring rounded-md px-2.5 py-1 text-xs text-muted-foreground hover:bg-accent hover:text-foreground"
              onClick={() => {
                setText(annotation.content ?? "");
                setIsEditing(true);
              }}
            >
              Edit
            </button>
          </div>
        </>
      )}
    </div>
  );
}
