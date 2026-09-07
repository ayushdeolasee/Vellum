#if os(iOS)
import PDFKit
import UIKit

/// Crops a prepared reader page without allocating a full-page bitmap.
/// Reader preparation has already removed PDF annotations; ink and highlights
/// live in overlays. The raw page preserves PDF rotation and crop-box offsets.
@MainActor
enum PdfRegionRenderer_iOS {
    static func render(page: PDFPage, box: PDFDisplayBox, fullSize: CGSize, crop: CGRect) -> UIImage? {
        let crop = crop.integral.intersection(CGRect(origin: .zero, size: fullSize))
        guard !crop.isEmpty else { return nil }
        let source = page.pageRef
        let fallback = source == nil ? page.thumbnail(of: fullSize, for: box) : nil
        let pdfBox: CGPDFBox
        switch box {
        case .mediaBox: pdfBox = .mediaBox
        case .cropBox: pdfBox = .cropBox
        case .bleedBox: pdfBox = .bleedBox
        case .trimBox: pdfBox = .trimBox
        case .artBox: pdfBox = .artBox
        @unknown default: pdfBox = .cropBox
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: crop.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: crop.size))
            guard let source else {
                fallback?.draw(in: CGRect(
                    x: -crop.minX, y: -crop.minY, width: fullSize.width, height: fullSize.height))
                return
            }
            let cg = context.cgContext
            cg.translateBy(x: -crop.minX, y: fullSize.height - crop.minY)
            cg.scaleBy(x: 1, y: -1)
            let bounds = source.getBoxRect(pdfBox)
            let rotated = abs(source.rotationAngle % 180) == 90
            let display = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            cg.scaleBy(x: fullSize.width / display.width, y: fullSize.height / display.height)
            cg.concatenate(source.getDrawingTransform(pdfBox,
                rect: CGRect(origin: .zero, size: display), rotate: 0, preserveAspectRatio: true))
            cg.drawPDFPage(source)
        }
    }
}
#endif
