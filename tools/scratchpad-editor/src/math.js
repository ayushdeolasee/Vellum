// Adds `$...$` inline and `$$...$$` block math to the Markdown Lezer grammar so
// the live-preview plugin can find math nodes in the syntax tree (and so
// emphasis parsing does not mangle `x_i`, `a*b`, etc. inside math).
import { tags as t } from "@lezer/highlight";

const DOLLAR = 36; // $
const NEWLINE = 10; // \n
const BACKSLASH = 92; // \

// Inline `$ ... $` on a single line. Deliberately ignores `$$` so display math
// is left for the block parser.
const InlineMathParser = {
  name: "InlineMath",
  parse(cx, next, pos) {
    if (next !== DOLLAR) return -1;
    if (cx.char(pos + 1) === DOLLAR) return -1;
    let end = pos + 1;
    while (end < cx.end) {
      const c = cx.char(end);
      if (c === BACKSLASH) {
        end += 2;
        continue;
      }
      if (c === NEWLINE) return -1;
      if (c === DOLLAR) break;
      end++;
    }
    if (end >= cx.end || cx.char(end) !== DOLLAR) return -1;
    if (end === pos + 1) return -1; // empty `$$` handled as block
    return cx.addElement(cx.elt("InlineMath", pos, end + 1));
  },
};

// Fenced display math. Handles single-line `$$ x $$` and multi-line blocks that
// open with `$$` and run until a line containing the closing `$$`.
const BlockMathParser = {
  name: "BlockMath",
  parse(cx, line) {
    const pos = line.pos;
    const text = line.text;
    if (text.charCodeAt(pos) !== DOLLAR || text.charCodeAt(pos + 1) !== DOLLAR) {
      return false;
    }
    const start = cx.lineStart + pos;
    const after = text.slice(pos + 2);
    const sameLineClose = after.indexOf("$$");
    if (sameLineClose >= 0) {
      const end = cx.lineStart + pos + 2 + sameLineClose + 2;
      cx.addElement(cx.elt("BlockMath", start, end));
      cx.nextLine();
      return true;
    }
    let end = -1;
    while (cx.nextLine()) {
      const idx = cx.line.text.indexOf("$$");
      if (idx >= 0) {
        end = cx.lineStart + idx + 2;
        cx.nextLine();
        break;
      }
    }
    if (end < 0) {
      end = cx.lineStart + (cx.line ? cx.line.text.length : 0);
    }
    cx.addElement(cx.elt("BlockMath", start, end));
    return true;
  },
};

export const mathExtension = {
  defineNodes: [
    { name: "InlineMath", style: t.monospace },
    { name: "BlockMath", block: true, style: t.monospace },
  ],
  parseInline: [InlineMathParser],
  parseBlock: [BlockMathParser],
};
