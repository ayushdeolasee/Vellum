// Math- and prose-specific editor intelligence that CodeMirror's stock
// extensions don't cover:
//   - promoting inline `$|$` to display `$$|$$` on a second `$`
//   - wrapping a selection in emphasis/quote marks (`* _ ~` ` `` ` " `) WITHOUT
//     auto-closing them while typing prose (closeBrackets can only do both)
// Bracket pairing, skip-over, and delete-pair now come from `closeBrackets` /
// `closeBracketsKeymap`, and Markdown list continuation from the `markdownKeymap`
// that `markdown()` installs by default — all wired up in main.js. Everything
// here dispatches ordinary transactions so CodeMirror's history/undo keeps
// working.
import { EditorView } from "@codemirror/view";
import { Prec } from "@codemirror/state";

// Selection-wrap marks that stock closeBrackets deliberately isn't configured
// for. The bracket pairs (`() [] {}` and `$`) are left to closeBrackets; these
// emphasis/quote marks are wrap-only — auto-closing them mid-prose is more
// annoying than helpful.
const WRAP = { "*": "*", _: "_", "`": "`", "~": "~", '"': '"' };

function charAt(state, pos) {
  return pos >= 0 && pos < state.doc.length ? state.doc.sliceString(pos, pos + 1) : "";
}

// Intercept single-character input for the two cases above. Returns true when
// handled, false to fall through to closeBrackets / the default insert.
export function handleInput(view, from, to, text) {
  if (text.length !== 1) return false;
  const ch = text;
  const state = view.state;
  // Keep multi-cursor typing simple — fall back to the default insert.
  if (state.selection.ranges.length !== 1) return false;

  // Wrap a non-empty selection in an emphasis/quote mark.
  if (from !== to) {
    if (!WRAP[ch]) return false;
    view.dispatch({
      changes: [{ from, insert: ch }, { from: to, insert: WRAP[ch] }],
      selection: { anchor: from + 1, head: to + 1 },
      userEvent: "input.type",
    });
    return true;
  }

  // Promote a lone inline `$|$` to display `$$|$$` on a second `$`, ahead of
  // closeBrackets — which would otherwise just skip over the closing `$`.
  if (ch === "$" && charAt(state, from - 1) === "$" && charAt(state, from) === "$" &&
      charAt(state, from - 2) !== "$" && charAt(state, from + 1) !== "$") {
    view.dispatch({
      changes: { from, insert: "$$" },
      selection: { anchor: from + 1 },
      userEvent: "input.type",
    });
    return true;
  }

  return false;
}

// High precedence so the `$$` promotion runs before closeBrackets' own input
// handler (which sits at default precedence).
export const editorIntelligence = Prec.high(EditorView.inputHandler.of(handleInput));
