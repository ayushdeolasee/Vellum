import SwiftUI
import UniformTypeIdentifiers

/// One destination per dragged item: prefer its file/URL representation over
/// the title or message text a source also advertises.
@MainActor
enum HomeDrop {
    static let types: [UTType] = [.fileURL, .url, .pdf, .plainText, .rtf, .html]

    struct Delivery {
        var urls: [URL] = []
        var errors: [String] = []
        var copiedPDFs: [URL] = []
    }

    static func accepts(_ provider: NSItemProvider) -> Bool {
        types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    static func load(_ providers: [NSItemProvider]) async -> Delivery {
        var delivery = Delivery()
        for provider in providers {
            if let url = await loadURL(provider), isSupported(url) {
                if !delivery.urls.contains(url) { delivery.urls.append(url) }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                do {
                    let url = try await copyPDF(provider)
                    delivery.urls.append(url)
                    delivery.copiedPDFs.append(url)
                } catch {
                    delivery.errors.append("Could not receive PDF: \(error.localizedDescription)")
                }
                continue
            }
            var link: URL?
            for type in [UTType.plainText, .rtf, .html] {
                guard provider.hasItemConformingToTypeIdentifier(type.identifier),
                      let data = await loadData(provider, type: type) else { continue }
                link = await Task.detached(priority: .userInitiated) {
                    linkInData(data, type: type)
                }.value
                if link != nil { break }
            }
            if let link {
                if !delivery.urls.contains(link) { delivery.urls.append(link) }
            } else {
                delivery.errors.append("Drop a PDF or a message containing a web link.")
            }
        }
        return delivery
    }

    nonisolated static func isSupported(_ url: URL) -> Bool {
        if url.isFileURL { return url.pathExtension.lowercased() == "pdf" }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty
    }

    nonisolated static func link(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first { !$0.isFileURL && isSupported($0) }
    }

    nonisolated static func linkInData(_ data: Data, type: UTType) -> URL? {
        if type == .plainText { return String(data: data, encoding: .utf8).flatMap { link(in: $0) } }
        if type == .html {
            // Do not invoke the attributed-string HTML importer: it spins up
            // WebKit and requires the main thread just to find a link.
            guard let html = String(data: data, encoding: .utf8),
                  let href = try? NSRegularExpression(pattern: "(?i)href\\s*=\\s*[\"']([^\"']+)[\"']") else { return nil }
            for match in href.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html),
                      let url = URL(string: String(html[range]).replacingOccurrences(of: "&amp;", with: "&")),
                      !url.isFileURL, isSupported(url) else { continue }
                return url
            }
            return link(in: html)
        }
        guard let text = try? NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else { return nil }
        var url: URL?
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            let candidate = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if let candidate, !candidate.isFileURL, isSupported(candidate) {
                url = candidate
                stop.pointee = true
            }
        }
        return url ?? link(in: text.string)
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, isSupported(url) { return url }
        }
        for type in [UTType.fileURL, .url] {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            if let data = await loadData(provider, type: type),
               let url = urlFromData(data), isSupported(url) { return url }
            let url: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                    let url: URL?
                    switch item {
                    case let value as URL: url = value
                    case let value as Data:
                        // Files can encode public.file-url as a binary plist.
                        url = urlFromData(value)
                    case let value as String: url = URL(string: value)
                    default: url = nil
                    }
                    continuation.resume(returning: url)
                }
            }
            if let url, isSupported(url) { return url }
        }
        return nil
    }

    nonisolated private static func urlFromData(_ data: Data) -> URL? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        let strings = (plist as? [Any])?.compactMap { $0 as? String }
            ?? [plist as? String].compactMap { $0 }
        return strings.compactMap(URL.init(string:)).first(where: \.isFileURL)
            ?? URL(dataRepresentation: data, relativeTo: nil)
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func copyPDF(_ provider: NSItemProvider) async throws -> URL {
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    // The provider deletes its URL when this callback returns.
                    // Keep our own copy, off-main, before resuming the open.
                    #if os(iOS)
                    let root = DocumentImport.libraryDirectory
                    #else
                    let root = TestEnvironment.storageRoot.map { $0.appendingPathComponent("Documents") }
                        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent(RuntimeProfile.current.localStorageDirectoryName)
                            .appendingPathComponent("Documents")
                    #endif
                    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var filename = ((name ?? url.lastPathComponent) as NSString).lastPathComponent
                    if filename.isEmpty { filename = "Dropped PDF" }
                    if (filename as NSString).pathExtension.lowercased() != "pdf" { filename += ".pdf" }
                    let destination = directory.appendingPathComponent(filename)
                    do { try FileManager.default.copyItem(at: url, to: destination) }
                    catch {
                        try? FileManager.default.removeItem(at: directory)
                        throw error
                    }
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct HomeDropModifier: ViewModifier {
    @Environment(AppStore.self) private var app
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var targeted = false
    var enabled = true
    var onOpened: () -> Void = {}

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .overlay {
                HomeDropCatcher(enabled: enabled, onTargeted: { targeted = $0 }, onDrop: receive)
            }
            #else
            .contentShape(Rectangle())
            .onDrop(of: HomeDrop.types, isTargeted: $targeted, perform: receive)
            #endif
            .overlay {
                if targeted && enabled {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard enabled, workspace.draggingTab == nil else { return false }
        let accepted = providers.filter(HomeDrop.accepts)
        guard !accepted.isEmpty else { return false }
        workspace.openHomeDrop(accepted, in: app, onOpened: onOpened)
        return true
    }
}

extension View {
    func homeDrop(enabled: Bool = true, onOpened: @escaping () -> Void = {}) -> some View {
        modifier(HomeDropModifier(enabled: enabled, onOpened: onOpened))
    }
}
