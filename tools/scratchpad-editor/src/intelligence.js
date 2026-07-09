// Light editor intelligence for Markdown + LaTeX notes: auto-pairing `$…$` and
// brackets, skip-over on closers, display-math promotion, selection wrapping,
// smart backspace, and list continuation. Everything dispatches ordinary
// transactions so CodeMirror's own history/undo keeps working.
import { EditorView, keymap } from "@codemirror/view";
import { Prec } from "@codemirror/state";

// Openers that auto-close to a matching partner with the caret in the middle.
const AUTO_CLOSE = { $: "$", "(": ")", "[": "]", "{": "}" };
// Characters that wrap a non-empty selection. Emphasis marks live here but not
// in AUTO_CLOSE — auto-closing them while typing prose is more annoying than
// helpful.
const WRAP = {
  $: "$", "(": ")", "[": "]", "{": "}",
  "*": "*", _: "_", "`": "`", "~": "~", '"': '"',
};
// Closers the caret can "type through" instead of inserting a duplicate.
const CLOSERS = new Set([")", "]", "}", "$"]);

function charAt(state, pos) {
  return pos >= 0 && pos < state.doc.length ? state.doc.sliceString(pos, pos + 1) : "";
}

// Only auto-close when the caret isn't butting up against existing word
// content, and isn't escaped (`\$`, `\{`, …).
function shouldAutoClose(before, after) {
  if (before === "\\") return false;
  if (after && !/\s/.test(after) && !")]}$,.;:".includes(after)) return false;
  return true;
}

// Intercept single-character input for pairing/wrapping/skip-over. Returns true
// when it handled the keystroke, false to let CodeMirror insert normally.
// Exported for unit tests; wired into CodeMirror via `autoPairInput` below.
export function handleAutoPair(view, from, to, text) {
  if (text.length !== 1) return false;
  const ch = text;
  const state = view.state;
  // Keep multi-cursor typing simple — fall back to the default insert.
  if (state.selection.ranges.length !== 1) return false;

  // 1. Wrap a non-empty selection in the pair.
  if (from !== to && WRAP[ch]) {
    view.dispatch({
      changes: [{ from, insert: ch }, { from: to, insert: WRAP[ch] }],
      selection: { anchor: from + 1, head: to + 1 },
      userEvent: "input.type",
    });
    return true;
  }

  if (from !== to) return false;

  const before = charAt(state, from - 1);
  const after = charAt(state, from);

  // 2. Promote a lone inline `$|$` to display `$$|$$` on a second `$`.
  if (ch === "$" && before === "$" && after === "$" &&
      charAt(state, from - 2) !== "$" && charAt(state, from + 1) !== "$") {
    view.dispatch({
      changes: { from, insert: "$$" },
      selection: { anchor: from + 1 },
      userEvent: "input.type",
    });
    return true;
  }

  // 3. Skip over an existing closer rather than duplicating it.
  if (CLOSERS.has(ch) && after === ch) {
    view.dispatch({ selection: { anchor: from + 1 } });
    return true;
  }

  // 4. Auto-close into a pair with the caret in the middle.
  if (AUTO_CLOSE[ch] && shouldAutoClose(before, after)) {
    view.dispatch({
      changes: { from, insert: ch + AUTO_CLOSE[ch] },
      selection: { anchor: from + 1 },
      userEvent: "input.type",
    });
    return true;
  }

  return false;
}

const autoPairInput = EditorView.inputHandler.of(handleAutoPair);

// Backspace between an empty pair (`$|$`, `(|)`, …) removes both sides.
export function deletePair(view) {
  const { state } = view;
  const range = state.selection.main;
  if (!range.empty || state.selection.ranges.length !== 1) return false;
  const before = charAt(state, range.from - 1);
  const after = charAt(state, range.from);
  if (AUTO_CLOSE[before] && AUTO_CLOSE[before] === after) {
    view.dispatch({
      changes: { from: range.from - 1, to: range.from + 1 },
      userEvent: "delete.backward",
    });
    return true;
  }
  return false;
}

// Work out how the next line should begin: continue a bullet/checkbox/ordered
// list, or (returning null) fall back to a plain newline.
function listContinuation(line) {
  const indentMatch = line.match(/^[ \t]*/);
  const indent = indentMatch ? indentMatch[0] : "";
  const rest = line.slice(indent.length);

  // Unordered bullets, with optional GitHub-style checkbox.
  const bullet = ["- ", "* ", "+ "].find((b) => rest.startsWith(b));
  if (bullet) {
    const body = rest.slice(bullet.length);
    const box = ["[ ] ", "[x] ", "[X] "].find((b) => body.startsWith(b));
    if (box) {
      const content = body.slice(box.length);
      return { indent, marker: indent + bullet + "[ ] ", isEmptyItem: content.trim() === "" };
    }
    return { indent, marker: indent + bullet, isEmptyItem: body.trim() === "" };
  }

  // Ordered list: `1. ` or `1) ` → increment the number.
  const ordered = rest.match(/^(\d+)([.)]) (.*)$/);
  if (ordered) {
    const next = (parseInt(ordered[1], 10) || 0) + 1;
    return {
      indent,
      marker: indent + next + ordered[2] + " ",
      isEmptyItem: ordered[3].trim() === "",
    };
  }

  return null;
}

export function continueList(view) {
  const { state } = view;
  const range = state.selection.main;
  if (!range.empty || state.selection.ranges.length !== 1) return false;
  const line = state.doc.lineAt(range.from);
  const cont = listContinuation(state.doc.sliceString(line.from, range.from));
  if (!cont) return false;

  // Enter on an empty list item clears the marker instead of continuing.
  if (cont.isEmptyItem) {
    view.dispatch({
      changes: { from: line.from, to: range.from, insert: cont.indent },
      selection: { anchor: line.from + cont.indent.length },
      userEvent: "delete.backward",
    });
    return true;
  }

  const insert = "\n" + cont.marker;
  view.dispatch({
    changes: { from: range.from, to: range.to, insert },
    selection: { anchor: range.from + insert.length },
    userEvent: "input",
    scrollIntoView: true,
  });
  return true;
}

// Bound at high precedence so they run before the default Enter/Backspace.
const smartKeys = Prec.high(
  keymap.of([
    { key: "Enter", run: continueList },
    { key: "Backspace", run: deletePair },
  ])
);

export const editorIntelligence = [autoPairInput, smartKeys];
