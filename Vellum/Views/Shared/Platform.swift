import SwiftUI

// Cross-platform aliases so the shared layer (services, stores, shared views)
// compiles for both macOS (AppKit) and iOS/iPadOS (UIKit). The iPad app targets
// iOS; the macOS reference sources remain in the tree behind `#if os(macOS)`.

#if os(macOS)
import AppKit

typealias PlatformColor = NSColor
typealias PlatformImage = NSImage

extension PlatformColor {
    /// Device-RGB color; on macOS this is `deviceRed:` so PDFAnnotation `/C`
    /// serialization stays channel/255 exactly as the Rust writer produced.
    static func annotationRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor {
        NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
    }
}
#else
import UIKit

typealias PlatformColor = UIColor
typealias PlatformImage = UIImage

extension PlatformColor {
    static func annotationRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
#endif

extension Color {
    /// Bridge a SwiftUI Color to the platform color type for AppKit/UIKit APIs
    /// (PDFView backgrounds, PDFAnnotation colors, etc.).
    var platformColor: PlatformColor { PlatformColor(self) }
}
