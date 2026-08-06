# Readwise: reading, writing and de-duplicating highlights

Research for [Vellum#174](https://github.com/ayushdeolasee/Vellum/issues/174), part of the knowledge-base map ([Vellum#170](https://github.com/ayushdeolasee/Vellum/issues/170)).

All API facts from the [official Readwise API documentation](https://readwise.io/api_deets). The decision this feeds is [Vellum#180](https://github.com/ayushdeolasee/Vellum/issues/180).

## Verdict up front

**Write-back is supported and reliable de-duplication has a real hook.** Readwise exposes an idempotency key (`highlight_url`) that Vellum can populate with its own stable identity, making repeated pushes upserts rather than duplicates. This is a better position than expected.

## What Vellum already has

`Vellum/Services/Integrations/ReadwiseClient.swift` targets the **Reader v3** API — `api/v3/list/` for document pages, `withRawSourceUrl` for source resolution, and a move endpoint. It validates the token against `api/v2/auth/`.

That matters: **classic Readwise v2 (highlights) and Reader v3 (documents) are different API surfaces on the same access token.** Vellum already holds a valid token and already validates it against v2. Adding highlight sync needs **no new authentication, no new credential storage, and no new settings surface** — only new endpoints against the existing `ReadLaterHTTPClient`.

The existing client also carries a hard-won workaround worth preserving: `URLComponents` leaves `+` bare in query values, Readwise's Django backend decodes it as a space, and an opaque cursor containing one comes back mangled. `ReadwiseClient.page` percent-encodes it manually. Any new paginated endpoint needs the same treatment.

## 1. The export / read surface

**`GET https://readwise.io/api/v2/export/`** — the bulk endpoint, books with nested highlights.

Query parameters:
- `updatedAfter` (ISO 8601) — "Fetch only highlights updated after this date"
- `ids` — comma-separated book ids
- `includeDeleted` (true/false)
- `pageCursor` — pagination

Response: `count`, `nextPageCursor`, and `results` — an array of books each containing a nested `highlights` array.

Incremental sync is `updatedAfter` on subsequent runs, paginating via `nextPageCursor`. This is the same cursor shape the existing Reader v3 integration uses, so `IntegrationsSyncEngine`'s existing cursor/no-progress machinery should map across.

**`GET /api/v2/highlights/`** — granular list. Parameters: `page_size` (default 100, max 1000), `page`, `book_id`, `updated__lt`, `updated__gt`, `highlighted_at__lt`, `highlighted_at__gt`.

**`GET /api/v2/books/`** — parameters: `page_size`, `page`, `category`, `source`, `updated__lt`, `updated__gt`, `last_highlight_at__lt`, `last_highlight_at__gt`.

**`GET /api/v2/highlights/<id>/`** — single highlight detail.

### Authentication

Header `Authorization: Token XXX`, token from `readwise.io/access_token`. Validate with `GET https://readwise.io/api/v2/auth/` expecting **204**. This is exactly what `ReadwiseClient.validate` already does.

### Rate limits

- Default: **240 requests per minute** per access token.
- **Highlight LIST and Book LIST are restricted to 20 per minute.**
- 429 responses carry `Retry-After`.

The asymmetry matters: the bulk `export` endpoint is on the 240/min tier while the granular LIST endpoints are on 20/min. Bulk export is the right primitive for sync; per-highlight polling would throttle almost immediately.

## 2. Write-back — supported

**`POST https://readwise.io/api/v2/highlights/`**

Required:
- `text` (string, max 8191 chars)

Optional:
- `title` (max 511), `author` (max 1024)
- `image_url` (max 2047), `source_url` (max 2047)
- `source_type` (3–64 chars, no spaces)
- `category` — one of `books`, `articles`, `tweets`, `podcasts`
- `note` (max 8191, supports inline tagging)
- `location` (integer), `location_type` — one of `page`, `location`, `none`, `order`, `offset`, `time_offset`
- `highlighted_at` (ISO 8601)
- `highlight_url` (max 4095) — **"unique URL for updates"**

Response: 200, with an array of created/updated books each carrying a `modified_highlights` array of ids.

Only `text` is required, so the minimum viable push is trivial. Everything Vellum would want to send — page number via `location` + `location_type: page`, capture time via `highlighted_at`, the user's note via `note` — has a field.

## 3. Identity and de-duplication

Readwise's documented behaviour is to **"de-dupe highlights by title/author/text/source_url."**

That composite is fragile for Vellum's purposes: it keys on the highlight's *content*, so re-sending the same passage is safely idempotent, but *editing* a highlight's text would create a second record rather than updating the first.

The better hook is **`highlight_url`**, documented as the "unique URL for updates." Vellum can mint a stable URL encoding its own identity — the document's `docId` plus the annotation id — and use it as an idempotency key. Repeated pushes then become upserts, and edits update in place rather than duplicating.

This composes well with Vellum's existing model: `docId` is already the stable storage identity and already survives rename and path-to-`docId` promotion via `DocumentIdentity`. A `highlight_url` built from it inherits that stability.

Two caveats:
- Deduping *inbound* Readwise highlights against Vellum's own annotations on the same passage is the harder direction, and has no clean key. Readwise highlights originating elsewhere carry no Vellum identity, so matching falls back to fuzzy text comparison against `PositionData.selectedText`.
- `source_url` participating in the dedupe composite means a local PDF with no URL weakens the composite key further, reinforcing `highlight_url` as the identity to rely on.

## 4. Documents Readwise has never seen

There is no separate "create a book" step — `POST /api/v2/highlights/` accepts `title`, `author`, `source_type` and `category` alongside the highlight, and the response returns created/updated books. Sending a highlight for an unknown source implicitly creates the source.

`source_type` is a free-form 3–64 character identifier with no spaces, so Vellum can declare its own (e.g. `vellum`) and have its highlights grouped and attributable in the user's Readwise library. `category` must be one of the four enumerated values; a local PDF would most naturally be `books` or `articles`.

**Not established from the documentation:** whether a custom `source_type` requires registration or approval, and whether `category` choice affects Daily Review inclusion.

## 5. Readwise Reader (v3) versus classic Readwise (v2)

Distinct APIs on one token. Reader v3 (`api/v3/list/`, already integrated) is document-oriented — the read-later queue. Classic v2 is highlight-oriented.

**Not established:** whether highlights created via v2 surface inside Reader documents, and whether Reader v3 exposes its own highlight create/read endpoints. The Reader API was not documented on the `api_deets` page fetched. If the spec depends on Reader-side highlights specifically, this needs a follow-up against Reader's own documentation.

## 6. Raindrop

`RaindropClient.swift` uses `api.raindrop.io/rest/v1/` with `Bearer` auth, covering `user`, collections and a paginated `raindrops` list, plus a move endpoint.

Raindrop's model is bookmark-and-collection oriented rather than highlight-oriented. It does support highlights on saved items, but Vellum's integration does not currently touch them and the overlap with a reading knowledge base is thinner than Readwise's. **Not investigated further** — flagged as lower value, not as unsuitable.

## What this leaves for the decision

1. Vellum can be a **source**, not only a sink. Write-back works, needs no new auth, and `highlight_url` gives genuine idempotency.
2. Outbound dedupe is solved; **inbound dedupe is not** — matching a Readwise highlight to a Vellum annotation on the same passage has no reliable key and would rely on text matching.
3. Use `export` for sync (240/min), never the LIST endpoints (20/min).
4. The `+`-in-cursor workaround already in `ReadwiseClient` must be carried into any new paginated endpoint.
