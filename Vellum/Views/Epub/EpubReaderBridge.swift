#if os(macOS)
import Foundation

struct EpubReaderSettings: Equatable, Codable {
    var fontSize: Double
    var lineSpacing: Double

    init(fontSize: Double = 18, lineSpacing: Double = 1.6) {
        self.fontSize = fontSize.isFinite ? min(36, max(12, fontSize)) : 18
        self.lineSpacing = lineSpacing.isFinite ? min(2.4, max(1.1, lineSpacing)) : 1.6
    }

    static func load() -> Self {
        let defaults = AppDefaults.current
        return Self(fontSize: defaults.object(forKey: "epub.fontSize") as? Double ?? 18,
                    lineSpacing: defaults.object(forKey: "epub.lineSpacing") as? Double ?? 1.6)
    }

    func save() {
        let bounded = Self(fontSize: fontSize, lineSpacing: lineSpacing)
        AppDefaults.current.set(bounded.fontSize, forKey: "epub.fontSize")
        AppDefaults.current.set(bounded.lineSpacing, forKey: "epub.lineSpacing")
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

    static func decode(_ body: Any, token: String, href: String, docId: String) -> Self? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64 * 1024,
              let message = try? JSONDecoder().decode(Self.self, from: data),
              message.token == token, message.href == href,
              ["progress", "selection", "annotation", "unresolved", "unresolvedLocation"].contains(message.type),
              message.value.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              message.id.map({ $0.utf16.count <= 256 }) ?? true,
              message.unresolved.map({ $0.count <= 500 && $0.allSatisfy { $0.utf16.count <= 256 } }) ?? true
        else { return nil }
        if let anchor = message.anchor {
            guard anchor.chapterHref == href,
                  AiEpubCitation(docId: docId, chapterNumber: 1, chapterHref: href, anchor: anchor).bounded != nil
            else { return nil }
        }
        if message.type == "progress", message.value == nil { return nil }
        if message.type == "annotation", message.id == nil { return nil }
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
      style.textContent = `html { -webkit-text-size-adjust:100%; }
        body { max-width:44em; margin:0 auto !important; padding:2.5em 2em 5em !important; }
        img,svg,video { max-width:100%; height:auto; } pre { white-space:pre-wrap; }
        html[data-vellum-dark] { background:#1c1c1e !important; color:#eee !important; color-scheme:dark; }
        html[data-vellum-dark] body { background:transparent !important; color:#eee !important; }
        html[data-vellum-dark] a { color:#9bc6ff; }`;
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
      const scrollable = () => Math.max(0,document.documentElement.scrollHeight-innerHeight);
      function visible() {
        const m=index();
        // Probe actual text near the viewport top, not an offset proportional to text length.
        for (let y=24;y<Math.min(innerHeight,240);y+=24) for (let x=32;x<innerWidth;x+=Math.max(40,innerWidth/12)) {
          const caret=document.caretRangeFromPoint(x,y); if (!caret || caret.startContainer.nodeType!==Node.TEXT_NODE) continue;
          let start=offsetAt(caret.startContainer,caret.startOffset,false), end=Math.min(m.text.length,start+128);
          if (!boundary(m.text,end)) end--;
          const a=anchor(start,end); if (a) return a;
        }
        return null;
      }
      function snapshot() { return {anchor:visible(),progression:scrollable()?Math.min(1,scrollY/scrollable()):0}; }
      function report() {
        if (restoring || !config?.active) return;
        viewport=snapshot(); post('progress',{anchor:viewport.anchor,value:viewport.progression});
      }
      function restore(location) {
        if (!location) return;
        restoring=true;
        const r=location.anchor && resolve(location.anchor);
        if (r) { const rect=r.getBoundingClientRect(); scrollTo(0,scrollY+rect.top-24); }
        else {
          if (location.anchor) post('unresolvedLocation');
          const id=location.fragment, target=id && (document.getElementById(id) || document.getElementsByName(id)[0]);
          if (target) target.scrollIntoView(); else scrollTo(0,scrollable()*Math.min(1,Math.max(0,location.progression || 0)));
        }
        restoring=false; viewport=snapshot(); paint(); report();
      }
      function paint() {
        if (!overlay) { overlay=element('div'); overlay.setAttribute('aria-hidden','true');
          Object.assign(overlay.style,{position:'absolute',top:'0',left:'0',width:'0',height:'0',pointerEvents:'none',zIndex:'2147483646'});
          document.documentElement.appendChild(overlay); }
        overlay.replaceChildren(); const unresolved=[];
        for (const a of annotations) {
          const r=resolve(a.anchor); if (!r) { unresolved.push(a.id); continue; }
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
      document.addEventListener('pointerup',finishSelection);
      document.addEventListener('keyup',finishSelection);
      let resizeTimer;
      window.addEventListener('resize',()=>{
        const saved=viewport; clearTimeout(resizeTimer);
        resizeTimer=setTimeout(()=>restore(saved),100);
      });
      document.addEventListener('load',()=>{ if(viewport) restore(viewport); },true);
      window.__vellumEpub={
        configure(c) {
          const saved=config && snapshot(); config=c;
          document.documentElement.toggleAttribute('data-vellum-dark',c.dark);
          document.documentElement.style.colorScheme=c.dark?'dark':'light';
          document.body.style.setProperty('font-size',c.settings.fontSize+'px','important');
          document.body.style.setProperty('line-height',String(c.settings.lineSpacing),'important');
          // Inherited controls retain publisher headings, emphasis, images and layout.
          if (saved) restore(saved);
        },
        restore, selection, snapshot,
        annotations(items) { annotations=items.slice(0,500); paint(); },
        text:()=>index().text, resolve:a=>!!resolve(a),
        dispose() { config=null; clearTimeout(timer);clearTimeout(resizeTimer);overlay?.remove(); }
      };
    })();
    """#
}
#endif
