# Tool Skills Reference

These are the ONLY tools you may call. Never invent other tool names — any
unrecognized tool is discarded. A maximum of 5 actions run per response.

## Coordinate System (used by `addNote`)
- Coordinates are in PDF points with the origin at the **top-left** of the page.
- `x` increases to the right; `y` increases **downward**.
- A typical US Letter page is 612 wide x 792 tall. If you don't know the page
  size, assume those dimensions.
- All coordinates and sizes must be finite and non-negative. Omit any field you
  are unsure about and a sensible default is used instead.

## Tool: `goToPage`
### Purpose
Navigate the document viewport to a specific page.

### Use When
- The user asks to jump, move, navigate, or inspect a specific page.
- You need to guide the user to evidence located on another page.

### Input Schema
```json
{ "pageNumber": number }
```

### Notes
- `pageNumber` is 1-indexed (the first page is 1).
- Out-of-range values are clamped to the valid page range.
- Prefer exact page numbers when the request is explicit. If the request is
  vague, choose the most likely page and explain your choice in `reply`.

## Tool: `addNote`
### Purpose
Create a sticky-note annotation on a page with user-visible text.

### Use When
- The user asks to add a note, reminder, summary, TODO, or comment.
- You want to save an interpretation or action item into the document.

### Input Schema
```json
{
  "pageNumber": number,
  "text": string,
  "x"?: number,
  "y"?: number
}
```

### Notes
- `pageNumber` is 1-indexed; `text` is required and must be non-empty
  (empty-text notes are skipped). Keep it concise and useful.
- `x` / `y` place the note's top-left anchor (see Coordinate System). Omit them
  if placement is unclear; they default to (72, 96).
- Do not add empty or redundant notes.

## Tool: `addHighlight`
### Purpose
Create a highlight annotation over a specific run of text on a page.

### Use When
- The user asks to highlight text or visually mark important content.
- You identify a critical statement, value, or phrase worth emphasizing.

### Input Schema
```json
{
  "pageNumber": number,
  "text": string,
  "color"?: string
}
```

### Notes
- `pageNumber` is 1-indexed.
- `text` is REQUIRED: it is the exact phrase to highlight. The app locates that
  phrase in the page's text and draws the highlight over its real position — you
  do NOT supply any coordinates. Quote the phrase verbatim from the document
  (whitespace differences are tolerated, but spelling/words must match).
- Keep `text` to the specific phrase of interest. Highlighting an entire
  paragraph is rarely useful; pick the key sentence or term.
- If the phrase does not appear verbatim on that page, the highlight is skipped,
  so prefer text you can see in the provided page text.
- `color` must be a valid CSS color (hex like `#fef08a` preferred). Invalid
  values fall back to the default yellow.
