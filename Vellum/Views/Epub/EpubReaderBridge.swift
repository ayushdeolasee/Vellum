#if os(macOS) || os(iOS)
import Foundation

enum EpubReaderLayout: String, Codable, CaseIterable {
    case scroll
    case paged
}

struct EpubReaderSettings: Equatable, Codable {
    static let layoutKey = "epub.layout"

    var fontSize: Double
    var lineSpacing: Double
    var layout: EpubReaderLayout

    init(fontSize: Double = 18, lineSpacing: Double = 1.6, layout: EpubReaderLayout = .scroll) {
        self.fontSize = fontSize.isFinite ? min(36, max(12, fontSize)) : 18
        self.lineSpacing = lineSpacing.isFinite ? min(2.4, max(1.1, lineSpacing)) : 1.6
        self.layout = layout
    }

    static func load() -> Self {
        let defaults = AppDefaults.current
        return Self(fontSize: defaults.object(forKey: "epub.fontSize") as? Double ?? 18,
                    lineSpacing: defaults.object(forKey: "epub.lineSpacing") as? Double ?? 1.6,
                    layout: defaults.string(forKey: layoutKey).flatMap(EpubReaderLayout.init(rawValue:)) ?? .scroll)
    }

    func save() {
        let bounded = Self(fontSize: fontSize, lineSpacing: lineSpacing, layout: layout)
        let defaults = AppDefaults.current
        defaults.set(bounded.fontSize, forKey: "epub.fontSize")
        defaults.set(bounded.lineSpacing, forKey: "epub.lineSpacing")
        defaults.set(bounded.layout.rawValue, forKey: Self.layoutKey)
    }
}

/// A document-load nonce, not just an href: a delayed callback from an earlier
/// visit to the same chapter must not move the new viewport or selection.
struct EpubReaderMessage: Decodable {
    let type: String
    let token: String
    let href: String
    let value: Double?
    let anchor: EpubTextAnchor?
    let id: String?
    let unresolved: [String]?
    let page: Int?
    let pageCount: Int?
    let step: Int?

    init(type: String, token: String, href: String, value: Double?, anchor: EpubTextAnchor?,
         id: String?, unresolved: [String]?, page: Int? = nil, pageCount: Int? = nil, step: Int? = nil) {
        self.type = type; self.token = token; self.href = href; self.value = value
        self.anchor = anchor; self.id = id; self.unresolved = unresolved
        self.page = page; self.pageCount = pageCount; self.step = step
    }

    static func decode(_ body: Any, token: String, href: String, docId: String) -> Self? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64 * 1024,
              let message = try? JSONDecoder().decode(Self.self, from: data),
              message.token == token, message.href == href,
              ["progress", "selection", "annotation", "unresolved", "unresolvedLocation", "pencilHighlight", "edge"].contains(message.type),
              message.value.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              message.pageCount.map({ (1...100_000).contains($0) }) ?? true,
              message.id.map({ $0.utf16.count <= 256 }) ?? true,
              message.unresolved.map({ ids in
                  ids.count <= 1000 && ids.filter { !$0.hasPrefix("ink:") }.count <= 500
                      && ids.filter { $0.hasPrefix("ink:") }.count <= 500
                      && ids.allSatisfy { $0.utf16.count <= 256 }
              }) ?? true
        else { return nil }
        if let page = message.page {
            guard let pageCount = message.pageCount, page >= 0, page < pageCount else { return nil }
        } else if message.pageCount != nil { return nil }
        if message.type == "edge", message.step != -1 && message.step != 1 { return nil }
        if let anchor = message.anchor {
            guard anchor.chapterHref == href,
                  AiEpubCitation(docId: docId, chapterNumber: 1, chapterHref: href, anchor: anchor).bounded != nil
            else { return nil }
        }
        if message.type == "progress", message.value == nil { return nil }
        if message.type == "annotation", message.id == nil { return nil }
        if message.type == "pencilHighlight", message.anchor == nil { return nil }
        return message
    }
}

enum EpubReaderJavaScript {
    static func literal<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value), let literal = String(data: data, encoding: .utf8)
        else { return "null" }
        return literal
    }

    static let source = #"""
    (() => {
      if (window.__vellumEpub) return;
      const excluded = new Set(['head','script','style','template','noscript']);
      const blocks = new Set(['address','article','aside','blockquote','body','caption','dd','details','dialog',
        'div','dl','dt','fieldset','figcaption','figure','footer','form','h1','h2','h3','h4','h5','h6',
        'header','hgroup','hr','li','main','nav','ol','p','pre','section','summary','table','tbody',
        'td','tfoot','th','thead','tr','ul','br']);
      const whitespace = c => (c >= 9 && c <= 13) || c === 32 || c === 0x85 || c === 0xa0 ||
        c === 0x1680 || (c >= 0x2000 && c <= 0x200a) || [0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff].includes(c);
      let config = null, cache = null, viewport = null, timer = null, restoring = false;
      let annotations = [], overlay = null;
      const element = name => document.createElementNS('http://www.w3.org/1999/xhtml', name);
      const style = element('style');
      style.textContent = `html { -webkit-text-size-adjust:100%; background:var(--vellum-epub-well) !important;
          color:var(--vellum-epub-foreground) !important; }
        body { box-sizing:border-box; max-width:44em; min-height:100vh; margin:0 auto !important;
          padding:2.5em 2em 5em !important; background:var(--vellum-epub-surface) !important;
          color:var(--vellum-epub-foreground) !important; border:1px solid var(--vellum-epub-border);
          box-shadow:0 1px 8px rgb(0 0 0 / 10%); }
        a { color:var(--vellum-epub-primary) !important; }
        img,svg,video { max-width:100%; height:auto; } pre { white-space:pre-wrap; }
        html[data-vellum-dark] { color-scheme:dark; }
        html[data-vellum-paged] { height:100vh; box-sizing:border-box;
          padding:2.5em var(--vellum-page-margin) 3em; column-width:var(--vellum-page-width);
          column-gap:var(--vellum-page-gap); column-fill:auto; overflow:hidden;
          background:var(--vellum-epub-surface) !important; scroll-behavior:auto !important; }
        html[data-vellum-paged] body { box-sizing:border-box; max-width:none !important;
          min-height:0; margin:0 !important; padding:0 !important; border:0 !important;
          box-shadow:none !important; background:transparent !important; break-inside:auto; }
        html[data-vellum-paged] img,html[data-vellum-paged] svg,html[data-vellum-paged] video,
        html[data-vellum-paged] table,html[data-vellum-paged] pre {
          max-height:calc(100vh - 5.5em); break-inside:avoid; }
        html[data-vellum-paged] figure { max-height:calc(100vh - 5.5em); break-inside:avoid; }
        html[data-vellum-paged] pre { overflow:auto; }`;
      (document.head || document.documentElement).appendChild(style);
      const post = (type, extra = {}) => {
        if (!config || !config.active) return;
        window.webkit?.messageHandlers?.epubReader?.postMessage({type,token:config.token,href:config.href,...extra});
      };
      const boundary = (text, i) => i >= 0 && i <= text.length && !(i > 0 && i < text.length &&
        /[\uD800-\uDBFF]/.test(text[i-1]) && /[\uDC00-\uDFFF]/.test(text[i]));
      function index() {
        if (cache) return cache;
        let text = '', starts = [], ends = [], pending = false, count = 0;
        const separator = () => { if (text.length) pending = true; };
        function emit(char, node, offset) {
          if (text.length + char.length + (pending ? 1 : 0) > 2097152) throw Error('Chapter text limit');
          if (pending) {
            starts[text.length] = ends[text.length - 1]; ends[text.length] = [node,offset];
            text += ' '; pending = false;
          }
          starts[text.length] = [node,offset];
          ends[text.length + char.length - 1] = [node,offset + char.length]; text += char;
        }
        function walk(node, depth) {
          if (++count > 200000 || depth > 256) throw Error('Chapter structure limit');
          if (node.nodeType === Node.TEXT_NODE) {
            let offset = 0;
            for (const c of node.data) { if (whitespace(c.codePointAt(0))) separator(); else emit(c,node,offset); offset += c.length; }
          } else if (node.nodeType === Node.ELEMENT_NODE) {
            const name = node.localName.toLowerCase();
            if (node === overlay || excluded.has(name) || node.hasAttribute('hidden') ||
                (node.getAttribute('aria-hidden') || '').toLowerCase() === 'true') return;
            if (blocks.has(name)) separator();
            for (const child of node.childNodes) walk(child,depth+1);
            if (blocks.has(name)) separator();
          }
        }
        walk(document.body,0);
        return cache = {text,starts,ends};
      }
      function range(start,end) {
        const m = index();
        if (!boundary(m.text,start) || !boundary(m.text,end) || end <= start) return null;
        const a = m.starts[start], b = m.ends[end-1]; if (!a || !b) return null;
        const r = document.createRange(); r.setStart(...a); r.setEnd(...b); return r;
      }
      function anchor(start,end) {
        const m = index(); if (!range(start,end) || end-start > 4096) return null;
        let before = Math.max(0,start-32), after = Math.min(m.text.length,end+32);
        if (!boundary(m.text,before)) before++; if (!boundary(m.text,after)) after--;
        return {chapter_href:config.href,quote:m.text.slice(start,end),prefix:m.text.slice(before,start),
          suffix:m.text.slice(end,after),start_utf16:start,end_utf16:end};
      }
      function resolve(a) {
        const {text} = index();
        if (!a || a.chapter_href !== config.href || !a.quote || a.quote.length > 4096) return null;
        const start=a.start_utf16, end=a.end_utf16;
        if (Number.isInteger(start) && Number.isInteger(end) && boundary(text,start) && boundary(text,end) &&
            end-start === a.quote.length && text.slice(start,end) === a.quote) return range(start,end);
        let found=null, cursor=0;
        while (cursor < text.length) {
          const i=text.indexOf(a.quote,cursor); if (i<0) break; const e=i+a.quote.length;
          if (boundary(text,i) && boundary(text,e) && i >= a.prefix.length && e+a.suffix.length <= text.length &&
              text.slice(i-a.prefix.length,i) === a.prefix && text.slice(e,e+a.suffix.length) === a.suffix) {
            if (found) return null; found=range(i,e);
          }
          cursor=i+1;
        }
        return found;
      }
      function offsetAt(node,offset,end) {
        const m=index(), point=document.createRange(); point.setStart(node,offset); point.collapse(true);
        let low=0, high=m.text.length;
        while (low<high) {
          let mid=(low+high)>>1; if (!boundary(m.text,mid)) mid--;
          const p=end ? m.ends[mid] : m.starts[mid];
          if (!p) { low=mid+2; continue; }
          const probe=document.createRange(); probe.setStart(...p); probe.collapse(true);
          const cmp=probe.compareBoundaryPoints(Range.START_TO_START,point);
          if (cmp < 0 || (end && cmp === 0)) low=mid+(m.text.codePointAt(mid)>0xffff?2:1); else high=mid;
        }
        return Math.min(m.text.length,low);
      }
      function selection() {
        const s=window.getSelection(); if (!s || s.isCollapsed || !s.rangeCount) return null;
        const r=s.getRangeAt(0); if (!document.body.contains(r.commonAncestorContainer)) return null;
        return anchor(offsetAt(r.startContainer,r.startOffset,false),offsetAt(r.endContainer,r.endOffset,true));
      }
      let pencilStart = {value:null};
      function pencil(phase,x,y) {
        if (!config?.active) return;
        if (phase==='cancel') { pencilStart.value=null; return; }
        const caret=document.caretRangeFromPoint(x,y);
        if (!caret || !document.body.contains(caret.startContainer)) return;
        const point=offsetAt(caret.startContainer,caret.startOffset,false);
        if (phase==='begin') { pencilStart.value=point; return; }
        if (pencilStart.value===null) return;
        const start=Math.min(pencilStart.value,point), end=Math.max(pencilStart.value,point);
        const r=range(start,end), a=anchor(start,end);
        if (r && a) { const s=window.getSelection(); s.removeAllRanges(); s.addRange(r); }
        if (phase==='end') {
          pencilStart.value=null;
          if (a) post('pencilHighlight',{anchor:a});
          window.getSelection()?.removeAllRanges();
        }
      }
      const scrollable = () => Math.max(0,document.documentElement.scrollHeight-innerHeight);
      const paged = () => config?.settings?.layout === 'paged';
      function updatePageGeometry() {
        const margin=Math.max(24,innerWidth*0.06);
        document.documentElement.style.setProperty('--vellum-page-margin',margin+'px');
        document.documentElement.style.setProperty('--vellum-page-width',Math.max(1,innerWidth-margin*2)+'px');
        document.documentElement.style.setProperty('--vellum-page-gap',margin*2+'px');
      }
      function pageInfo() {
        const width=Math.max(1,innerWidth), count=Math.max(1,Math.round(document.documentElement.scrollWidth/width));
        return {page:Math.max(0,Math.min(count-1,Math.round(scrollX/width))),count};
      }
      function goTo(page) {
        const info=pageInfo(), target=Math.max(0,Math.min(info.count-1,Math.trunc(Number(page)||0)));
        scrollTo(target*innerWidth,0);
        return target;
      }
      function turn(step) {
        if (!paged()) return 'scroll';
        const info=pageInfo(), target=info.page+step;
        if (target>=0 && target<info.count) { goTo(target); return 'moved'; }
        post('edge',{step});
        return 'edge';
      }
      const pageAt = rect => Math.max(0,Math.min(pageInfo().count-1,
        Math.floor((scrollX+rect.left)/Math.max(1,innerWidth))));
      function visible() {
        const m=index();
        if (paged()) {
          const previous=viewport?.anchor && resolve(viewport.anchor);
          const previousRect=previous && previous.getClientRects()[0];
          if (previousRect && pageAt(previousRect)===pageInfo().page) return viewport.anchor;
          const margin=Math.max(24,innerWidth*0.06);
          const top=(parseFloat(getComputedStyle(document.documentElement).paddingTop)||0)+8;
          for (let y=top;y<Math.min(innerHeight,top+240);y+=24) for (let x=margin+8;x<innerWidth-margin;x+=Math.max(40,innerWidth/12)) {
            const caret=document.caretRangeFromPoint(x,y); if (!caret || caret.startContainer.nodeType!==Node.TEXT_NODE) continue;
            let start=offsetAt(caret.startContainer,caret.startOffset,false), end=Math.min(m.text.length,start+128);
            if (!boundary(m.text,end)) end--;
            const a=anchor(start,end); if (a) return a;
          }
          return null;
        }
        // Probe actual text near the viewport top, not an offset proportional to text length.
        for (let y=24;y<Math.min(innerHeight,240);y+=24) for (let x=32;x<innerWidth;x+=Math.max(40,innerWidth/12)) {
          const caret=document.caretRangeFromPoint(x,y); if (!caret || caret.startContainer.nodeType!==Node.TEXT_NODE) continue;
          let start=offsetAt(caret.startContainer,caret.startOffset,false), end=Math.min(m.text.length,start+128);
          if (!boundary(m.text,end)) end--;
          const a=anchor(start,end); if (a) return a;
        }
        return null;
      }
      function snapshot() {
        const current=visible();
        if (paged()) {
          const info=pageInfo();
          return {anchor:current,progression:info.count>1?info.page/(info.count-1):0,page:info.page,pageCount:info.count};
        }
        return {anchor:current,progression:scrollable()?Math.min(1,scrollY/scrollable()):0};
      }
      function report() {
        if (restoring || !config?.active) return;
        viewport=snapshot();
        if (paged()) post('progress',{anchor:viewport.anchor,value:viewport.progression,page:viewport.page,pageCount:viewport.pageCount});
        else post('progress',{anchor:viewport.anchor,value:viewport.progression});
      }
      function restore(location) {
        if (!location) return;
        restoring=true;
        const pagedMode=paged();
        const r=location.anchor && resolve(location.anchor);
        if (r) {
          if (pagedMode) {
            const rect=r.getClientRects()[0]||r.getBoundingClientRect();
            goTo(pageAt(rect));
            viewport={anchor:location.anchor,progression:location.progression||0};
          }
          else { const rect=r.getBoundingClientRect(); scrollTo(0,scrollY+rect.top-24); }
        }
        else {
          if (location.anchor) post('unresolvedLocation');
          const id=location.fragment, target=id && (document.getElementById(id) || document.getElementsByName(id)[0]);
          if (pagedMode) {
            if (target) goTo(pageAt(target.getBoundingClientRect()));
            else goTo(Math.round(Math.min(1,Math.max(0,location.progression||0))*(pageInfo().count-1)));
          } else {
            if (target) target.scrollIntoView(); else scrollTo(0,scrollable()*Math.min(1,Math.max(0,location.progression || 0)));
          }
        }
        restoring=false; viewport=snapshot(); paint(); report();
      }
      function paint() {
        if (!overlay) { overlay=element('div'); overlay.setAttribute('aria-label','Passage annotations');
          Object.assign(overlay.style,{position:'absolute',top:'0',left:'0',width:'0',height:'0',pointerEvents:'none',zIndex:'2147483646'});
          document.documentElement.appendChild(overlay); }
        overlay.replaceChildren(); const unresolved=[];
        for (const a of annotations) {
          const r=resolve(a.anchor); if (!r) { unresolved.push(a.id); continue; }
          if (a.handwriting) {
            const rect=r.getBoundingClientRect(), mark=element('button'); mark.type='button';
            mark.textContent='✎'; mark.setAttribute('aria-label','Open passage handwriting');
            Object.assign(mark.style,{position:'absolute',left:Math.max(2,rect.left+scrollX-30)+'px',
              top:(rect.top+scrollY)+'px',width:'28px',height:'28px',fontSize:'22px',padding:'0',
              border:'0',borderRadius:'6px',background:'#e4e2fa',color:'#45418f',
              pointerEvents:config?.active?'auto':'none',cursor:'pointer'});
            mark.addEventListener('click',()=>post('annotation',{id:a.id})); overlay.appendChild(mark);
            continue;
          }
          for (const rect of Array.from(r.getClientRects()).slice(0,500)) {
            const mark=element('button'); mark.type='button'; mark.setAttribute('aria-label','Open annotation');
            const color=/^#[0-9a-fA-F]{6}$/.test(a.color || '')?a.color:'#fef08a';
            Object.assign(mark.style,{position:'absolute',left:(rect.left+scrollX)+'px',top:(rect.top+scrollY)+'px',
              width:rect.width+'px',height:rect.height+'px',padding:'0',border:'0',borderRadius:'2px',
              background:color,opacity:'0.32',pointerEvents:config?.active?'auto':'none',cursor:'pointer'});
            mark.addEventListener('click',()=>post('annotation',{id:a.id})); overlay.appendChild(mark);
          }
        }
        post('unresolved',{unresolved});
      }
      const schedule=()=>{clearTimeout(timer);timer=setTimeout(report,200);};
      window.addEventListener('scroll',schedule,{passive:true});
      document.addEventListener('selectionchange',()=>{
        const anchor=selection();
        // WebKit also clears its selection when focus moves to the note editor.
        if (anchor) post('selection',{anchor});
      });
      const finishSelection=()=>post('selection',{anchor:selection()});
      document.addEventListener('pointerup',event=>{lastPointerWasPen=event.pointerType==='pen';finishSelection();});
      document.addEventListener('keyup',finishSelection);
      let resizeTimer;
      window.addEventListener('resize',()=>{
        const saved=viewport; clearTimeout(resizeTimer);
        resizeTimer=setTimeout(()=>{ if(paged()) updatePageGeometry(); restore(saved); },100);
      });
      document.addEventListener('load',()=>{ if(viewport) restore(viewport); },true);
      let lastPointerWasPen=false;
      document.addEventListener('click',event=>{
        if (!paged() || !config?.active || lastPointerWasPen) return;
        if (overlay && event.target instanceof Node && overlay.contains(event.target)) return;
        const selected=window.getSelection();
        if (selected && !selected.isCollapsed) return;
        if (event.target instanceof Element && event.target.closest('a,button,[role=button]')) return;
        if (event.clientX<innerWidth*0.25) turn(-1);
        else if (event.clientX>innerWidth*0.75) turn(1);
      });
      window.__vellumEpub={
        configure(c) {
          const saved=config && snapshot(); config=c;
          const root=document.documentElement;
          root.toggleAttribute('data-vellum-dark',c.dark);
          root.toggleAttribute('data-vellum-paged',c.settings.layout==='paged');
          root.style.colorScheme=c.dark?'dark':'light';
          root.style.setProperty('--vellum-epub-well',c.colors.well);
          root.style.setProperty('--vellum-epub-surface',c.colors.surface);
          root.style.setProperty('--vellum-epub-foreground',c.colors.foreground);
          root.style.setProperty('--vellum-epub-primary',c.colors.primary);
          root.style.setProperty('--vellum-epub-border',c.colors.border);
          if (paged()) updatePageGeometry();
          document.body.style.setProperty('font-size',c.settings.fontSize+'px','important');
          document.body.style.setProperty('line-height',String(c.settings.lineSpacing),'important');
          // Inherited controls retain publisher headings, emphasis, images and layout.
          if (saved) restore(saved);
        },
        restore, selection, snapshot, pencil, pageInfo, goTo, turn,
        annotations(items) { annotations=items.slice(0,1000); paint(); },
        text:()=>index().text, resolve:a=>!!resolve(a),
        dispose() { config=null; clearTimeout(timer);clearTimeout(resizeTimer);overlay?.remove(); }
      };
    })();
    """#
}
#endif
