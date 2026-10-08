#if os(macOS)
import PDFKit
import PencilKit
import SwiftUI

/// Read-only inspector navigation. Ink stays in its PDF /Ink entries or web
/// sidecar; these rows never enter AnnotationStore or acquire persistence tasks.
struct MacHandwritingNavigator: View {
    @Environment(AppStore.self) private var app
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette

    private struct LoadID: Equatable {
        let binding: DocumentBinding?
        let generation: Int
        let ready: Bool
        let webInit: Int
        let refresh: Int
    }

    @State private var loadedID: LoadID?
    @State private var pages: [Int] = []
    @State private var clusters: [WebInkRecord.Cluster] = []
    @State private var refresh = 0

    private var runtime: LiveTabRuntime? {
        guard let tabId = app.activeTabId else { return nil }
        return workspace.existingLiveTabRuntime(for: tabId)
    }

    private var loadID: LoadID {
        let ready: Bool
        if let runtime, case .loaded = runtime.pdfLoadState { ready = true }
        else { ready = false }
        return LoadID(
            binding: app.activeDocumentBinding,
            generation: runtime?.documentGeneration ?? 0,
            ready: ready, webInit: runtime?.webController.initCount ?? 0,
            refresh: refresh)
    }

    var body: some View {
        let id = loadID
        VStack(spacing: 0) {
            if loadedID == id, !pages.isEmpty || !clusters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Handwriting")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.mutedForeground)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(pages, id: \.self) { page in
                                jumpButton("p. \(page)", label: "Handwriting on page \(page)") {
                                    guard app.activeDocumentBinding == id.binding else { return }
                                    app.goToPage(page)
                                }
                                .accessibilityIdentifier("handwriting.page.\(page)")
                            }
                            ForEach(clusters.indices, id: \.self) { index in
                                let cluster = clusters[index]
                                jumpButton(
                                    "Location \(index + 1)",
                                    label: "Handwriting location \(index + 1)") {
                                    guard app.activeDocumentBinding == id.binding else { return }
                                    _ = app.scrollToWebInkHandler?(cluster)
                                }
                                .accessibilityIdentifier("handwriting.location.\(index + 1)")
                            }
                        }
                    }
                }
                .padding(12)
                Divider()
            }
        }
        .task(id: id) { await load(id) }
        .onReceive(NotificationCenter.default.publisher(for: .PDFDocumentDidUnlock)
            .receive(on: RunLoop.main)) { notification in
            guard let document = notification.object as? PDFDocument,
                  document === runtime?.pdfController.document else { return }
            refresh += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAnnotationsUpdated)
            .receive(on: RunLoop.main)) { _ in refresh += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .vellumDocumentSidecarImported)
            .receive(on: RunLoop.main)) { notification in
            guard notification.userInfo?["key"] as? String == app.activeDocumentBinding?.storageKey
            else { return }
            refresh += 1
        }
    }

    private func jumpButton(
        _ title: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: "pencil.and.scribble")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.foreground)
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .background(palette.muted, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help("Jump to " + label.lowercased())
    }

    @MainActor
    private func load(_ id: LoadID) async {
        guard let binding = id.binding, let document = app.document,
              app.activeDocumentBinding == binding else { return }
        do {
            let foundPages: [Int]
            let foundClusters: [WebInkRecord.Cluster]
            if document.kind == .pdf {
                guard id.ready, let runtime, let data = runtime.preparedSourceData,
                      let viewerDocument = runtime.pdfController.document else { return }
                let password = (viewerDocument as? PdfViewerDocument)?.privateCopyPassword
                let worker = Task.detached(priority: .utility) {
                    try SavedHandwritingReader.pdfPages(data: data, password: password)
                }
                foundPages = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                foundClusters = []
            } else {
                let url = document.pdfPath
                let worker = Task.detached(priority: .utility) {
                    SavedHandwritingReader.webClusters(url: url)
                }
                foundClusters = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                foundPages = []
            }
            guard !Task.isCancelled, app.activeDocumentBinding == binding, loadID == id
            else { return }
            pages = foundPages
            clusters = foundClusters
            loadedID = id
        } catch {
            guard !Task.isCancelled, app.activeDocumentBinding == binding, loadID == id
            else { return }
            pages = []
            clusters = []
            loadedID = id
        }
    }
}

private enum SavedHandwritingReader {
    /// This private reader owns its PDF exclusively off-main. It uses the
    /// display snapshot and unlock credential, never the PDFView's PDFPage.
    static func pdfPages(data: Data, password: String?) throws -> [Int] {
        let document = try PdfViewerPreparation.privateDocument(data: data, password: password)
        guard let raw = document.documentRef, raw.numberOfPages > 0 else { return [] }
        var pages: [Int] = []
        for page in 1...raw.numberOfPages {
            try Task.checkCancellation()
            guard let dictionary = raw.page(at: page)?.dictionary,
                  let entries = CgPdf.array(dictionary, "Annots") else { continue }
            for index in 0..<CgPdf.count(entries) {
                guard let annotation = CgPdf.dictionaryAt(entries, index),
                      CgPdf.name(annotation, "Subtype") == "Ink" else { continue }
                pages.append(page)
                break
            }
        }
        return pages
    }

    /// Same read-only storage/ownership validation as the saved-ink renderer. Decode locally to
    /// avoid listing corrupt/empty drawings that the Mac renderer cannot show.
    static func webClusters(url: String) -> [WebInkRecord.Cluster] {
        guard !Task.isCancelled,
              let record = WebInkStore.loadRecord(forKey: WebLibrary.pageKey(url)),
              (1...WebInkRecord.currentVersion).contains(record.version),
              (try? WebUrl.normalize(record.url)) == url else { return [] }
        return record.clusters.compactMap { cluster -> WebInkRecord.Cluster? in
            guard !Task.isCancelled else { return nil }
            let bounds = cluster.bounds
            guard bounds.x.isFinite, bounds.y.isFinite,
                  bounds.w.isFinite, bounds.h.isFinite,
                  bounds.w > 0, bounds.h > 0,
                  let drawing = try? PKDrawing(data: cluster.drawing),
                  !drawing.strokes.isEmpty else { return nil }
            var result = cluster
            if let anchor = result.anchor,
               anchor.startOffset < 0 || anchor.startOffset == Int.max || !anchor.rect.y.isFinite {
                result.anchor = nil
            }
            return result
        }.sorted { ($0.bounds.y, $0.bounds.x) < ($1.bounds.y, $1.bounds.x) }
    }
}
#endif
