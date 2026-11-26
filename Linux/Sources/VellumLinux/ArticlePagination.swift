// Mirrors WebContentScript's virtual text pages. Keep only enough normalized
// UTF-16 text to locate its first 200 pages, and retain one DOM range per page.
let articlePaginationScript = #"""
function articlePages() {
    const skip = 'script,style,noscript,template,iframe,object,textarea,select,head,title,svg,[hidden],[aria-hidden="true"]';
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
            if (node.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
            return node.matches(skip) || node.style?.display === 'none' || node.style?.visibility === 'hidden'
                ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
        }
    });
    const segments = [], offsets = [], chars = [];
    let lastSpace = true, raw = 0;
    for (let node; (node = walker.nextNode()) && segments.length < 50000 && chars.length < 720001;) {
        const text = node.data;
        segments.push({node, start: raw, end: raw + text.length});
        for (let i = 0; i < text.length && chars.length < 720001; i++) {
            const space = /[\s\u0000-\u0020]/u.test(text[i]);
            if (!space || !lastSpace) {
                chars.push(space ? ' ' : text[i]);
                offsets.push(raw + i);
            }
            lastSpace = space;
        }
        raw += text.length;
    }
    const text = chars.join(''), ranges = [];
    let cursor = 0, segment = 0;
    while (cursor < text.length && ranges.length < 200) {
        const start = offsets[cursor];
        while (segments[segment].end <= start) segment++;
        const part = segments[segment], at = start - part.start;
        const range = document.createRange();
        range.setStart(part.node, at);
        range.setEnd(part.node, at + 1);
        ranges.push(range);
        let end = Math.min(cursor + 3600, text.length);
        if (end < text.length) {
            const chunk = text.slice(cursor, end);
            const sentence = chunk.lastIndexOf('. '), space = chunk.lastIndexOf(' ');
            if (sentence > 2160) end = cursor + sentence + 1;
            else if (space > 2160) end = cursor + space;
        }
        cursor = end;
        while (text[cursor] === ' ') cursor++;
    }
    function measure() {
        let previous = 0;
        return ranges.length ? ranges.map(range =>
            previous = Math.max(previous, scrollY + range.getBoundingClientRect().top)) : [0];
    }
    let tops = measure();
    addEventListener('resize', () => { tops = measure(); });
    return {
        get count() { return tops.length; },
        top(page) { return Math.max(0, tops[Math.min(tops.length, Math.max(1, page)) - 1] - 12); },
        current() {
            const anchor = scrollY + innerHeight * .35;
            let i = 1;
            while (i < tops.length && tops[i] <= anchor) i++;
            return i;
        }
    };
}
"""#
