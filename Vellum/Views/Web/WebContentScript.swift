import Foundation

// The Vellum content script — a port of
// src-tauri/assets/vellum-content-script.js with only the transport adapted
// for WKWebView:
//  - the top-frame guard is removed (the page is the webview's main frame,
//    not an iframe),
//  - `window.parent.postMessage(msg, "*")` becomes
//    `window.webkit.messageHandlers.vellum.postMessage(msg)`,
//  - the parent-window "message" listener becomes `window.__vellumCmd(d)`,
//    invoked by the shell via evaluateJavaScript.
// Everything else — the whitespace table, 3600-char page chunking, quote
// contexts, resolveHighlight scoring — is byte-for-byte the anchor
// compatibility contract and must not drift.
//
// The code is split across two JS worlds:
//  - `source` runs in an isolated WKContentWorld ("VellumBridge", see
//    WebViewerController.makeWebView) as a WKUserScript, so page scripts can
//    never reach the webkit message bridge or window.__vellumCmd. Isolated
//    worlds share the DOM (overlays, selection, events all work) but not JS
//    state, so the per-page constants arrive as data- attributes on
//    <html> rather than window globals.
//  - `pageWorldSource` is a small unprivileged bootstrap injected inline into
//    the served HTML by WebHtml.prepareHtml. It publishes those attributes
//    and hosts the two hooks that only work from the page's own world:
//    wrapping history.pushState/replaceState and overriding window.open.

enum WebContentScript {
    static let source = #"""
/*
 * Vellum content script — injected into reader webpages as a WKUserScript in
 * the isolated "VellumBridge" content world (page scripts cannot reach the
 * webkit message bridge). Shares the page's DOM but not its JS state.
 *
 * Responsibilities:
 *  - extract readable text and chunk it into "virtual pages"
 *  - report scroll position / current virtual page
 *  - report text selections (text + raw offsets + viewport rects)
 *  - render highlight overlays anchored by text offsets
 *  - locate arbitrary text for AI-created highlights
 *  - capture / scroll to exact reading positions (point bookmarks)
 *  - intercept link clicks so navigation stays inside the reader
 */
(function () {
  "use strict";
  if (window.__vellumLoaded) return;
  window.__vellumLoaded = true;

  // Per-page constants published by the page-world bootstrap as DOM
  // attributes (the DOM is the only state the two worlds share).
  var PAGE_URL =
    document.documentElement.getAttribute("data-vellum-page-url") || location.href;
  var PAGE_TARGET_CHARS = 3600;
  var MAX_PAGES = 200;

  // ------------------------------------------------------------------
  // Soft-navigation tracking (see plans/web-proxy-truthful-urls.html)
  //
  // The history.pushState/replaceState remap shim lives in the page-world
  // bootstrap (pageWorldSource) — an isolated-world override can't touch
  // the page's own history binding. It dispatches "__vellum-url-changed"
  // on the shared document after each call; from here we keep PAGE_URL
  // fresh so re-inits attribute extraction, archives, and annotations to
  // the right record.
  // ------------------------------------------------------------------
  var REAL_PROTOCOL = "https:";
  var REAL_HOST = "";
  try {
    var realParsed = new URL(PAGE_URL);
    REAL_PROTOCOL = realParsed.protocol;
    REAL_HOST = realParsed.host;
  } catch (e) {
    /* PAGE_URL not absolute; tracking stays inert */
  }

  var TRACKING_KEYS = ["fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "ref_src", "twclid"];

  // The real-URL equivalent of the current location, with tracking params
  // dropped like the app-side normalizer — PAGE_URL comparisons and init
  // reports must not thrash on utm noise.
  function currentRealUrl() {
    var search = "";
    if (location.search && location.search.length > 1) {
      var kept = [];
      var pairs = location.search.slice(1).split("&");
      for (var i = 0; i < pairs.length; i++) {
        var keyName = pairs[i].split("=")[0].replace(/\+/g, " ");
        try {
          keyName = decodeURIComponent(keyName);
        } catch (e) {
          /* keep raw */
        }
        if (/^utm_/.test(keyName)) continue;
        if (TRACKING_KEYS.indexOf(keyName) !== -1) continue;
        kept.push(pairs[i]);
      }
      if (kept.length) search = "?" + kept.join("&");
    }
    return REAL_PROTOCOL + "//" + location.host + location.pathname + search;
  }

  var urlReinitTimer = null;
  function noteUrlChange() {
    if (!REAL_HOST) return;
    var real = currentRealUrl();
    if (real === PAGE_URL) return;
    PAGE_URL = real;
    // Soft navigation: re-extract and re-init (debounced — the router is
    // still swapping DOM in) so the shell rebinds to the new address.
    if (urlReinitTimer) clearTimeout(urlReinitTimer);
    urlReinitTimer = setTimeout(function () {
      urlReinitTimer = null;
      initialize(true);
    }, 400);
  }

  document.addEventListener("__vellum-url-changed", noteUrlChange);
  window.addEventListener("popstate", noteUrlChange);

  // ------------------------------------------------------------------
  // YouTube embed fallback facade
  //
  // YouTube's embed player refuses to play when the embedding document
  // cannot send an http(s) Referer header. WebKit never sends one from
  // a custom-scheme (vellum-web://) page, so every embed variant dies
  // with "Error 153 — Video player configuration error" (verified
  // empirically against bare, autoplay, and jsapi+origin embeds; the
  // origin query param does not help). Unfixable client-side — replace
  // the dead player with a clickable thumbnail that opens the video in
  // the system browser via the app shell.
  // ------------------------------------------------------------------
  function youtubeVideoId(raw) {
    if (!raw) return null;
    try {
      var u = new URL(String(raw), location.href);
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(u.hostname)) return null;
      var m = u.pathname.match(/^\/embed\/([\w-]{6,})/);
      // `/embed/videoseries?list=...` is a playlist embed, not a video — its
      // literal "videoseries" id yields a broken thumbnail and a dead
      // watch?v=videoseries link. Leave the playlist iframe alone.
      if (!m || m[1] === "videoseries") return null;
      return m[1];
    } catch (e) {
      return null;
    }
  }

  function replaceWithFacade(frame) {
    var id = youtubeVideoId(frame.getAttribute("src"));
    if (!id || !frame.parentNode) return;
    var facade = document.createElement("div");
    facade.setAttribute("data-vellum-youtube", id);
    // Keyboard/AT-reachable: the facade is the only way to reach the video.
    facade.setAttribute("role", "button");
    facade.setAttribute("tabindex", "0");
    facade.setAttribute("aria-label", "Watch on YouTube");
    var w = +(frame.getAttribute("width") || 0);
    var h = +(frame.getAttribute("height") || 0);
    facade.style.cssText =
      "position:relative;cursor:pointer;background:#000 center/cover no-repeat;" +
      "background-image:url('https://i.ytimg.com/vi/" + id + "/hqdefault.jpg');" +
      (w > 0 && h > 0
        ? "width:" + w + "px;height:" + h + "px;"
        : "width:100%;aspect-ratio:16/9;");
    var badge = document.createElement("div");
    badge.style.cssText =
      "position:absolute;inset:0;display:flex;align-items:center;justify-content:center;" +
      "flex-direction:column;gap:8px;color:#fff;font:500 14px -apple-system,sans-serif;" +
      "background:rgba(0,0,0,0.35);text-shadow:0 1px 3px rgba(0,0,0,0.8);";
    badge.innerHTML =
      '<svg width="68" height="48" viewBox="0 0 68 48"><path d="M66.52 7.74a8 8 0 0 0' +
      "-5.6-5.66C55.98.86 34 .86 34 .86s-21.98 0-26.92 1.22a8 8 0 0 0-5.6 5.66C.26 " +
      "12.72.26 24 .26 24s0 11.28 1.22 16.26a8 8 0 0 0 5.6 5.66C12.02 47.14 34 47.14 " +
      '34 47.14s21.98 0 26.92-1.22a8 8 0 0 0 5.6-5.66C67.74 35.28 67.74 24 67.74 24s0' +
      '-11.28-1.22-16.26z" fill="#f00"/><path d="M45 24 27 14v20z" fill="#fff"/></svg>' +
      "<span>Watch on YouTube</span>";
    facade.appendChild(badge);
    facade.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      post("open-youtube", { id: id });
    });
    // Enter/Space activate it the same way a click does, for keyboard users.
    facade.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
        e.preventDefault();
        e.stopPropagation();
        post("open-youtube", { id: id });
      }
    });
    frame.parentNode.replaceChild(facade, frame);
  }

  if (REAL_HOST) {
    // Catch player iframes however they arrive: SSR markup, innerHTML,
    // or the IFrame API's createElement path.
    new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var added = mutations[i].addedNodes;
        for (var j = 0; j < added.length; j++) {
          var node = added[j];
          if (!node) continue;
          if (node.tagName === "IFRAME") {
            replaceWithFacade(node);
          } else if (node.querySelectorAll) {
            node.querySelectorAll("iframe[src]").forEach(replaceWithFacade);
          }
        }
      }
    }).observe(document.documentElement, { childList: true, subtree: true });
    // This script is injected at document end, so DOMContentLoaded may
    // already be behind us — scan immediately in that case.
    var scanFrames = function () {
      document.querySelectorAll("iframe[src]").forEach(replaceWithFacade);
    };
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", scanFrames);
    } else {
      scanFrames();
    }
  }

  // Raw text domain: concatenation of all accepted text nodes.
  var entries = []; // [{ node, start, end }] raw offsets per text node
  var rawText = "";
  // Normalized domain: whitespace-collapsed text for search/AI context.
  var normText = "";
  var normMap = []; // normMap[i] = raw offset of normText[i]
  var pages = []; // [{ number, start(raw), end(raw), normStart, normEnd, text }]
  var pageTops = null; // cached document-Y of each page start
  var overlayRoot = null;
  var appliedHighlights = []; // [{ id, color, start, end, text, prefix, suffix }]
  // Document-coordinate rects of the rendered highlight divs. The divs are
  // pointer-events:none (so text under a highlight stays selectable), so
  // clicks are matched against these instead.
  var highlightHitRects = []; // [{ id, left, top, width, height }]
  var appliedNotes = []; // same anchor shape + { content } for the marker tooltip
  // Point bookmarks: same anchor shape. Re-resolved against the current DOM
  // so the "bookmarked here?" toolbar state survives restarts and reflows.
  var appliedBookmarks = [];
  var resolvedBookmarks = []; // [{ id, start }] after re-anchoring
  var noteMode = false;
  var initialized = false;

  // Highlight edge-resize state. The app shell nominates the selected highlight
  // (the one whose edit popover is open); we draw draggable blue end bars on it,
  // mirroring the PDF viewer. Dragging a bar re-anchors that edge to the caret
  // under the pointer while the opposite edge stays pinned.
  var selectedHighlightId = null;
  // Resolved raw offsets of the selected highlight this render, so a drag can
  // read its pinned edge without re-resolving.
  var selectedHighlightRange = null; // { start, end }
  // Live drag preview: while set, renderHighlights draws these offsets for the
  // matching id instead of the stored ones (the store is only written on drop).
  var resizePreview = null; // { id, start, end }
  var resizeState = null; // { id, edge, start, end, anchorOffset } during a drag
  // True from a handle mousedown until just after the drop, so the trailing
  // mouseup doesn't clear the selection / close the edit popover.
  var resizing = false;

  // Find bar state (⌘F): matches are raw-offset {start,end} pairs, rendered in
  // their own overlay layer so the app's find never touches annotation layers.
  var findRoot = null;
  var findMatches = [];
  var findIndex = -1;

  function post(type, payload) {
    var msg = { vellum: true, type: type };
    if (payload) {
      for (var k in payload) msg[k] = payload[k];
    }
    try {
      window.webkit.messageHandlers.vellum.postMessage(msg);
    } catch (err) {
      /* bridge gone */
    }
  }

  function debounce(fn, ms) {
    var t = null;
    return function () {
      if (t) clearTimeout(t);
      t = setTimeout(fn, ms);
    };
  }

  // ------------------------------------------------------------------
  // Text extraction
  // ------------------------------------------------------------------

  var SKIP_TAGS = {
    SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, IFRAME: 1,
    OBJECT: 1, TEXTAREA: 1, SELECT: 1, HEAD: 1, TITLE: 1, svg: 1, SVG: 1,
  };

  function buildTextMap() {
    entries = [];
    rawText = "";
    normText = "";
    normMap = [];

    var root = document.body || document.documentElement;
    if (!root) return;

    var walker = document.createTreeWalker(
      root,
      NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
      {
        acceptNode: function (node) {
          if (node.nodeType === 1) {
            if (SKIP_TAGS[node.tagName]) return NodeFilter.FILTER_REJECT;
            if (node.hasAttribute && (node.hasAttribute("hidden") || node.getAttribute("aria-hidden") === "true")) {
              return NodeFilter.FILTER_REJECT;
            }
            // Cheap inline-style visibility check (computed styles for every
            // element would be too slow on large pages).
            if (
              node.style &&
              (node.style.display === "none" || node.style.visibility === "hidden")
            ) {
              return NodeFilter.FILTER_REJECT;
            }
            if (node === overlayRoot) return NodeFilter.FILTER_REJECT;
            if (node === findRoot) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_SKIP;
          }
          return NodeFilter.FILTER_ACCEPT;
        },
      }
    );

    var n;
    while ((n = walker.nextNode())) {
      var t = n.nodeValue;
      if (!t) continue;
      var start = rawText.length;
      rawText += t;
      entries.push({ node: n, start: start, end: rawText.length });
    }

    // Build the whitespace-collapsed view with a norm->raw index map.
    var lastWasSpace = true;
    for (var i = 0; i < rawText.length; i++) {
      var isSpace = isSpaceCode(rawText.charCodeAt(i));
      if (isSpace) {
        if (!lastWasSpace) {
          normText += " ";
          normMap.push(i);
          lastWasSpace = true;
        }
      } else {
        normText += rawText[i];
        normMap.push(i);
        lastWasSpace = false;
      }
    }
  }

  function buildPages() {
    pages = [];
    pageTops = null;
    var total = normText.length;
    if (total === 0) {
      pages.push({ number: 1, start: 0, end: 0, normStart: 0, normEnd: 0, text: "" });
      return;
    }

    var cursor = 0;
    while (cursor < total && pages.length < MAX_PAGES) {
      var end = Math.min(cursor + PAGE_TARGET_CHARS, total);
      if (end < total) {
        // Prefer breaking at a sentence, then any space, inside the last 40%.
        var slice = normText.slice(cursor, end);
        var minBreak = Math.floor(slice.length * 0.6);
        var sentence = slice.lastIndexOf(". ");
        var space = slice.lastIndexOf(" ");
        var breakAt = sentence > minBreak ? sentence + 1 : space > minBreak ? space : slice.length;
        end = cursor + breakAt;
      }
      if (pages.length === MAX_PAGES - 1) end = total; // merge remainder
      pages.push({
        number: pages.length + 1,
        start: normMap[cursor],
        end: normMap[end - 1] + 1,
        normStart: cursor,
        normEnd: end,
        text: normText.slice(cursor, end).trim(),
      });
      cursor = end;
      while (cursor < total && normText[cursor] === " ") cursor++;
    }
  }

  // ------------------------------------------------------------------
  // Raw offset <-> DOM Range mapping
  // ------------------------------------------------------------------

  function entryIndexForRaw(offset) {
    var lo = 0;
    var hi = entries.length - 1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      var e = entries[mid];
      if (offset < e.start) hi = mid - 1;
      else if (offset >= e.end) lo = mid + 1;
      else return mid;
    }
    return -1;
  }

  function rangeFromRaw(start, end) {
    if (entries.length === 0) return null;
    start = Math.max(0, Math.min(start, rawText.length - 1));
    end = Math.max(start + 1, Math.min(end, rawText.length));
    var si = entryIndexForRaw(start);
    var ei = entryIndexForRaw(end - 1);
    if (si === -1 || ei === -1) return null;
    var se = entries[si];
    var ee = entries[ei];
    try {
      var range = document.createRange();
      range.setStart(se.node, start - se.start);
      range.setEnd(ee.node, end - ee.start);
      return range;
    } catch (err) {
      return null;
    }
  }

  function rawOffsetOfBoundary(container, offset) {
    if (container.nodeType === 3) {
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].node === container) return entries[i].start + offset;
      }
      return null;
    }
    // Element boundary: find the first text entry at/after the boundary point.
    var probe = document.createRange();
    try {
      probe.setStart(container, offset);
      probe.collapse(true);
    } catch (err) {
      return null;
    }
    for (var j = 0; j < entries.length; j++) {
      try {
        // comparePoint: -1 = entry before the boundary, 0/1 = at or after.
        // We want the first entry at/after the boundary point.
        if (probe.comparePoint(entries[j].node, 0) >= 0) return entries[j].start;
      } catch (err2) {
        /* node not comparable (detached) */
      }
    }
    return rawText.length;
  }

  function pageForRaw(offset) {
    for (var i = pages.length - 1; i >= 0; i--) {
      if (offset >= pages[i].start) return pages[i].number;
    }
    return 1;
  }

  function normalizeStr(s) {
    return (s || "").replace(/\s+/g, " ").trim().toLowerCase();
  }

  // Collapse whitespace runs to single spaces without lowercasing or trimming.
  function collapseWs(s) {
    return (s || "").replace(/\s+/g, " ");
  }

  // Case-insensitive search is only safe when lowercasing preserves string
  // length — Unicode case folds like İ (U+0130) expand, which would desync
  // indexes into normMap and corrupt anchor offsets. When folding changes
  // either side's length, fall back to case-sensitive matching.
  function searchPair(needleRaw) {
    var hayFolded = normText.toLowerCase();
    var needleFolded = needleRaw.toLowerCase();
    if (
      hayFolded.length !== normText.length ||
      needleFolded.length !== needleRaw.length
    ) {
      return { hay: normText, needle: needleRaw, folded: false };
    }
    return { hay: hayFolded, needle: needleFolded, folded: true };
  }

  // Text-quote anchor context (W3C-style) around a raw-offset range:
  // normalized prefix/suffix, ~32 chars each side, drawn from up to 200 raw
  // chars of surrounding text. Case is preserved; lowercase only to compare.
  function quoteContext(start, end) {
    var prefix = collapseWs(rawText.slice(Math.max(0, start - 200), start));
    var suffix = collapseWs(rawText.slice(end, end + 200));
    if (prefix.length > 32) prefix = prefix.slice(prefix.length - 32);
    if (suffix.length > 32) suffix = suffix.slice(0, 32);
    return { prefix: prefix, suffix: suffix };
  }

  // ------------------------------------------------------------------
  // Point anchors (bookmarks at an arbitrary reading position)
  // ------------------------------------------------------------------

  // Mirrors JS /\s/ so the text map and the collapse-based needle
  // normalization agree; a mismatch (e.g. thin/ideographic spaces) would make
  // locate/re-anchor searches miss on pages that use them.
  function isSpaceCode(code) {
    return (
      code <= 32 ||
      code === 160 ||
      code === 0x1680 ||
      (code >= 0x2000 && code <= 0x200a) ||
      code === 0x2028 ||
      code === 0x2029 ||
      code === 0x202f ||
      code === 0x205f ||
      code === 0x3000 ||
      code === 0xfeff
    );
  }

  // A fixed/sticky ancestor means the node is pinned to the viewport (header,
  // nav, cookie bar) rather than scrolling with the article. Such nodes must
  // never anchor a "bookmark this spot" — they'd resolve to the same place at
  // every scroll position.
  function isPinned(node) {
    var el = node && node.nodeType === 3 ? node.parentElement : node;
    while (el && el !== document.body && el !== document.documentElement) {
      var pos;
      try {
        pos = window.getComputedStyle(el).position;
      } catch (err) {
        pos = "";
      }
      if (pos === "fixed" || pos === "sticky") return true;
      el = el.parentElement;
    }
    return false;
  }

  // Raw offset for the caret at a viewport point, or null if the point misses
  // text or lands on pinned (fixed/sticky) chrome.
  function rawOffsetAtPoint(x, y) {
    var range = null;
    if (document.caretRangeFromPoint) {
      range = document.caretRangeFromPoint(x, y);
    } else if (document.caretPositionFromPoint) {
      var pos = document.caretPositionFromPoint(x, y);
      if (pos && pos.offsetNode) {
        try {
          range = document.createRange();
          range.setStart(pos.offsetNode, pos.offset);
        } catch (err) {
          range = null;
        }
      }
    }
    if (!range) return null;
    if (isPinned(range.startContainer)) return null;
    return rawOffsetOfBoundary(range.startContainer, range.startOffset);
  }

  // Anchor for "bookmark this spot": the first flowing text at the top of the
  // viewport, described the same way as a highlight (raw offsets + snippet +
  // text-quote context) so it re-anchors after reflows and re-renders. We scan
  // downward from the top edge so a pinned header doesn't hijack the anchor,
  // and validate that the chosen offset actually renders at the current scroll
  // position before trusting it.
  function captureViewportAnchor() {
    if (rawText.length === 0) return null;

    var xs = [Math.floor(window.innerWidth / 2), 24, Math.max(24, window.innerWidth - 24)];
    var scrollTop = window.scrollY;
    var start = null;

    // Probe progressively further down the viewport until we hit real,
    // non-pinned text that sits at/after the current scroll position.
    for (var y = 8; y < window.innerHeight * 0.9 && start === null; y += 16) {
      for (var xi = 0; xi < xs.length && start === null; xi++) {
        var candidate = rawOffsetAtPoint(xs[xi], y);
        if (candidate === null) continue;
        var probe = rangeFromRaw(candidate, Math.min(rawText.length, candidate + 1));
        if (!probe) continue;
        // A caret over non-text content resolves to a *nearby* text node,
        // which may itself be pinned chrome — recheck the resolved node, not
        // just where the caret landed.
        if (isPinned(probe.startContainer)) continue;
        var docTop = probe.getBoundingClientRect().top + scrollTop;
        // Reject anything that resolves above the viewport top (stale).
        if (docTop >= scrollTop - 4) start = candidate;
      }
    }

    if (start === null) {
      // Hit-testing failed everywhere (e.g. an image fills the viewport top):
      // fall back to the start of the current virtual page.
      if (!pageTops) computePageTops();
      start = pages.length > 0 ? pages[0].start : 0;
      for (var i = pages.length - 1; i >= 0; i--) {
        if (pageTops[i] <= scrollTop + 16) {
          start = pages[i].start;
          break;
        }
      }
    }

    while (start < rawText.length && isSpaceCode(rawText.charCodeAt(start))) start++;
    if (start >= rawText.length) start = Math.max(0, rawText.length - 1);
    var end = Math.min(rawText.length, start + 160);
    var text = collapseWs(rawText.slice(start, end)).trim();
    if (!text) return null;

    // Where the anchor text sits in the viewport right now. Non-text content
    // (images, figures) can push the first text well below the viewport top;
    // restoring to this offset puts the whole captured view back, not just
    // the text.
    var viewportY = 16;
    var anchorRange = rangeFromRaw(start, Math.min(rawText.length, start + 1));
    if (anchorRange) {
      var anchorTop = anchorRange.getBoundingClientRect().top;
      if (isFinite(anchorTop)) {
        viewportY = Math.max(0, Math.min(window.innerHeight, anchorTop));
      }
    }

    var ctx = quoteContext(start, end);
    return {
      start: start,
      end: end,
      text: text,
      prefix: ctx.prefix,
      suffix: ctx.suffix,
      offset: viewportY,
      pageNumber: pageForRaw(start),
    };
  }

  // ------------------------------------------------------------------
  // Highlight overlays (document-coordinate divs; pointer-events: none)
  // ------------------------------------------------------------------

  function ensureOverlayRoot() {
    if (overlayRoot && overlayRoot.isConnected) return overlayRoot;
    overlayRoot = document.createElement("div");
    overlayRoot.id = "__vellum-highlights";
    overlayRoot.setAttribute("aria-hidden", "true");
    overlayRoot.style.cssText =
      "position:absolute;left:0;top:0;width:0;height:0;overflow:visible;" +
      "pointer-events:none;z-index:2147483646;";
    (document.documentElement || document.body).appendChild(overlayRoot);
    return overlayRoot;
  }

  function resolveHighlight(h) {
    var normSel = normalizeStr(h.text);
    if (
      typeof h.start === "number" &&
      typeof h.end === "number" &&
      h.end > h.start &&
      h.end <= rawText.length
    ) {
      var current = normalizeStr(rawText.slice(h.start, h.end));
      if (normSel && current === normSel) return { start: h.start, end: h.end };
      if (!normSel) return { start: h.start, end: h.end };
    }
    if (!normSel) return null;

    // Score every occurrence: distance from the offset hint, minus a large
    // bonus per matching side of the stored text-quote context. Occurrences
    // whose surroundings match the annotation's prefix/suffix win even when
    // the page has shifted the raw offsets a long way.
    var CONTEXT_BONUS = 100000;
    var pair = searchPair(collapseWs(h.text).trim());
    var hay = pair.hay;
    var needle = pair.needle;
    var hPrefix = typeof h.prefix === "string" ? collapseWs(h.prefix) : "";
    var hSuffix = typeof h.suffix === "string" ? collapseWs(h.suffix) : "";
    if (pair.folded) {
      hPrefix = hPrefix.toLowerCase();
      hSuffix = hSuffix.toLowerCase();
    }
    var best = -1;
    var bestScore = Infinity;
    var idx = hay.indexOf(needle);
    while (idx !== -1) {
      var rawStart = normMap[idx];
      var score = typeof h.start === "number" ? Math.abs(rawStart - h.start) : idx;
      if (hPrefix) {
        var before = hay.slice(Math.max(0, idx - hPrefix.length), idx);
        if (before && hPrefix.slice(hPrefix.length - before.length) === before) {
          score -= CONTEXT_BONUS;
        }
      }
      if (hSuffix) {
        var afterStart = idx + needle.length;
        var after = hay.slice(afterStart, afterStart + hSuffix.length);
        if (after && hSuffix.slice(0, after.length) === after) {
          score -= CONTEXT_BONUS;
        }
      }
      if (score < bestScore) {
        bestScore = score;
        best = idx;
      }
      idx = hay.indexOf(needle, idx + 1);
    }
    if (best === -1) return null;
    return {
      start: normMap[best],
      end: normMap[best + needle.length - 1] + 1,
    };
  }

  function resolveBookmarks() {
    resolvedBookmarks = [];
    for (var i = 0; i < appliedBookmarks.length; i++) {
      var resolved = resolveHighlight(appliedBookmarks[i]);
      if (resolved) {
        resolvedBookmarks.push({ id: appliedBookmarks[i].id, start: resolved.start });
      }
    }
  }

  function renderHighlights() {
    var root = ensureOverlayRoot();
    while (root.firstChild) root.removeChild(root.firstChild);
    resolveBookmarks();
    highlightHitRects = [];
    selectedHighlightRange = null;
    resizeHandleEls = null;
    // First and last rendered rect of the selected highlight (viewport coords),
    // where the drag handles get anchored after the fill divs are drawn.
    var selectedFirstRect = null;
    var selectedLastRect = null;

    for (var i = 0; i < appliedHighlights.length; i++) {
      var h = appliedHighlights[i];
      var resolved =
        resizePreview && resizePreview.id === h.id
          ? { start: resizePreview.start, end: resizePreview.end }
          : resolveHighlight(h);
      if (!resolved) continue;
      var range = rangeFromRaw(resolved.start, resolved.end);
      if (!range) continue;
      var isSelected = h.id === selectedHighlightId;
      if (isSelected) selectedHighlightRange = { start: resolved.start, end: resolved.end };
      var rects = range.getClientRects();
      for (var r = 0; r < rects.length; r++) {
        var rect = rects[r];
        if (rect.width < 1 || rect.height < 1) continue;
        highlightHitRects.push({
          id: h.id,
          left: rect.left + window.scrollX,
          top: rect.top + window.scrollY,
          width: rect.width,
          height: rect.height,
        });
        if (isSelected) {
          if (!selectedFirstRect) selectedFirstRect = rect;
          selectedLastRect = rect;
        }
        root.appendChild(makeFillDiv(h.id, h.color, rect));
      }
    }

    // Draggable blue end bars on the selected highlight (matches the PDF viewer).
    // Kept as persistent nodes so a drag repositions them in place rather than
    // rebuilding (see drawResizePreview).
    if (selectedHighlightRange && selectedFirstRect && selectedLastRect) {
      var startHandle = makeResizeHandle("start", selectedFirstRect);
      var endHandle = makeResizeHandle("end", selectedLastRect);
      root.appendChild(startHandle);
      root.appendChild(endHandle);
      resizeHandleEls = { start: startHandle, end: endHandle };
    }

    // Sticky-note markers: a small clickable badge at the note's anchor. The
    // full note UI lives in the app-shell sidebar; clicking a marker selects
    // the note there. Notes sharing an anchor fan out so none is buried.
    var seenAnchors = {};
    for (var ni = 0; ni < appliedNotes.length; ni++) {
      renderNoteMarker(root, appliedNotes[ni], seenAnchors);
    }
  }

  function renderNoteMarker(root, note, seenAnchors) {
    var resolved = resolveHighlight(note);
    if (!resolved) return;
    var anchorKey = String(resolved.start);
    var duplicateIndex = seenAnchors[anchorKey] || 0;
    seenAnchors[anchorKey] = duplicateIndex + 1;
    var range = rangeFromRaw(resolved.start, Math.min(resolved.start + 1, resolved.end));
    if (!range) return;
    var rect = range.getBoundingClientRect();
    if (!isFinite(rect.top) || (rect.width === 0 && rect.height === 0 && rect.top === 0)) {
      return;
    }

    var marker = document.createElement("div");
    marker.setAttribute("data-vellum-note", note.id);
    marker.style.cssText =
      "position:absolute;pointer-events:auto;cursor:pointer;width:18px;height:18px;" +
      "border-radius:4px 4px 4px 1px;background:#fbbf24;border:1px solid #b4530999;" +
      "box-shadow:0 1px 3px rgba(0,0,0,0.25);display:flex;align-items:center;" +
      "justify-content:center;font-size:11px;line-height:1;user-select:none;";
    marker.textContent = "✎"; // pencil
    // Sit in the margin just left of the anchored text when there's room;
    // when the text touches the edge, float just above the line instead of
    // covering the words. Duplicate anchors fan out downward.
    var left = rect.left + window.scrollX - 24;
    var top = rect.top + window.scrollY + Math.max(0, (rect.height - 18) / 2);
    if (left < 2) {
      left = Math.max(2, rect.left + window.scrollX - 2);
      top = rect.top + window.scrollY - 20;
      if (top < 2) top = rect.top + window.scrollY + rect.height + 2;
    }
    top += duplicateIndex * 22;
    marker.style.left = left + "px";
    marker.style.top = top + "px";
    if (note.content) {
      marker.title = String(note.content).slice(0, 200);
    }
    marker.addEventListener("mousedown", function (e) {
      e.preventDefault();
      e.stopPropagation();
    });
    marker.addEventListener("click", function (e) {
      e.preventDefault();
      e.stopPropagation();
      // Viewport coords of the marker so the app shell can anchor the note
      // viewer popover next to it.
      var box = marker.getBoundingClientRect();
      post("annotation-click", {
        id: note.id,
        x: box.left + box.width / 2,
        y: box.top,
      });
    });
    root.appendChild(marker);
  }

  // ------------------------------------------------------------------
  // Highlight edge resize (drag the blue end bars)
  // ------------------------------------------------------------------

  var RESIZE_COLOR = "#2563eb"; // blue-600, matches the PDF viewer handles
  var RESIZE_BAR_W = 3;
  var RESIZE_KNOB = 11;
  var RESIZE_PAD = 10; // extra hit slop around the knob
  // The two live handle elements while a highlight is selected. Persisting them
  // lets a drag reposition the handles in place (layoutResizeHandle) instead of
  // recreating them every frame — recreating the grabbed handle mid-drag is
  // what made WebKit lose its mousedown anchor and select the whole page.
  var resizeHandleEls = null; // { start, end }

  function makeFillDiv(id, color, rect) {
    var div = document.createElement("div");
    div.setAttribute("data-vellum-id", id);
    div.style.cssText =
      "position:absolute;pointer-events:none;border-radius:2px;" +
      "mix-blend-mode:multiply;opacity:0.55;";
    div.style.left = rect.left + window.scrollX + "px";
    div.style.top = rect.top + window.scrollY + "px";
    div.style.width = rect.width + "px";
    div.style.height = rect.height + "px";
    try {
      div.style.backgroundColor = color || "#fef08a";
    } catch (err) {
      div.style.backgroundColor = "#fef08a";
    }
    return div;
  }

  // Position an existing handle (outer + its ._bar / ._knob children) onto
  // `rect` — the highlight's first (start) or last (end) client rect in viewport
  // coordinates. The handle is placed in document coordinates so it tracks the
  // page as it scrolls. The handle's high z-index keeps it above the fill divs
  // regardless of DOM order, so a drag never has to re-append it.
  function layoutResizeHandle(outer, edge, rect) {
    var outerW = RESIZE_KNOB + RESIZE_PAD;
    var outerH = rect.height + RESIZE_KNOB + RESIZE_PAD;
    var barCenterX = (edge === "start" ? rect.left : rect.right) + window.scrollX;
    var docTop = rect.top + window.scrollY;
    outer.style.left = barCenterX - outerW / 2 + "px";
    outer.style.top = docTop - RESIZE_PAD / 2 - RESIZE_KNOB / 2 + "px";
    outer.style.width = outerW + "px";
    outer.style.height = outerH + "px";

    var barTop = (outerH - rect.height) / 2;
    var bar = outer._bar;
    bar.style.left = (outerW - RESIZE_BAR_W) / 2 + "px";
    bar.style.top = barTop + "px";
    bar.style.width = RESIZE_BAR_W + "px";
    bar.style.height = Math.max(rect.height, RESIZE_KNOB) + "px";

    var knob = outer._knob;
    knob.style.left = (outerW - RESIZE_KNOB) / 2 + "px";
    // Knob at the outer end: top for the start bar, bottom for the end bar.
    knob.style.top =
      (edge === "start" ? barTop : barTop + rect.height) - RESIZE_KNOB / 2 + "px";
    knob.style.width = RESIZE_KNOB + "px";
    knob.style.height = RESIZE_KNOB + "px";
  }

  // A vertical blue bar with a round knob sitting on one edge of the selected
  // highlight.
  function makeResizeHandle(edge, rect) {
    var outer = document.createElement("div");
    outer.setAttribute("data-vellum-resize", edge);
    outer.style.cssText =
      "position:absolute;pointer-events:auto;cursor:grab;z-index:2147483647;";

    var bar = document.createElement("div");
    bar.style.cssText =
      "position:absolute;border-radius:2px;background:" + RESIZE_COLOR + ";";
    outer.appendChild(bar);
    outer._bar = bar;

    var knob = document.createElement("div");
    knob.style.cssText =
      "position:absolute;border-radius:50%;box-sizing:border-box;background:" +
      RESIZE_COLOR + ";border:1.5px solid #fff;";
    outer.appendChild(knob);
    outer._knob = knob;

    layoutResizeHandle(outer, edge, rect);

    outer.addEventListener("mousedown", function (e) {
      e.preventDefault();
      e.stopPropagation();
      beginResize(edge);
    });
    return outer;
  }

  // Per-frame update during a drag: redraw ONLY the selected highlight's fill
  // from the preview offsets and reposition the two handles, leaving every
  // other overlay element — and, crucially, the grabbed handle's DOM node —
  // untouched. This is the whole reason the drag no longer triggers a native
  // page selection.
  function drawResizePreview() {
    if (!resizeState || !resizePreview) return;
    var root = ensureOverlayRoot();
    var id = resizeState.id;

    var stale = [];
    for (var c = 0; c < root.children.length; c++) {
      var child = root.children[c];
      if (child.getAttribute && child.getAttribute("data-vellum-id") === id) {
        stale.push(child);
      }
    }
    for (var s = 0; s < stale.length; s++) root.removeChild(stale[s]);

    var range = rangeFromRaw(resizePreview.start, resizePreview.end);
    if (!range) return;
    var color = null;
    for (var i = 0; i < appliedHighlights.length; i++) {
      if (appliedHighlights[i].id === id) {
        color = appliedHighlights[i].color;
        break;
      }
    }
    var rects = range.getClientRects();
    var firstRect = null;
    var lastRect = null;
    for (var r = 0; r < rects.length; r++) {
      var rect = rects[r];
      if (rect.width < 1 || rect.height < 1) continue;
      if (!firstRect) firstRect = rect;
      lastRect = rect;
      root.appendChild(makeFillDiv(id, color, rect));
    }
    if (firstRect && lastRect) {
      selectedHighlightRange = { start: resizePreview.start, end: resizePreview.end };
      if (resizeHandleEls && resizeHandleEls.start && resizeHandleEls.end) {
        layoutResizeHandle(resizeHandleEls.start, "start", firstRect);
        layoutResizeHandle(resizeHandleEls.end, "end", lastRect);
      }
    }
  }

  // Preventing a native text selection during the drag uses THREE guards, the
  // first of which is decisive and mechanism-independent:
  //  1. A full-viewport DRAG SHIELD: a transparent fixed div covering the whole
  //     page while the drag is live. WebKit cannot select text the cursor never
  //     touches, so this defeats the selection no matter HOW it would otherwise
  //     start — including the "anchor-loss" case where the grabbed handle's
  //     mousedown (which we preventDefault) is torn out from under WebKit and it
  //     begins a fresh selection that a cancellable `selectstart` never fires
  //     for. The one catch: `caretRangeFromPoint` (how we map the drag point to
  //     a text offset) also respects the shield, so onResizeMove flips the
  //     shield to pointer-events:none for that single synchronous hit-test and
  //     back — no real event can slip through in the gap.
  //  2. `selectstart`/`dragstart` cancellation: aborts a normal user-selection
  //     the instant it tries to form (and blocks native image/text drag-drop).
  //  3. `user-select:none` + grabbing cursor page-wide: extra insurance and the
  //     visual affordance.
  function onResizeSelectStart(e) {
    e.preventDefault();
  }
  var resizeLockStyle = null;
  var resizeShield = null;
  function setResizeLock(on) {
    if (on) {
      if (!resizeShield) {
        resizeShield = document.createElement("div");
        resizeShield.id = "__vellum-resize-shield";
        resizeShield.setAttribute("aria-hidden", "true");
        resizeShield.style.cssText =
          "position:fixed;left:0;top:0;width:100vw;height:100vh;" +
          "z-index:2147483647;background:transparent;cursor:grabbing;";
        (document.body || document.documentElement).appendChild(resizeShield);
      }
      document.addEventListener("selectstart", onResizeSelectStart, true);
      document.addEventListener("dragstart", onResizeSelectStart, true);
      if (!resizeLockStyle) {
        resizeLockStyle = document.createElement("style");
        resizeLockStyle.id = "__vellum-resize-lock";
        // The overlay rule matters as much as the user-select one: the grabbed
        // handle (and any note marker) is pointer-events:auto and sits directly
        // under the cursor, so caretRangeFromPoint would hit IT instead of the
        // text below. That boundary lives in the overlay root at the END of
        // documentElement, which rawOffsetOfBoundary maps to rawText.length —
        // snapping the dragged edge to the end of the document (the "resize
        // selects the whole page" bug). Move/up are captured on document, so
        // the handles need no events while the drag is live.
        resizeLockStyle.textContent =
          "*{-webkit-user-select:none!important;user-select:none!important;" +
          "cursor:grabbing!important;}" +
          "#__vellum-highlights *{pointer-events:none!important;}";
        (document.head || document.documentElement).appendChild(resizeLockStyle);
      }
      var sel = window.getSelection();
      if (sel && !sel.isCollapsed) sel.removeAllRanges();
    } else {
      if (resizeShield) {
        if (resizeShield.parentNode) resizeShield.parentNode.removeChild(resizeShield);
        resizeShield = null;
      }
      document.removeEventListener("selectstart", onResizeSelectStart, true);
      document.removeEventListener("dragstart", onResizeSelectStart, true);
      if (resizeLockStyle) {
        if (resizeLockStyle.parentNode) {
          resizeLockStyle.parentNode.removeChild(resizeLockStyle);
        }
        resizeLockStyle = null;
      }
    }
  }

  // The knobs are small and the highlight fill divs are pointer-events:none, so
  // a mousedown that misses the knob lands on the page text underneath and
  // starts a normal drag-selection ("finicky... it selects the whole page").
  // Fix: while a highlight is selected, ANY mousedown on it (or within a margin
  // of its handles) begins a resize of the nearest edge instead — no text
  // selection can start. Capture phase + stopPropagation so it also pre-empts
  // the per-handle listener (no double beginResize) and the link/click paths.
  function onSelectedHighlightMouseDown(e) {
    if (selectedHighlightId === null || resizing || noteMode || e.button !== 0) return;
    var rects = [];
    for (var i = 0; i < highlightHitRects.length; i++) {
      if (highlightHitRects[i].id === selectedHighlightId) rects.push(highlightHitRects[i]);
    }
    if (rects.length === 0) return;
    var docX = e.clientX + window.scrollX;
    var docY = e.clientY + window.scrollY;
    var margin = RESIZE_KNOB + RESIZE_PAD; // cover the knob/hit-slop past the text edges
    var inside = false;
    for (var r = 0; r < rects.length; r++) {
      var rc = rects[r];
      if (
        docX >= rc.left - margin && docX <= rc.left + rc.width + margin &&
        docY >= rc.top - margin && docY <= rc.top + rc.height + margin
      ) { inside = true; break; }
    }
    if (!inside) return;
    // Nearest edge: distance to the start (left of first rect) vs the end
    // (right of last rect).
    var first = rects[0], last = rects[rects.length - 1];
    var dStart = Math.hypot(docX - first.left, docY - (first.top + first.height / 2));
    var dEnd = Math.hypot(docX - (last.left + last.width), docY - (last.top + last.height / 2));
    e.preventDefault();
    e.stopPropagation();
    beginResize(dStart <= dEnd ? "start" : "end");
  }

  function beginResize(edge) {
    if (!selectedHighlightRange || selectedHighlightId === null) return;
    resizing = true;
    resizeState = {
      id: selectedHighlightId,
      edge: edge,
      start: selectedHighlightRange.start,
      end: selectedHighlightRange.end,
      anchorOffset: edge === "start" ? selectedHighlightRange.end : selectedHighlightRange.start,
    };
    setResizeLock(true);
    document.addEventListener("mousemove", onResizeMove, true);
    document.addEventListener("mouseup", onResizeUp, true);
  }

  function onResizeMove(e) {
    if (!resizeState) return;
    e.preventDefault();
    // Belt-and-suspenders: drop any selection the browser managed to start
    // before the guards took hold.
    var liveSel = window.getSelection();
    if (liveSel && !liveSel.isCollapsed) liveSel.removeAllRanges();
    // The shield sits over the text, so drop it to pointer-events:none for the
    // single synchronous caret hit-test, then restore it. Nothing can select in
    // this gap because no event is dispatched during a synchronous call.
    if (resizeShield) resizeShield.style.pointerEvents = "none";
    var caret = rawOffsetAtPoint(e.clientX, e.clientY);
    if (resizeShield) resizeShield.style.pointerEvents = "auto";
    if (caret === null) return; // over a gap/chrome: hold the last frame
    // Plausibility guard: hit-testing in empty regions (page margins, space
    // past the last paragraph, footer/header gaps) snaps the caret to a
    // document-boundary position whole screens away from the pointer — most
    // dangerously rawText.length, which yanks the dragged edge to the end of
    // the page in one frame. Require the caret's rendered line to be near the
    // pointer's y; otherwise hold the last frame like a missed hit-test.
    // Probe the nearest rendered (non-space) character — a caret on collapsed
    // whitespace (line breaks, the document's trailing whitespace nodes) has
    // no box of its own to measure.
    var probeAt = Math.min(caret, rawText.length - 1);
    while (probeAt > 0 && isSpaceCode(rawText.charCodeAt(probeAt))) probeAt--;
    var caretProbe = rangeFromRaw(probeAt, probeAt + 1);
    if (caretProbe) {
      var caretRect = caretProbe.getBoundingClientRect();
      if (isFinite(caretRect.top) && (caretRect.width > 0 || caretRect.height > 0)) {
        var dy = 0;
        if (e.clientY < caretRect.top) dy = caretRect.top - e.clientY;
        else if (e.clientY > caretRect.bottom) dy = e.clientY - caretRect.bottom;
        if (dy > 80) return;
      }
    }
    var start = resizeState.start;
    var end = resizeState.end;
    if (resizeState.edge === "start") {
      // Dragged edge never crosses (or touches) the pinned end.
      start = Math.max(0, Math.min(caret, resizeState.anchorOffset - 1));
      end = resizeState.anchorOffset;
    } else {
      start = resizeState.anchorOffset;
      end = Math.min(rawText.length, Math.max(caret, resizeState.anchorOffset + 1));
    }
    if (start === resizeState.start && end === resizeState.end) return;
    resizeState.start = start;
    resizeState.end = end;
    resizePreview = { id: resizeState.id, start: start, end: end };
    drawResizePreview();
  }

  function onResizeUp() {
    document.removeEventListener("mousemove", onResizeMove, true);
    document.removeEventListener("mouseup", onResizeUp, true);
    setResizeLock(false);
    var state = resizeState;
    resizeState = null;
    resizePreview = null;
    // Let the trailing mouseup->reportSelection and click handlers see that a
    // resize just finished, then release the flag.
    setTimeout(function () {
      resizing = false;
    }, 60);
    if (!state) return;
    var start = state.start;
    var end = state.end;
    var text = collapseWs(rawText.slice(start, end)).trim();
    // Collapsed range OR whitespace-only quote: bail like a no-op drag. An
    // empty selectedText would be dropped by the app shell's hasQuote filter
    // on the next apply-annotations round-trip, silently deleting the
    // highlight.
    if (end <= start || text.length === 0) {
      renderHighlights();
      return;
    }
    var ctx = quoteContext(start, end);
    // Update the local record so the highlight stays at the new size until the
    // app shell's apply-annotations round-trip lands (avoids a flicker back).
    for (var i = 0; i < appliedHighlights.length; i++) {
      if (appliedHighlights[i].id === state.id) {
        appliedHighlights[i].start = start;
        appliedHighlights[i].end = end;
        appliedHighlights[i].text = text;
        appliedHighlights[i].prefix = ctx.prefix;
        appliedHighlights[i].suffix = ctx.suffix;
        break;
      }
    }
    renderHighlights();
    post("highlight-resized", {
      id: state.id,
      start: start,
      end: end,
      text: text,
      prefix: ctx.prefix,
      suffix: ctx.suffix,
      pageNumber: pageForRaw(start),
    });
  }

  // ------------------------------------------------------------------
  // Find bar (⌘F) — separate overlay layer, whitespace-collapsed matching
  // ------------------------------------------------------------------

  function ensureFindRoot() {
    if (findRoot && findRoot.isConnected) return findRoot;
    findRoot = document.createElement("div");
    findRoot.id = "__vellum-find";
    findRoot.setAttribute("aria-hidden", "true");
    findRoot.style.cssText =
      "position:absolute;left:0;top:0;width:0;height:0;overflow:visible;" +
      "pointer-events:none;z-index:2147483647;";
    (document.documentElement || document.body).appendChild(findRoot);
    return findRoot;
  }

  function findAll(query) {
    findMatches = [];
    findIndex = -1;
    var q = collapseWs(query || "").trim();
    if (!q) return;
    var pair = searchPair(q);
    var hay = pair.hay;
    var needle = pair.needle;
    if (!needle) return;
    var idx = hay.indexOf(needle);
    while (idx !== -1 && findMatches.length < 5000) {
      findMatches.push({
        start: normMap[idx],
        end: normMap[idx + needle.length - 1] + 1,
      });
      idx = hay.indexOf(needle, idx + needle.length);
    }
    if (findMatches.length > 0) findIndex = 0;
  }

  function renderFind() {
    var root = ensureFindRoot();
    while (root.firstChild) root.removeChild(root.firstChild);
    for (var i = 0; i < findMatches.length; i++) {
      var range = rangeFromRaw(findMatches[i].start, findMatches[i].end);
      if (!range) continue;
      var rects = range.getClientRects();
      var current = i === findIndex;
      for (var r = 0; r < rects.length; r++) {
        var rect = rects[r];
        if (rect.width < 1 || rect.height < 1) continue;
        var div = document.createElement("div");
        div.style.cssText =
          "position:absolute;pointer-events:none;border-radius:2px;" +
          "mix-blend-mode:multiply;";
        div.style.left = rect.left + window.scrollX + "px";
        div.style.top = rect.top + window.scrollY + "px";
        div.style.width = rect.width + "px";
        div.style.height = rect.height + "px";
        div.style.backgroundColor = current ? "#fb923c" : "#fde047";
        root.appendChild(div);
      }
    }
  }

  function scrollFindIntoView() {
    if (findIndex < 0 || findIndex >= findMatches.length) return;
    var m = findMatches[findIndex];
    var range = rangeFromRaw(m.start, m.end);
    if (!range) return;
    var rect = range.getBoundingClientRect();
    if (rect.top < 60 || rect.bottom > window.innerHeight - 20) {
      window.scrollTo({
        top: Math.max(0, rect.top + window.scrollY - window.innerHeight * 0.3),
        behavior: "auto",
      });
    }
  }

  function reportFind() {
    post("find-result", {
      count: findMatches.length,
      current: findMatches.length > 0 ? findIndex + 1 : 0,
    });
  }

  function clearFind() {
    findMatches = [];
    findIndex = -1;
    if (findRoot) {
      while (findRoot.firstChild) findRoot.removeChild(findRoot.firstChild);
    }
  }

  var relayout = debounce(function () {
    pageTops = null;
    renderHighlights();
    if (findMatches.length > 0) renderFind();
    reportScroll(true);
  }, 250);

  // ------------------------------------------------------------------
  // Virtual page positions & scroll reporting
  // ------------------------------------------------------------------

  function computePageTops() {
    pageTops = [];
    for (var i = 0; i < pages.length; i++) {
      var p = pages[i];
      var range = rangeFromRaw(p.start, Math.min(p.start + 1, p.end || p.start + 1));
      var top = 0;
      if (range) {
        var rect = range.getBoundingClientRect();
        top = rect.top + window.scrollY;
      }
      // Keep tops monotonically increasing so lookup is well-defined.
      if (i > 0 && top < pageTops[i - 1]) top = pageTops[i - 1];
      pageTops.push(top);
    }
  }

  var lastReported = { current: 0, visible: "", bookmarks: "" };

  function reportScroll(force) {
    if (pages.length === 0) return;
    if (!pageTops) computePageTops();
    var viewTop = window.scrollY;
    var viewBottom = viewTop + window.innerHeight;
    var anchor = viewTop + window.innerHeight * 0.35;

    var current = 1;
    var visible = [];
    for (var i = 0; i < pages.length; i++) {
      var top = pageTops[i];
      var bottom = i + 1 < pageTops.length ? pageTops[i + 1] : Infinity;
      if (top <= anchor) current = pages[i].number;
      if (top < viewBottom && bottom > viewTop) visible.push(pages[i].number);
    }
    if (visible.length === 0) visible = [current];

    // Point bookmarks actually on screen right now: check each re-anchored
    // bookmark's rendered position against the viewport. This is precise to
    // the visible text (a virtual-page span would light the toolbar star for
    // an entire ~3600-char page — or the whole document on short articles).
    var visibleBookmarks = [];
    for (var bi = 0; bi < resolvedBookmarks.length; bi++) {
      var bookmarkRange = rangeFromRaw(
        resolvedBookmarks[bi].start,
        resolvedBookmarks[bi].start + 1
      );
      if (!bookmarkRange) continue;
      var bookmarkRect = bookmarkRange.getBoundingClientRect();
      if (bookmarkRect.bottom > 0 && bookmarkRect.top < window.innerHeight) {
        visibleBookmarks.push(resolvedBookmarks[bi].id);
      }
    }
    var bookmarksKey = visibleBookmarks.join(",");

    var visibleKey = visible.join(",");
    if (
      !force &&
      current === lastReported.current &&
      visibleKey === lastReported.visible &&
      bookmarksKey === lastReported.bookmarks
    ) {
      return;
    }
    lastReported = { current: current, visible: visibleKey, bookmarks: bookmarksKey };
    // Raw-offset span of the visible virtual pages (legacy fallback for the
    // app shell when visibleBookmarks is absent).
    var firstPage = pages[visible[0] - 1];
    var lastPage = pages[visible[visible.length - 1] - 1];
    post("scroll", {
      currentPage: current,
      visiblePages: visible,
      visibleStart: firstPage ? firstPage.start : 0,
      visibleEnd: lastPage ? lastPage.end : 0,
      visibleBookmarks: visibleBookmarks,
    });
  }

  var scrollTicking = false;
  function onScroll() {
    if (scrollTicking) return;
    scrollTicking = true;
    requestAnimationFrame(function () {
      scrollTicking = false;
      // Unconditional (reportScroll dedupes): the app shell hides the
      // selection popover, whose position is viewport-anchored.
      post("viewport-scrolled");
      reportScroll(false);
    });
  }

  function scrollToVirtualPage(pageNumber) {
    if (!pageTops) computePageTops();
    var idx = Math.max(1, Math.min(pages.length, pageNumber)) - 1;
    window.scrollTo({ top: Math.max(0, pageTops[idx] - 12), behavior: "auto" });
  }

  // ------------------------------------------------------------------
  // Selection reporting
  // ------------------------------------------------------------------

  function reportSelection() {
    // A handle drag ends in a mouseup too; don't let it clear the selection or
    // dismiss the highlight's edit popover.
    if (resizing) return;
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
      post("selection-cleared");
      return;
    }
    var text = sel.toString().replace(/\s+/g, " ").trim();
    if (!text) {
      post("selection-cleared");
      return;
    }
    var range = sel.getRangeAt(0);
    var rects = range.getClientRects();
    if (rects.length === 0) return;

    var start = rawOffsetOfBoundary(range.startContainer, range.startOffset);
    var end = rawOffsetOfBoundary(range.endContainer, range.endOffset);
    if (start === null || end === null || end <= start) return;

    var mapped = [];
    for (var i = 0; i < rects.length && i < 60; i++) {
      mapped.push({
        x: rects[i].left,
        y: rects[i].top,
        width: rects[i].width,
        height: rects[i].height,
      });
    }

    var ctx = quoteContext(start, end);
    post("selection", {
      text: text,
      start: start,
      end: end,
      pageNumber: pageForRaw(start),
      rects: mapped,
      prefix: ctx.prefix,
      suffix: ctx.suffix,
    });
  }

  document.addEventListener("mouseup", function () {
    setTimeout(reportSelection, 30);
  });

  document.addEventListener(
    "selectionchange",
    debounce(function () {
      var sel = window.getSelection();
      if (!sel || sel.isCollapsed) post("selection-cleared");
    }, 200)
  );

  // ------------------------------------------------------------------
  // Sticky-note placement (note mode click / right-click menu): anchor a
  // note to the text under the pointer
  // ------------------------------------------------------------------

  // Text-quote anchor for the caret at/near a viewport point, or null when
  // no anchorable text is nearby. Probes around the point so clicks in gaps
  // (image margins, padding) still anchor.
  function noteAnchorAtPoint(clientX, clientY) {
    if (rawText.length === 0) return null;
    var offset = null;
    var probes = [
      [clientX, clientY],
      [clientX - 40, clientY],
      [clientX + 40, clientY],
      [clientX, clientY - 20],
      [clientX, clientY + 20],
    ];
    for (var i = 0; i < probes.length && offset === null; i++) {
      offset = rawOffsetAtPoint(probes[i][0], probes[i][1]);
    }
    if (offset === null) return null;

    var start = Math.max(0, Math.min(offset, rawText.length - 1));
    while (start < rawText.length && isSpaceCode(rawText.charCodeAt(start))) start++;
    if (start >= rawText.length) start = Math.max(0, rawText.length - 1);
    // Snap back to the start of the word so the anchored quote doesn't begin
    // mid-word ("ent on a hike..." instead of "went on a hike...").
    while (start > 0 && !isSpaceCode(rawText.charCodeAt(start - 1))) start--;
    var end = Math.min(rawText.length, start + 80);
    // Finish the trailing word too (capped) so the quote ends cleanly.
    var endCap = Math.min(rawText.length, start + 100);
    while (end < endCap && !isSpaceCode(rawText.charCodeAt(end))) end++;
    var snippet = collapseWs(rawText.slice(start, end)).trim();
    if (!snippet) return null;

    var ctx = quoteContext(start, end);
    return {
      start: start,
      end: end,
      text: snippet,
      prefix: ctx.prefix,
      suffix: ctx.suffix,
      pageNumber: pageForRaw(start),
    };
  }

  document.addEventListener(
    "click",
    function (e) {
      if (!noteMode) return;
      e.preventDefault();
      e.stopImmediatePropagation();

      var anchor = noteAnchorAtPoint(e.clientX, e.clientY);
      if (!anchor) return; // stay in note mode
      anchor.x = e.clientX;
      anchor.y = e.clientY;
      post("note-placed", anchor);
    },
    true
  );

  // ------------------------------------------------------------------
  // Highlight click → edit popover in the app shell
  // ------------------------------------------------------------------

  // Hit-test clicks against the rendered highlight rects (the overlay divs
  // are pointer-events:none, so this is the only click path). Registered
  // before the link interceptor so a highlighted link opens the edit popover
  // instead of navigating. A drag-selection also ends in a click, so a
  // non-collapsed selection means "leave it to the selection popover".
  document.addEventListener(
    "click",
    function (e) {
      if (e.defaultPrevented) return;
      if (noteMode) return;
      var sel = window.getSelection();
      if (sel && !sel.isCollapsed) return;
      // Note markers (inside the overlay root) handle their own clicks.
      if (overlayRoot && e.target && overlayRoot.contains(e.target)) return;
      var docX = e.clientX + window.scrollX;
      var docY = e.clientY + window.scrollY;
      var hit = null;
      // Backwards: the last-rendered (topmost) of overlapping highlights wins.
      for (var i = highlightHitRects.length - 1; i >= 0 && !hit; i--) {
        var r = highlightHitRects[i];
        if (
          docX >= r.left &&
          docX <= r.left + r.width &&
          docY >= r.top &&
          docY <= r.top + r.height
        ) {
          hit = r;
        }
      }
      if (!hit) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      // Viewport coords of the clicked rect so the app shell can anchor the
      // popover above it (the highlight's first rect may be off screen).
      post("annotation-click", {
        id: hit.id,
        x: hit.left - window.scrollX + hit.width / 2,
        y: hit.top - window.scrollY,
      });
    },
    true
  );

  // Right-click: replace the native menu with the app shell's context menu
  // (mirrors the PDF viewer's "Add note here").
  document.addEventListener(
    "contextmenu",
    function (e) {
      var anchor = noteAnchorAtPoint(e.clientX, e.clientY);
      e.preventDefault();
      var payload = { x: e.clientX, y: e.clientY, found: !!anchor };
      if (anchor) {
        for (var k in anchor) payload[k] = anchor[k];
        payload.x = e.clientX;
        payload.y = e.clientY;
      }
      post("context-menu", payload);
    },
    true
  );

  // ------------------------------------------------------------------
  // Link interception — keep navigation inside the reader
  // ------------------------------------------------------------------

  document.addEventListener(
    "click",
    function (e) {
      if (e.defaultPrevented) return;
      if (noteMode) return; // note placement owns clicks in note mode
      var target = e.target;
      if (!target || !target.closest) return;
      var link = target.closest("a[href]");
      if (!link) return;

      var rawHref = link.getAttribute("href") || "";
      if (rawHref.charAt(0) === "#") return; // same-document anchor

      // SVG <a> exposes href as SVGAnimatedString; without unwrapping it the
      // regex tests fail and the click would navigate the webview out of the
      // reader entirely.
      var href = link.href;
      if (href && typeof href === "object" && typeof href.baseVal === "string") {
        try {
          href = new URL(href.baseVal, document.baseURI).href;
        } catch (err) {
          href = "";
        }
      }
      if (/^https?:/i.test(href)) {
        e.preventDefault();
        e.stopPropagation();
        post("navigate", { url: href });
      } else if (/^(mailto|tel):/i.test(href)) {
        e.preventDefault();
      }
    },
    true
  );

  // GET form submissions (e.g. site search) become reader navigations.
  document.addEventListener(
    "submit",
    function (e) {
      var form = e.target;
      if (!form || !form.action) return;
      var method = (form.method || "get").toLowerCase();
      if (method !== "get") return;
      if (!/^https?:/i.test(form.action)) return;
      e.preventDefault();
      try {
        var url = new URL(form.action);
        var data = new FormData(form);
        data.forEach(function (value, key) {
          if (typeof value === "string") url.searchParams.append(key, value);
        });
        post("navigate", { url: url.toString() });
      } catch (err) {
        /* leave as-is */
      }
    },
    true
  );

  // window.open is overridden by the page-world bootstrap (only the page's
  // own world can replace the binding page scripts call); it publishes the
  // target on the shared <html> element and pings this event. Routing the
  // URL through the reader here grants the page nothing it can't already do
  // with location.assign.
  document.addEventListener("__vellum-open-url", function () {
    var u = document.documentElement.getAttribute("data-vellum-open-url");
    if (u && /^https?:/i.test(u)) post("navigate", { url: u });
  });

  // ------------------------------------------------------------------
  // Commands from the app shell (invoked via evaluateJavaScript)
  // ------------------------------------------------------------------

  window.__vellumCmd = function (d) {
    if (!d || typeof d.vellumCmd !== "string") return;

    switch (d.vellumCmd) {
      case "scroll-to-page":
        scrollToVirtualPage(Number(d.page) || 1);
        break;

      case "apply-annotations":
        appliedHighlights = Array.isArray(d.highlights) ? d.highlights : [];
        appliedNotes = Array.isArray(d.notes) ? d.notes : [];
        appliedBookmarks = Array.isArray(d.bookmarks) ? d.bookmarks : [];
        renderHighlights();
        // Bookmark visibility may have changed with the new set.
        reportScroll(true);
        break;

      case "set-selected-highlight": {
        var nextId = d.id != null ? String(d.id) : null;
        if (nextId !== selectedHighlightId) {
          selectedHighlightId = nextId;
          if (nextId === null) {
            resizePreview = null;
            resizeState = null;
            resizing = false;
            setResizeLock(false);
          }
          renderHighlights();
        }
        break;
      }

      case "set-mode": {
        noteMode = d.mode === "note";
        try {
          // Custom "+" cursor (matches the PDF note tool): a bold plus with a
          // white halo so it reads on any background, hotspot at the crossing.
          var noteCursorSvg =
            "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'>" +
            "<line x1='12' y1='5' x2='12' y2='19' stroke='white' stroke-width='5' stroke-linecap='round'/>" +
            "<line x1='5' y1='12' x2='19' y2='12' stroke='white' stroke-width='5' stroke-linecap='round'/>" +
            "<line x1='12' y1='5' x2='12' y2='19' stroke='black' stroke-width='2.5' stroke-linecap='round'/>" +
            "<line x1='5' y1='12' x2='19' y2='12' stroke='black' stroke-width='2.5' stroke-linecap='round'/></svg>";
          var noteCursor =
            "url(\"data:image/svg+xml," + encodeURIComponent(noteCursorSvg) + "\") 12 12, crosshair";
          document.documentElement.style.cursor = noteMode ? noteCursor : "";
        } catch (err) {
          /* ignore */
        }
        break;
      }

      case "scroll-to-annotation": {
        var match = null;
        var annotationLists = [appliedHighlights, appliedNotes];
        for (var li = 0; li < annotationLists.length && !match; li++) {
          var list = annotationLists[li];
          for (var i = 0; i < list.length; i++) {
            if (list[i].id === d.id) {
              match = resolveHighlight(list[i]);
              break;
            }
          }
        }
        if (match) {
          var range = rangeFromRaw(match.start, match.end);
          if (range) {
            var rect = range.getBoundingClientRect();
            // Already fully on screen (e.g. selected by clicking it in the
            // page): scrolling would just yank the viewport — and dismiss
            // the popover the click opened.
            if (rect.top < 0 || rect.bottom > window.innerHeight) {
              window.scrollTo({
                top: Math.max(0, rect.top + window.scrollY - window.innerHeight * 0.3),
                behavior: "auto",
              });
            }
          }
        }
        break;
      }

      case "locate-text": {
        var found = null;
        var locateRaw = collapseWs(d.text || "").trim();
        if (locateRaw) {
          var locatePair = searchPair(locateRaw);
          var hay = locatePair.hay;
          var needle = locatePair.needle;
          var pageIdx = Math.max(1, Math.min(pages.length, Number(d.page) || 1)) - 1;
          var page = pages[pageIdx];
          var from = page ? page.normStart : 0;
          var idx = hay.indexOf(needle, from);
          if (idx === -1 || (page && idx >= page.normEnd)) idx = hay.indexOf(needle);
          if (idx !== -1) {
            found = {
              start: normMap[idx],
              end: normMap[idx + needle.length - 1] + 1,
            };
          }
        }
        var foundCtx = found ? quoteContext(found.start, found.end) : null;
        post("locate-result", {
          requestId: d.requestId,
          found: !!found,
          start: found ? found.start : null,
          end: found ? found.end : null,
          prefix: foundCtx ? foundCtx.prefix : null,
          suffix: foundCtx ? foundCtx.suffix : null,
          // The whole-document fallback may land on a different virtual page
          // than requested; report where the text actually is.
          pageNumber: found ? pageForRaw(found.start) : null,
        });
        break;
      }

      case "capture-position": {
        var anchor = captureViewportAnchor();
        post("position-result", {
          requestId: d.requestId,
          found: !!anchor,
          start: anchor ? anchor.start : null,
          end: anchor ? anchor.end : null,
          text: anchor ? anchor.text : null,
          prefix: anchor ? anchor.prefix : null,
          suffix: anchor ? anchor.suffix : null,
          offset: anchor ? anchor.offset : null,
          pageNumber: anchor ? anchor.pageNumber : null,
        });
        break;
      }

      case "scroll-to-position": {
        var posPayload = {
          start: typeof d.start === "number" ? d.start : null,
          end: typeof d.end === "number" ? d.end : null,
          text: typeof d.text === "string" ? d.text : "",
          prefix: typeof d.prefix === "string" ? d.prefix : null,
          suffix: typeof d.suffix === "string" ? d.suffix : null,
        };
        var anchorOffset = typeof d.offset === "number" ? d.offset : 16;

        var desiredTop = function () {
          var resolved = resolveHighlight(posPayload);
          var range = resolved ? rangeFromRaw(resolved.start, resolved.end) : null;
          if (!range) return null;
          return Math.max(0, range.getBoundingClientRect().top + window.scrollY - anchorOffset);
        };

        var firstTop = desiredTop();
        if (firstTop === null) {
          if (typeof d.page === "number") scrollToVirtualPage(d.page);
          break;
        }
        window.scrollTo({ top: firstTop, behavior: "auto" });
        // scrollTo clamps at the document end; remember where we landed.
        var expectedY = window.scrollY;

        // Late-loading content above the anchor (lazy images, ads) shifts
        // layout after the jump. Re-correct briefly, but back off as soon as
        // the user scrolls somewhere else themselves.
        var settle = function () {
          if (Math.abs(window.scrollY - expectedY) > 150) return;
          var top = desiredTop();
          if (top !== null && Math.abs(top - window.scrollY) > 24) {
            window.scrollTo({ top: top, behavior: "auto" });
            expectedY = window.scrollY;
          }
        };
        setTimeout(settle, 400);
        setTimeout(settle, 1200);
        break;
      }

      case "find": {
        findAll(d.query || "");
        renderFind();
        scrollFindIntoView();
        reportFind();
        break;
      }

      case "find-step": {
        if (findMatches.length > 0) {
          var delta = Number(d.delta) || 1;
          var n = findMatches.length;
          findIndex = ((findIndex + delta) % n + n) % n;
          renderFind();
          scrollFindIntoView();
        }
        reportFind();
        break;
      }

      case "find-clear":
        clearFind();
        break;

      case "clear-selection": {
        var sel = window.getSelection();
        if (sel) sel.removeAllRanges();
        break;
      }

      case "history":
        try {
          history.go(Number(d.delta) || 0);
        } catch (err) {
          /* ignore */
        }
        break;

      case "request-init":
        initialize(true);
        break;
    }
  };

  // ------------------------------------------------------------------
  // Init
  // ------------------------------------------------------------------

  function sendInit() {
    post("init", {
      url: PAGE_URL,
      title: document.title || null,
      offline: document.documentElement.getAttribute("data-vellum-offline") === "true",
      // Capability handshake: this script understands capture-position /
      // scroll-to-position. Lets the app shell degrade to page bookmarks
      // when an older embedded script is running.
      positionAnchors: true,
      pageCount: pages.length,
      pages: pages.map(function (p) {
        return { number: p.number, text: p.text };
      }),
    });
    reportScroll(true);
  }

  function initialize(force) {
    var previousLength = rawText.length;
    buildTextMap();
    buildPages();
    if (!initialized || force || Math.abs(rawText.length - previousLength) > previousLength * 0.15) {
      initialized = true;
      sendInit();
    }
    renderHighlights();
  }

  var started = false;

  function start() {
    if (started) return;
    started = true;
    initialize(true);
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", relayout);
    // Grab-anywhere-on-the-selected-highlight resize (see the function comment).
    document.addEventListener("mousedown", onSelectedHighlightMouseDown, true);

    // Back/forward can restore this page from WebKit's page cache, where
    // user scripts don't re-run: without a fresh init the shell keeps the
    // outgoing document bound and the address pill shows a stale URL. A
    // persisted pageshow is exactly that restore — re-report so handleInit's
    // rebind path fires.
    window.addEventListener("pageshow", function (e) {
      if (e.persisted) initialize(true);
    });
    if (window.ResizeObserver && document.body) {
      new ResizeObserver(relayout).observe(document.body);
    }
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(function () {
        relayout();
      });
    }

    // SPA re-renders detach the text nodes our entries point at, which would
    // silently kill highlights and freeze the text map. Re-extract (debounced)
    // on subtree mutations, ignoring our own overlay churn. Observing the
    // documentElement survives full <body> replacement.
    if (window.MutationObserver) {
      var remap = debounce(function () {
        initialize(false); // resends init only if the text changed >15%
        pageTops = null;
        renderHighlights();
        reportScroll(true);
      }, 600);
      // Our own transient drag chrome (the resize shield + user-select lock
      // style) is added/removed on document.body/head during a drag; those
      // mutations must not trigger a re-extract that rebuilds the handles
      // mid-drag.
      function isOwnResizeChrome(n) {
        return !!n && (n.id === "__vellum-resize-shield" || n.id === "__vellum-resize-lock");
      }
      function onlyOwnChrome(list) {
        if (!list || list.length === 0) return false;
        for (var k = 0; k < list.length; k++) {
          if (!isOwnResizeChrome(list[k])) return false;
        }
        return true;
      }
      new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
          var target = records[i].target;
          if (overlayRoot && (target === overlayRoot || overlayRoot.contains(target))) {
            continue;
          }
          if (findRoot && (target === findRoot || findRoot.contains(target))) {
            continue;
          }
          if (isOwnResizeChrome(target)) continue;
          // Pure shield/lock add or remove: not a page change.
          if (
            records[i].type === "childList" &&
            (onlyOwnChrome(records[i].addedNodes) || onlyOwnChrome(records[i].removedNodes))
          ) {
            continue;
          }
          remap();
          return;
        }
      }).observe(document.documentElement, {
        childList: true,
        subtree: true,
        characterData: true,
      });
    }

    // Late-rendering pages (client-side hydration): re-extract once settled.
    setTimeout(function () {
      initialize(false);
    }, 2000);
  }

  if (document.readyState === "complete") {
    start();
  } else {
    window.addEventListener("load", start);
    // Fall back in case load stalls on a slow subresource.
    setTimeout(start, 4000);
  }
})();
"""#

    /// Unprivileged page-world bootstrap, injected inline into the served
    /// HTML by `WebHtml.prepareHtml` (which prefixes the
    /// `window.__VELLUM_PAGE_URL__` / `window.__VELLUM_OFFLINE__` constants —
    /// only the scheme handler knows the redirect-followed URL and the
    /// offline flag at serve time). Runs in the page's own JS context — it
    /// must, because it wraps the page's history binding and window.open —
    /// but has no bridge access: it only publishes shared DOM attributes and
    /// dispatches DOM events the isolated-world content script listens for,
    /// none of which grant a page more than location.assign already does.
    static let pageWorldSource = #"""
(function () {
  "use strict";
  if (window.__vellumPageShimLoaded) return;
  window.__vellumPageShimLoaded = true;

  var PAGE_URL = window.__VELLUM_PAGE_URL__ || location.href;
  var root = document.documentElement;
  // Republish the per-page constants where the isolated world can see them.
  root.setAttribute("data-vellum-page-url", PAGE_URL);
  root.setAttribute("data-vellum-offline", window.__VELLUM_OFFLINE__ ? "true" : "false");

  // ------------------------------------------------------------------
  // History API shim (see plans/web-proxy-truthful-urls.html)
  //
  // The injected <base href> points at the real https origin so
  // subresources resolve — but it also makes RELATIVE
  // history.pushState/replaceState URLs resolve against it, which is
  // cross-origin to this vellum-web document, so WebKit throws a
  // SecurityError mid-hydration in SPA routers (Next.js does exactly
  // this). Resolve url arguments against location.href instead, and map
  // absolute real-origin URLs back onto the reader origin. The isolated
  // world is pinged afterwards so it can refresh its PAGE_URL.
  // ------------------------------------------------------------------
  var REAL_HOST = "";
  try {
    REAL_HOST = new URL(PAGE_URL).host;
  } catch (e) {
    /* PAGE_URL not absolute; remap degrades to absolute resolution */
  }

  function remapHistoryUrl(url) {
    if (url === undefined || url === null) return url;
    try {
      var abs = new URL(String(url), location.href);
      if ((abs.protocol === "http:" || abs.protocol === "https:") && abs.host === REAL_HOST) {
        return location.protocol + "//" + location.host + abs.pathname + abs.search + abs.hash;
      }
      return abs.href;
    } catch (e) {
      return url;
    }
  }

  function noteUrlChange() {
    try {
      document.dispatchEvent(new Event("__vellum-url-changed"));
    } catch (e) {
      /* ignore */
    }
  }

  var nativePushState = history.pushState.bind(history);
  var nativeReplaceState = history.replaceState.bind(history);
  history.pushState = function (state, title, url) {
    nativePushState(state, title, remapHistoryUrl(url));
    noteUrlChange();
  };
  history.replaceState = function (state, title, url) {
    nativeReplaceState(state, title, remapHistoryUrl(url));
    noteUrlChange();
  };

  // No popups in the reader: hand window.open targets to the isolated world
  // (via the shared DOM) so they become normal reader navigations.
  window.open = function (u) {
    try {
      var abs = new URL(u, PAGE_URL).toString();
      if (/^https?:/i.test(abs)) {
        root.setAttribute("data-vellum-open-url", abs);
        document.dispatchEvent(new Event("__vellum-open-url"));
      }
    } catch (err) {
      /* ignore */
    }
    return null;
  };
})();
"""#
}
