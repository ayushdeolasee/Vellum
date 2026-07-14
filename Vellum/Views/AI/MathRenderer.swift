import AppKit
import SwiftMath

// Shared LaTeX rendering for the AI chat bubbles. Both message renderers — the
// SwiftUI `MarkdownMessage` (user bubbles) and the AppKit-backed
// `SelectableMessageText` (assistant bubbles) — hand math spans here and get
// back a typeset image plus the baseline metrics needed to sit it on the
// surrounding text line.

/// One piece of an inline-markdown string after splitting out math spans.
enum MathSegment: Equatable {
    case text(String)
    /// LaTeX source with the `$...$` / `\(...\)` delimiters stripped.
    case math(String)
}

@MainActor
enum MathRenderer {
    struct Rendered {
        let image: NSImage
        /// Distance from the image's bottom edge down to the math baseline, so
        /// text hosts can offset the image and keep `x` level with prose.
        let descent: CGFloat
        var size: CGSize { image.size }
    }

    /// Typeset images are cheap but not free (font table lookups + layout), and
    /// streaming re-renders a growing message on every delta — cache by
    /// (latex, size, color, mode).
    private static let cache: NSCache<NSString, CachedRender> = {
        let cache = NSCache<NSString, CachedRender>()
        // Rendered equations are small, but keys are exact LaTeX strings —
        // long sessions with many one-off renders shouldn't grow unbounded.
        cache.countLimit = 300
        return cache
    }()

    private final class CachedRender {
        let rendered: Rendered
        init(_ rendered: Rendered) { self.rendered = rendered }
    }

    /// Render a LaTeX string (no delimiters) to an image. Returns nil when the
    /// source fails to parse, so callers can fall back to styled plain text.
    static func render(latex: String, fontSize: CGFloat, color: NSColor, display: Bool) -> Rendered? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Resolve dynamic (catalog/appearance) colors to concrete sRGB so the
        // cache key can't alias a light-mode render into dark mode.
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = "\(display ? "D" : "T")|\(fontSize)|\(resolved.description)|\(trimmed)" as NSString
        if let hit = cache.object(forKey: key) { return hit.rendered }

        // SwiftMath 1.7.3 keeps its typesetter internal, so build the display
        // list through an offscreen MTMathUILabel (the public API). The label's
        // layout centers the math vertically inside its bounds with the
        // baseline `descent` above the content's bottom edge — giving the label
        // bounds of exactly the fitted content height makes the baseline land
        // at `descent` from the image's bottom, which is what text hosts need.
        let label = MTMathUILabel()
        label.labelMode = display ? .display : .text
        label.fontSize = fontSize
        label.textColor = resolved
        label.textAlignment = .left
        label.latex = trimmed
        guard label.error == nil, label.mathList != nil else { return nil }

        let fitted = label.fittingSize
        guard fitted.width > 0, fitted.height > 0, fitted.width.isFinite, fitted.height.isFinite else { return nil }
        // The label clamps very short content to half the font size when
        // centering; matching that clamp keeps the baseline math exact.
        let size = CGSize(width: ceil(fitted.width), height: ceil(max(fitted.height, fontSize / 2)))
        label.frame = CGRect(origin: .zero, size: size)
        label.layout()
        guard let line = label.displayList else { return nil }
        let descent = line.descent

        // Handler-based NSImage re-draws the display list at the destination
        // context's scale, so the math stays vector-crisp on retina.
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            line.draw(context)
            context.restoreGState()
            return true
        }
        let rendered = Rendered(image: image, descent: descent)
        cache.setObject(CachedRender(rendered), forKey: key)
        return rendered
    }

    /// Split inline text into prose and math spans. Recognizes `\(...\)` and
    /// single-`$` spans; a `$` span must not butt against whitespace on the
    /// inside ("$5 and $10" stays currency, "$x^2$" is math).
    nonisolated static func segments(in source: String) -> [MathSegment] {
        guard source.contains("$") || source.contains("\\(") else { return [.text(source)] }
        let pattern = #"\\\((.+?)\\\)|\$(?![\s$])([^$\n]*[^\s$])\$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.text(source)] }
        let ns = source as NSString
        var segments: [MathSegment] = []
        var cursor = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                segments.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            let latexRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            segments.append(.math(ns.substring(with: latexRange)))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            segments.append(.text(ns.substring(from: cursor)))
        }
        return segments.isEmpty ? [.text(source)] : segments
    }
}
