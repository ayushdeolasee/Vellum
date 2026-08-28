#if os(iOS)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The transcript half of the reference-chip UI (issue #58).
//
// The composer shows removable chips for whatever the user has attached to the
// *next* message (`ReferenceChipRow` in ComposerReferences.swift). Those chips
// vanish on send, and the referenced text is never part of the message body —
// it reaches the model only through the prompt's "User-referenced context"
// block — so a sent prompt used to leave no trace of the context it carried.
//
// `SentReferenceChips` renders the same visual language, read-only, next to the
// user bubble it belongs to, with the excerpt one tap away.
//
// The chip's icon/label vocabulary lives here as an `AiReference` extension so
// both rows speak it; putting it on the model keeps the two chip views from
// drifting into two different names for the same reference.
//
// iPad deviations from the macOS original: UIKit image decode, no hover state
// (there is no pointer to hover with), and the chip carries extra invisible
// vertical padding so the tap target clears 30pt without growing the pill.

extension AiReference {
    /// SF Symbol for this reference's kind.
    var chipIcon: String {
        switch kind {
        case .selection: return "text.quote"
        case .highlight: return "highlighter"
        case .region: return "square.dashed"
        case .pageSnapshot: return "doc.richtext"
        case .quote: return "quote.bubble"
        case .image: return "photo"
        }
    }

    /// One-line chip caption — the excerpt (whitespace collapsed) plus a page
    /// locator where there is one.
    var chipLabel: String {
        switch kind {
        case let .selection(text, page): return "“\(Self.collapse(text))” · p.\(page)"
        case let .highlight(text, page): return "“\(Self.collapse(text))” · p.\(page)"
        case let .region(_, page): return "Region · p.\(page)"
        case let .pageSnapshot(_, page): return "Page \(page)"
        case let .quote(text, _): return "“\(Self.collapse(text))”"
        case let .image(_, name): return name
        }
    }

    /// Human name for the kind, used as the popover's title.
    var chipKindName: String {
        switch kind {
        case .selection: return "Selected text"
        case .highlight: return "Highlight"
        case .region: return "Region snapshot"
        case .pageSnapshot: return "Page snapshot"
        case .quote: return "Quoted reply"
        case .image: return "Attached image"
        }
    }

    /// Flatten newlines and runs of spaces so a multi-line selection still reads
    /// as one line inside a chip.
    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Read-only chips for the references a user message was sent with.
///
/// Differs from the composer's `ReferenceChipRow` in three ways, each forced by
/// where it sits: no × (the message is already on the wire), no inline
/// thumbnails (the persisted references carry no pixels — see
/// `AiReference.strippingImageData` — and the full-size preview is one tap
/// away anyway), and it wraps instead of scrolling horizontally, because a
/// horizontal ScrollView nested in the transcript would swallow drag gestures
/// meant for the transcript itself.
struct SentReferenceChips: View {
    let references: [AiReference]
    /// Scroll the reader to a page a reference points at. Called only for
    /// references with a `page`.
    let onGoToPage: (Int) -> Void
    /// Pixels to preview for an image-carrying reference, or nil when there are
    /// none to show. Resolved by the store, not by the reference itself: the
    /// persisted copy has had its base64 stripped, so the bytes come from the
    /// session cache (`AiStore.referencePreviewData(for:)`) and are unavailable
    /// for a message restored from an earlier run.
    let previewData: (AiReference) -> Data?
    /// The width the chips wrap at — the same cap the bubble below them uses
    /// (`AiPanel_iOS.bubbleMaxWidth(for:contentWidth:)`), passed in rather than
    /// hardcoded. It used to be a literal 272, which was the bubble's fixed
    /// width until #64 made bubbles scale with the resizable sidebar; left
    /// alone it would pin the chips at 272 while a wide sidebar grew the bubble
    /// past them, and overflow the bubble on a sidebar narrower than 272.
    let maxWidth: CGFloat

    var body: some View {
        ChipFlowLayout(spacing: 4, lineSpacing: 4, alignment: .trailing) {
            ForEach(references) { reference in
                SentReferenceChip(
                    reference: reference, onGoToPage: onGoToPage, previewData: previewData)
            }
        }
        // Matches the bubble's own cap so the chips read as one column with it.
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .accessibilityIdentifier("aiMessage.references")
    }
}

private struct SentReferenceChip: View {
    let reference: AiReference
    let onGoToPage: (Int) -> Void
    let previewData: (AiReference) -> Data?

    @Environment(\.palette) private var palette
    @State private var detailShown = false

    var body: some View {
        Button { detailShown = true } label: {
            HStack(spacing: 4) {
                Image(systemName: reference.chipIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.primary)
                Text(reference.chipLabel)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                .quaternary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(palette.border.opacity(0.7))
            }
            // The pill itself is ~18pt tall — a mouse target, not a finger one.
            // Pad it out to a 30pt tap target *outside* the background so the
            // chip keeps the Mac's visual size, and shape the padded area so a
            // tap in the invisible strip still hits the button.
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(reference.chipKindName): \(reference.chipLabel)")
        .accessibilityHint(
            reference.image == nil ? "Show the referenced text" : "Show a preview of the image")
        .accessibilityIdentifier("aiMessage.reference")
        .popover(isPresented: $detailShown, arrowEdge: .bottom) {
            SentReferenceDetail(
                reference: reference,
                // Resolved here, at presentation, rather than up front for every
                // chip in the transcript: base64-decoding a ~200 KB page
                // snapshot per chip on every transcript render would be wasted
                // work for popovers that are mostly never opened.
                preview: previewData(reference).flatMap(UIImage.init(data:)),
                onGoToPage: { page in
                    // Dismiss first: leaving a popover open over a page the
                    // reader just scrolled away from is disorienting.
                    detailShown = false
                    onGoToPage(page)
                }
            )
            // In a compact split-view width iPadOS would promote this popover to
            // a sheet, which loses the "this chip, right here" attachment the
            // whole affordance depends on. Keep it anchored.
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Popover body: what the reference actually was.
///
/// Text-bearing kinds show the verbatim excerpt (selectable, so it can be copied
/// back out). Image kinds — a page snapshot, a region screenshot, an attached
/// image — show the image itself when its pixels are still available, and say
/// plainly when they aren't.
///
/// WHY AN IMAGE CAN BE UNAVAILABLE. References are persisted with their base64
/// pixels dropped (`AiReference.strippingImageData`): a page snapshot is ~200 KB
/// and `conversations.json` is re-encoded and rewritten in full on every turn,
/// so keeping them would turn a few-KB transcript into megabytes of churn.
/// `AiStore` therefore holds the pixels in a session-scoped cache, which covers
/// every message sent in the current run of the app. A message reloaded from a
/// previous session has no pixels anywhere, so it gets the descriptor plus an
/// explicit note — never a blank frame the user is left to interpret. Making old
/// previews work would mean writing the images to their own files beside the
/// transcript, which is a storage change and deliberately not part of this PR.
private struct SentReferenceDetail: View {
    let reference: AiReference
    /// Decoded pixels, or nil when this reference is no longer previewable.
    let preview: UIImage?
    let onGoToPage: (Int) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: reference.chipIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.primary)
                Text(reference.chipKindName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                if let page = reference.page {
                    Text("· page \(page)")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                }
            }

            if reference.image != nil {
                imageBody
            } else {
                excerptBody
            }

            if let page = reference.page {
                // Deliberately not `.buttonStyle(.link)`: that paints the system
                // link blue, which clashes with the app's own accent everywhere
                // else in the panel. Plain + `palette.primary` reads as a link
                // and stays on-palette in both themes.
                Button { onGoToPage(page) } label: {
                    Label("Go to page \(page)", systemImage: "arrow.right.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("aiMessage.reference.goToPage")
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// The verbatim excerpt for a selection / highlight / quote.
    private var excerptBody: some View {
        ScrollView {
            Text(reference.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                .font(.system(size: 12))
                .foregroundStyle(palette.foreground)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Long excerpts must wrap, not clip; the fixed frame width on
                // the popover constrains them first.
                .fixedSize(horizontal: false, vertical: true)
        }
        // A whole-page selection would otherwise grow the popover past the
        // screen; cap the height and let it scroll.
        .frame(maxHeight: 220)
    }

    /// The image itself when we still have it, otherwise the descriptor and a
    /// plain statement of why there is nothing to show.
    @ViewBuilder
    private var imageBody: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                // A page snapshot is taller than it is wide and a region crop can
                // be any shape, so fit inside the box rather than filling it —
                // filling would silently crop the very thing being previewed.
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .overlay {
                    // A white page snapshot on a light popover has no edge
                    // otherwise, and reads as part of the chrome.
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(palette.border)
                }
                .accessibilityLabel("Preview of \(reference.chipKindName.lowercased())")
                .accessibilityIdentifier("aiMessage.reference.preview")
            Text(imageDescriptor)
                .font(.system(size: 11))
                .foregroundStyle(palette.mutedForeground)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(imageDescriptor)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.foreground)
                Text("Preview unavailable — images aren't kept once the app restarts.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("aiMessage.reference.previewUnavailable")
        }
    }

    /// Name (for a dropped/picked image) and pixel dimensions — the part of an
    /// image reference that is always persisted.
    private var imageDescriptor: String {
        guard let image = reference.image else { return "" }
        var parts = ["\(image.width)×\(image.height)"]
        if case let .image(_, name) = reference.kind { parts.insert(name, at: 0) }
        return parts.joined(separator: " · ")
    }
}

#Preview("Sent reference chips") {
    let snapshot = AiPageImageSnapshot(
        pageNumber: 2, base64Data: "", mediaType: "image/jpeg", width: 1280, height: 1656)
    return VStack(alignment: .trailing, spacing: 12) {
        // Four references, deliberately mixed-width, to exercise the wrap.
        SentReferenceChips(
            references: [
                AiReference(kind: .selection(
                    text: "Chlorophyll a absorbs light most strongly in the blue (430 nm) and red "
                        + "(662 nm) bands of the visible spectrum.", page: 2)),
                AiReference(kind: .highlight(text: "Calvin cycle", page: 3)),
                AiReference(kind: .pageSnapshot(image: snapshot, page: 2)),
                AiReference(kind: .image(
                    image: snapshot, name: "absorption-spectrum.png")),
            ],
            onGoToPage: { _ in },
            // Stands in for a reference reloaded from a previous session: no
            // pixels, so its popover shows the "preview unavailable" branch.
            previewData: { _ in nil },
            // The user-bubble cap for this preview's 300pt column.
            maxWidth: AiPanel_iOS.bubbleMaxWidth(for: .user, contentWidth: 300)
        )
        // The single-chip case, which must hug the trailing edge like the bubble.
        SentReferenceChips(
            references: [AiReference(kind: .quote(
                text: "Green light is largely reflected.", messageId: "a1"))],
            onGoToPage: { _ in },
            previewData: { _ in nil },
            maxWidth: AiPanel_iOS.bubbleMaxWidth(for: .user, contentWidth: 300)
        )
    }
    .frame(width: 300, alignment: .trailing)
    .padding(20)
    .background(Color(hex: "#1a1a1a"))
    .environment(\.palette, .dark)
    .preferredColorScheme(.dark)
    .tint(ThemePalette.dark.primary)
}

/// Minimal wrapping row container: lays subviews left-to-right and starts a new
/// line when the next one would overflow the proposed width.
///
/// SwiftUI ships no flow container, and the two obvious substitutes don't work
/// here — a horizontal `ScrollView` (what the composer uses) steals the
/// transcript's scroll gestures, and an `HStack` would squeeze every chip to
/// illegibility once a message carries more than two or three.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    /// Which edge each line hugs. `.trailing` for user messages, whose bubble is
    /// right-aligned.
    var alignment: HorizontalAlignment

    /// One laid-out line: the subview index range it covers and its extents.
    private struct Line {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: width, height: nil))
            let advance = lineWidth == 0 ? size.width : lineWidth + spacing + size.width
            // Never wrap the first item on a line: a chip wider than the
            // container still has to go somewhere, and it truncates instead.
            if advance > width, index > start {
                lines.append(Line(range: start..<index, width: lineWidth, height: lineHeight))
                start = index
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth = advance
                lineHeight = max(lineHeight, size.height)
            }
        }
        if start < subviews.count {
            lines.append(Line(range: start..<subviews.count, width: lineWidth, height: lineHeight))
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        // An unspecified/infinite proposal means "how wide would you like to
        // be?" — answer with one unwrapped line and let the real proposal wrap.
        let width = proposal.width.map { $0.isFinite ? $0 : .greatestFiniteMagnitude }
            ?? .greatestFiniteMagnitude
        let lines = lines(for: subviews, width: width)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - line.width : bounds.minX
            for index in line.range {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
#endif
