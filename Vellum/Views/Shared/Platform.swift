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

extension Image {
    /// Bridge a platform image (NSImage/UIImage) into a SwiftUI `Image` without
    /// callers needing to branch on the platform.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Set the VoiceOver description in a cross-platform way. On AppKit this is
    /// `accessibilityDescription`; on UIKit the informal `accessibilityLabel`.
    func setAccessibilityDescription(_ description: String) {
        #if os(macOS)
        accessibilityDescription = description
        #else
        accessibilityLabel = description
        #endif
    }
}
