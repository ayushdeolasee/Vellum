import Foundation

// The parsed, render-independent shape of one EPUB 2/3 book: package metadata,
// manifest, reading order (spine) and navigation. Every resource path here is
// an archive-relative path already resolved against the file that referenced
// it, so consumers never re-resolve publisher hrefs.

struct EpubPublication: Codable, Equatable, Sendable {
    struct Metadata: Codable, Equatable, Sendable {
        var title: String?
        var creators: [String] = []
        var language: String?
        var identifier: String?
        var publisher: String?
        var description: String?
    }

    struct ManifestItem: Codable, Equatable, Sendable {
        var id: String
        var path: String
        var mediaType: String
        var properties: [String] = []
    }

    /// One reading-order document. `path` points at the renderable content
    /// document after following the manifest fallback chain.
    struct SpineItem: Codable, Equatable, Sendable {
        var idref: String
        var path: String
        var mediaType: String
        var linear: Bool
    }

    /// One table-of-contents entry. `path` is nil for heading-only entries and
    /// for links whose target is not inside the package.
    struct TocEntry: Codable, Equatable, Sendable {
        var title: String
        var path: String?
        var fragment: String?
        var children: [TocEntry] = []
    }

    /// The package's declared version ("2.0", "3.0", …).
    var version: String
    /// Archive path of the OPF package document.
    var packagePath: String
    var metadata: Metadata
    var manifest: [ManifestItem]
    var spine: [SpineItem]
    var toc: [TocEntry]
    var coverPath: String?
    /// Font resources obfuscated per the IDPF/Adobe font-mangling algorithms.
    /// They are not DRM, but must be de-obfuscated (or skipped) by the reader.
    var obfuscatedResourcePaths: [String] = []

    func manifestItem(path: String) -> ManifestItem? {
        manifest.first { $0.path == path }
    }

    func spineIndex(path: String) -> Int? {
        spine.firstIndex { $0.path == path }
    }
}

enum EpubError: Error, LocalizedError, Equatable {
    case notAnArchive
    case unsafeArchive(String)
    case archiveTooLarge
    case resourceTooLarge(String)
    case missingResource(String)
    case invalidMimetype
    case missingContainer
    case missingPackage
    case malformedXML(String)
    case invalidPackage(String)
    case emptySpine
    case drmProtected
    case fixedLayoutUnsupported

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "This file is not a valid EPUB book (it is not a ZIP archive)."
        case .unsafeArchive(let reason):
            return "This EPUB was rejected because its archive is unsafe: \(reason)."
        case .archiveTooLarge:
            return "This EPUB expands to more data than Vellum allows for one book."
        case .resourceTooLarge(let path):
            return "The EPUB resource “\(path)” is larger than Vellum allows."
        case .missingResource(let path):
            return "The EPUB is missing “\(path)”."
        case .invalidMimetype:
            return "This file is not an EPUB book (its mimetype entry is not application/epub+zip)."
        case .missingContainer:
            return "This file is not a valid EPUB book (META-INF/container.xml is missing)."
        case .missingPackage:
            return "This EPUB does not point to a readable package document."
        case .malformedXML(let detail):
            return "This EPUB contains malformed XML: \(detail)."
        case .invalidPackage(let detail):
            return "This EPUB's package document is invalid: \(detail)."
        case .emptySpine:
            return "This EPUB has no readable chapters."
        case .drmProtected:
            return "This EPUB is protected by DRM. Vellum can open DRM-free books only."
        case .fixedLayoutUnsupported:
            return "Fixed-layout EPUBs are not supported yet. Vellum can open reflowable books."
        }
    }
}
