// Editor chrome + Markdown token styling. Colors resolve to CSS custom
// properties that the Swift host sets from the active theme palette, so
// re-theming never rebuilds the editor.
import { EditorView } from "@codemirror/view";
import { HighlightStyle } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

export const theme = EditorView.theme(
  {
    "&": {
      color: "var(--fg)",
      backgroundColor: "transparent",
      fontSize: "var(--fs)",
      height: "100%",
    },
    ".cm-scroller": {
      fontFamily:
        "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif",
      lineHeight: "1.55",
      overflow: "auto",
    },
    ".cm-content": {
      padding: "14px 16px 48px",
      caretColor: "var(--fg)",
      maxWidth: "100%",
    },
    "&.cm-focused": { outline: "none" },
    ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--fg)" },
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
      { backgroundColor: "color-mix(in srgb, var(--accent) 24%, transparent)" },
    ".cm-placeholder": { color: "var(--muted)", fontStyle: "normal" },
    // Rendered widgets injected by the live-preview plugin.
    ".cm-inline-code": {
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: "0.88em",
      backgroundColor: "color-mix(in srgb, var(--fg) 11%, transparent)",
      borderRadius: "5px",
      padding: "0.08em 0.32em",
    },
    ".cm-bullet": { color: "var(--muted)" },
    ".cm-math-inline": { cursor: "text" },
    ".cm-math-block": {
      display: "block",
      textAlign: "center",
      padding: "4px 0 6px",
      overflowX: "auto",
    },
    ".cm-math-error": {
      color: "var(--err)",
      fontFamily: "ui-monospace, Menlo, monospace",
      fontSize: "0.9em",
    },
    ".cm-md-image": {
      display: "block",
      maxWidth: "100%",
      height: "auto",
      margin: "4px 0",
      borderRadius: "6px",
      border: "1px solid color-mix(in srgb, var(--fg) 12%, transparent)",
    },
    ".cm-md-hr": { padding: "6px 0" },
    ".cm-md-hr hr": {
      border: "none",
      borderTop: "1px solid color-mix(in srgb, var(--fg) 20%, transparent)",
      margin: 0,
    },
    ".cm-md-table": { overflowX: "auto", margin: "2px 0 6px" },
    ".cm-md-table table": {
      borderCollapse: "collapse",
      fontSize: "0.95em",
    },
    ".cm-md-table th, .cm-md-table td": {
      border: "1px solid color-mix(in srgb, var(--fg) 22%, transparent)",
      padding: "4px 9px",
      textAlign: "left",
    },
    ".cm-md-table th": {
      backgroundColor: "color-mix(in srgb, var(--fg) 7%, transparent)",
      fontWeight: "600",
    },
    ".cm-task-checkbox": {
      cursor: "pointer",
      userSelect: "none",
      marginRight: "0.35em",
      color: "var(--accent)",
    },
    ".cm-quote-line": {
      borderLeft: "2px solid color-mix(in srgb, var(--fg) 30%, transparent)",
      paddingLeft: "0.7em",
      color: "var(--muted)",
    },
  },
  { dark: false }
);

export const highlight = HighlightStyle.define([
  { tag: t.heading1, fontSize: "1.5em", fontWeight: "600", lineHeight: "1.3" },
  { tag: t.heading2, fontSize: "1.28em", fontWeight: "600", lineHeight: "1.3" },
  { tag: t.heading3, fontSize: "1.12em", fontWeight: "600" },
  { tag: [t.heading4, t.heading5, t.heading6], fontWeight: "600" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: t.link, color: "var(--accent)", textDecoration: "underline" },
  { tag: t.url, color: "var(--accent)" },
  { tag: t.monospace, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" },
  { tag: t.quote, color: "var(--muted)" },
  { tag: [t.list, t.meta], color: "var(--muted)" },
]);
