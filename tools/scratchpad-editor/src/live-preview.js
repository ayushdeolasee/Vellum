// Obsidian-style live preview. Every line the selection touches shows raw
// Markdown source; every other construct is rendered in place — syntax markers
// hidden, math/tables/rules swapped for widgets. Moving the cursor onto a line
// reveals it; leaving re-renders it.
import { Decoration, EditorView, WidgetType } from "@codemirror/view";
import { StateField } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import DOMPurify from "dompurify";

const HIDDEN = Decoration.replace({});
const INLINE_CODE = Decoration.mark({ class: "cm-inline-code" });
const QUOTE_LINE = Decoration.line({ class: "cm-quote-line" });

class BulletWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const s = document.createElement("span");
    s.className = "cm-bullet";
    s.textContent = "•";
    return s;
  }
}

class MathWidget extends WidgetType {
  constructor(tex, display) {
    super();
    this.tex = tex;
    this.display = display;
  }
  eq(other) {
    return other.tex === this.tex && other.display === this.display;
  }
  toDOM() {
    const el = document.createElement(this.display ? "div" : "span");
    el.className = this.display ? "cm-math-block" : "cm-math-inline";
    try {
      window.katex.render(this.tex, el, {
        throwOnError: false,
        displayMode: this.display,
        output: "html",
      });
    } catch (e) {
      el.textContent = this.tex;
      el.classList.add("cm-math-error");
    }
    return el;
  }
  ignoreEvent() {
    return false;
  }
}

class HrWidget extends WidgetType {
  eq() {
    return true;
  }
  toDOM() {
    const wrap = document.createElement("div");
    wrap.className = "cm-md-hr";
    wrap.appendChild(document.createElement("hr"));
    return wrap;
  }
}

class TableWidget extends WidgetType {
  constructor(src) {
    super();
    this.src = src;
  }
  eq(other) {
    return other.src === this.src;
  }
  toDOM() {
    const wrap = document.createElement("div");
    wrap.className = "cm-md-table";
    try {
      // Sanitize before insertion — a note could contain raw HTML (e.g. pasted
      // from the web) whose inline event handlers would otherwise execute.
      wrap.innerHTML = DOMPurify.sanitize(window.marked.parse(this.src, { gfm: true }));
    } catch (e) {
      wrap.textContent = this.src;
    }
    return wrap;
  }
  ignoreEvent() {
    return false;
  }
}

class ImageWidget extends WidgetType {
  constructor(url, alt) {
    super();
    this.url = url;
    this.alt = alt;
  }
  eq(other) {
    return other.url === this.url && other.alt === this.alt;
  }
  toDOM() {
    const img = document.createElement("img");
    img.className = "cm-md-image";
    img.src = this.url;
    if (this.alt) img.alt = this.alt;
    return img;
  }
  ignoreEvent() {
    return false;
  }
}

class CheckboxWidget extends WidgetType {
  constructor(checked, from, to) {
    super();
    this.checked = checked;
    this.from = from;
    this.to = to;
  }
  eq(other) {
    return other.checked === this.checked && other.from === this.from;
  }
  toDOM(view) {
    const box = document.createElement("span");
    box.className = "cm-task-checkbox";
    box.textContent = this.checked ? "☑" : "☐";
    box.addEventListener("mousedown", (e) => {
      e.preventDefault();
      view.dispatch({
        changes: { from: this.from, to: this.to, insert: this.checked ? "[ ]" : "[x]" },
      });
    });
    return box;
  }
  ignoreEvent() {
    return true;
  }
}

function buildDecorations(state) {
  const doc = state.doc;
  const decos = [];

  // Lines touched by any selection range stay in raw "edit" mode.
  const activeLines = new Set();
  for (const range of state.selection.ranges) {
    const first = doc.lineAt(range.from).number;
    const last = doc.lineAt(range.to).number;
    for (let n = first; n <= last; n++) activeLines.add(n);
  }
  const isActive = (from, to) => {
    const first = doc.lineAt(from).number;
    const last = doc.lineAt(to).number;
    for (let n = first; n <= last; n++) if (activeLines.has(n)) return true;
    return false;
  };
  const blockRange = (from, to) => {
    const l1 = doc.lineAt(from);
    const l2 = doc.lineAt(to);
    return { from: l1.from, to: l2.to };
  };

  const tree = syntaxTree(state);
  {
    tree.iterate({
      enter: (node) => {
        const { name, from, to } = node;
        const active = isActive(from, to);
        switch (name) {
          case "InlineMath": {
            if (!active) {
              const tex = doc.sliceString(from + 1, to - 1);
              decos.push(
                Decoration.replace({ widget: new MathWidget(tex, false) }).range(from, to)
              );
            }
            return false;
          }
          case "BlockMath": {
            if (!active) {
              const tex = doc
                .sliceString(from, to)
                .replace(/^\$\$/, "")
                .replace(/\$\$\s*$/, "")
                .trim();
              const r = blockRange(from, to);
              decos.push(
                Decoration.replace({ widget: new MathWidget(tex, true), block: true }).range(
                  r.from,
                  r.to
                )
              );
            }
            return false;
          }
          case "Table": {
            if (!active) {
              const src = doc.sliceString(from, to);
              const r = blockRange(from, to);
              decos.push(
                Decoration.replace({ widget: new TableWidget(src), block: true }).range(
                  r.from,
                  r.to
                )
              );
            }
            return false;
          }
          case "HorizontalRule": {
            if (!active) {
              const r = blockRange(from, to);
              decos.push(
                Decoration.replace({ widget: new HrWidget(), block: true }).range(r.from, r.to)
              );
            }
            return false;
          }
          case "Blockquote": {
            // Style each quoted line; markers hidden via QuoteMark below.
            let pos = from;
            while (pos <= to) {
              const line = doc.lineAt(pos);
              decos.push(QUOTE_LINE.range(line.from));
              if (line.to + 1 > to) break;
              pos = line.to + 1;
            }
            return true;
          }
          case "Image": {
            // Render `![alt](url)` in place as an <img>; the raw source shows
            // when the cursor is on the line so it can be edited/deleted.
            if (!active) {
              const src = doc.sliceString(from, to);
              const m = /^!\[([^\]]*)\]\(([^)\s]+)/.exec(src);
              if (m) {
                decos.push(
                  Decoration.replace({ widget: new ImageWidget(m[2], m[1]) }).range(from, to)
                );
              }
            }
            return false;
          }
          case "HeaderMark": {
            if (!active) {
              let end = to;
              if (doc.sliceString(to, to + 1) === " ") end = to + 1;
              decos.push(HIDDEN.range(from, end));
            }
            return false;
          }
          case "EmphasisMark":
          case "StrikethroughMark":
          case "QuoteMark":
          case "LinkMark":
          case "URL":
          case "LinkTitle":
          case "CodeInfo":
          case "CodeMark": {
            if (!active) decos.push(HIDDEN.range(from, to));
            return false;
          }
          case "InlineCode": {
            decos.push(INLINE_CODE.range(from, to));
            return true; // descend so the backtick CodeMarks get hidden
          }
          case "ListMark": {
            const text = doc.sliceString(from, to).trim();
            if (!active && /^[-*+]$/.test(text)) {
              decos.push(
                Decoration.replace({ widget: new BulletWidget() }).range(from, to)
              );
            }
            return false;
          }
          case "TaskMarker": {
            if (!active) {
              const checked = /x/i.test(doc.sliceString(from, to));
              decos.push(
                Decoration.replace({
                  widget: new CheckboxWidget(checked, from, to),
                }).range(from, to)
              );
            }
            return false;
          }
          default:
            return true;
        }
      },
    });
  }
  return Decoration.set(decos, true);
}

// Block decorations (display-math / table / rule widgets) may only be supplied
// from a StateField — CodeMirror rejects block decorations coming from a
// ViewPlugin. A note-sized scratchpad is small enough to re-scan the whole
// document on each change, so there is no viewport bookkeeping to do.
function safeBuild(state) {
  try {
    return buildDecorations(state);
  } catch (err) {
    console.error("scratchpad live-preview build failed:", err);
    return Decoration.none;
  }
}

export const livePreview = StateField.define({
  create(state) {
    return safeBuild(state);
  },
  update(deco, tr) {
    if (tr.docChanged || tr.selection) return safeBuild(tr.state);
    return deco;
  },
  provide: (field) => EditorView.decorations.from(field),
});
