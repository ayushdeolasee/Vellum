// Entry point for the scratchpad live-preview editor. Bundled to a single IIFE
// (window.ScratchpadEditor) that the Swift WKWebView host drives: it pushes
// content/theme in, and receives change + ready messages back.
import { EditorState } from "@codemirror/state";
import { EditorView, keymap, drawSelection, placeholder } from "@codemirror/view";
import { history, historyKeymap, defaultKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting } from "@codemirror/language";
import { mathExtension } from "./math.js";
import { livePreview } from "./live-preview.js";
import { editorIntelligence } from "./intelligence.js";
import { theme, highlight } from "./theme.js";

let view = null;
let suppressChange = false;

function post(type, payload) {
  const handler = window.webkit?.messageHandlers?.scratchpad;
  if (handler) handler.postMessage(Object.assign({ type }, payload || {}));
}

function createEditor(parent) {
  const listener = EditorView.updateListener.of((update) => {
    if (update.docChanged && !suppressChange) {
      post("change", { text: update.state.doc.toString() });
    }
  });
  const state = EditorState.create({
    doc: "",
    extensions: [
      history(),
      drawSelection(),
      EditorView.lineWrapping,
      editorIntelligence,
      keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
      markdown({ base: markdownLanguage, extensions: [mathExtension] }),
      syntaxHighlighting(highlight),
      livePreview,
      theme,
      placeholder("Jot down notes as you read.\nMarkdown and $LaTeX$ supported."),
      listener,
    ],
  });
  view = new EditorView({ state, parent });
}

// Public API consumed by the Swift host.
const api = {
  setContent(text) {
    if (!view) return;
    const value = text == null ? "" : String(text);
    if (view.state.doc.toString() === value) return;
    suppressChange = true;
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: value },
      selection: { anchor: Math.min(view.state.selection.main.anchor, value.length) },
    });
    suppressChange = false;
  },
  // Append a markdown block (e.g. an image reference) at the end of the note,
  // separated by a blank line, then reveal + focus it. Not suppressed: the
  // resulting doc change flows back to Swift as a normal `change` message, so
  // the note text + persistence update themselves.
  insertSnippet(markdown) {
    if (!view) return;
    const text = markdown == null ? "" : String(markdown);
    if (!text) return;
    const doc = view.state.doc;
    const end = doc.length;
    let prefix = "";
    if (end > 0) {
      const tail = doc.sliceString(Math.max(0, end - 2), end);
      prefix = tail.endsWith("\n\n") ? "" : tail.endsWith("\n") ? "\n" : "\n\n";
    }
    const insert = prefix + text + "\n";
    view.dispatch({
      changes: { from: end, to: end, insert },
      selection: { anchor: end + insert.length },
      scrollIntoView: true,
    });
    view.focus();
  },
  setTheme(opts) {
    const root = document.documentElement.style;
    if (opts.fg) root.setProperty("--fg", opts.fg);
    if (opts.muted) root.setProperty("--muted", opts.muted);
    if (opts.accent) root.setProperty("--accent", opts.accent);
    if (opts.err) root.setProperty("--err", opts.err);
    if (opts.fontSize) root.setProperty("--fs", opts.fontSize + "px");
  },
  focus() {
    view?.focus();
  },
};

function boot() {
  createEditor(document.getElementById("editor"));
  post("ready", {});
}

if (document.readyState === "loading") {
  window.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}

// Expose the API directly on window. (No module export / esbuild --global-name:
// an iife global-name binding would overwrite window.ScratchpadEditor with the
// exports object, burying setContent one level deeper.)
window.ScratchpadEditor = api;
