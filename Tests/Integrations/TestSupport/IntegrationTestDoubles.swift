import CoreGraphics
import CryptoKit
import Foundation
@testable import Vellum

actor InMemoryIntegrationCredentials: IntegrationCredentials {
    private var values: [IntegrationProvider: String]
    private let setSucceeds: Bool
    private let deleteSucceeds: Bool

    init(_ values: [IntegrationProvider: String] = [:], setSucceeds: Bool = true, deleteSucceeds: Bool = true) {
        self.values = values
        self.setSucceeds = setSucceeds
        self.deleteSucceeds = deleteSucceeds
    }

    func credential(for provider: IntegrationProvider) async -> String? { values[provider] }
    func setCredential(_ credential: String, for provider: IntegrationProvider) async -> Bool { guard setSucceeds else { return false }; values[provider] = credential; return true }
    func deleteCredential(for provider: IntegrationProvider) async -> Bool { guard deleteSucceeds else { return false }; values[provider] = nil; return true }
}

struct NoWaitIntegrationSleeper: IntegrationSleeper {
    func sleep(for duration: Duration) async throws {}
}

actor RecordingIntegrationSleeper: IntegrationSleeper {
    private var recordedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        recordedDurations.append(duration)
    }

    func durations() -> [Duration] { recordedDurations }
}

actor IntegrationTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

actor IntegrationSnapshotRecorder {
    private var values: [ProviderSnapshot] = []
    func record(_ snapshot: ProviderSnapshot) { values.append(snapshot) }
    func snapshots() -> [ProviderSnapshot] { values }
}

struct ReadwisePageCall: Equatable, Sendable {
    let cursor: String?
    let updatedAfter: Date?
    let limit: Int
}

struct IntegrationMoveCall: Equatable, Sendable {
    let itemID: String
    let collectionVendorID: String
}

actor ScriptedReadwiseService: ReadwiseServing {
    private var pages: [IntegrationPage]
    private let terminalError: IntegrationError?
    private let rawSource: URL?
    private let validationError: IntegrationError?
    private let validationStarted: IntegrationTestGate?
    private let validationRelease: IntegrationTestGate?
    private let pageStarted: IntegrationTestGate?
    private let pageRelease: IntegrationTestGate?
    private let moveError: IntegrationError?
    private var recordedPageCalls: [ReadwisePageCall] = []
    private var recordedRawSourceIDs: [String] = []
    private var recordedMoveCalls: [IntegrationMoveCall] = []

    init(
        pages: [IntegrationPage] = [],
        terminalError: IntegrationError? = nil,
        rawSource: URL? = nil,
        validationError: IntegrationError? = nil,
        validationStarted: IntegrationTestGate? = nil,
        validationRelease: IntegrationTestGate? = nil,
        pageStarted: IntegrationTestGate? = nil,
        pageRelease: IntegrationTestGate? = nil,
        moveError: IntegrationError? = nil
    ) {
        self.pages = pages
        self.terminalError = terminalError
        self.rawSource = rawSource
        self.validationError = validationError
        self.validationStarted = validationStarted
        self.validationRelease = validationRelease
        self.pageStarted = pageStarted
        self.pageRelease = pageRelease
        self.moveError = moveError
    }

    func validate(token: String) async throws {
        if let validationStarted { await validationStarted.open() }
        if let validationRelease { await validationRelease.wait() }
        try Task.checkCancellation()
        if let validationError { throw validationError }
    }

    func page(token: String, cursor: String?, updatedAfter: Date?, limit: Int) async throws -> IntegrationPage {
        recordedPageCalls.append(.init(cursor: cursor, updatedAfter: updatedAfter, limit: limit))
        if let pageStarted { await pageStarted.open() }
        if let pageRelease { await pageRelease.wait() }
        guard pages.isEmpty == false else { throw terminalError ?? IntegrationError.invalidResponse }
        return pages.removeFirst()
    }

    func rawSourceURL(token: String, itemID: String) async throws -> URL? {
        recordedRawSourceIDs.append(itemID)
        return rawSource
    }

    func moveItem(token: String, itemID: String, locationVendorID: String) async throws {
        recordedMoveCalls.append(.init(itemID: itemID, collectionVendorID: locationVendorID))
        if let moveError { throw moveError }
    }

    func pageCalls() -> [ReadwisePageCall] { recordedPageCalls }
    func rawSourceIDs() -> [String] { recordedRawSourceIDs }
    func moveCalls() -> [IntegrationMoveCall] { recordedMoveCalls }
}

actor ReconnectReadwiseService: ReadwiseServing {
    private let firstPageStarted: IntegrationTestGate
    private let replacementPage: IntegrationPage
    private var callCount = 0

    init(firstPageStarted: IntegrationTestGate, replacementPage: IntegrationPage) {
        self.firstPageStarted = firstPageStarted
        self.replacementPage = replacementPage
    }

    func validate(token: String) async throws {}

    func page(token: String, cursor: String?, updatedAfter: Date?, limit: Int) async throws -> IntegrationPage {
        callCount += 1
        if callCount == 1 {
            await firstPageStarted.open()
            try await Task.sleep(for: .seconds(60))
            throw IntegrationError.invalidResponse
        }
        return replacementPage
    }

    func rawSourceURL(token: String, itemID: String) async throws -> URL? { nil }
    func moveItem(token: String, itemID: String, locationVendorID: String) async throws {}
}

actor CancellationBlockingReadwiseService: ReadwiseServing {
    private let pageStarted: IntegrationTestGate

    init(pageStarted: IntegrationTestGate) {
        self.pageStarted = pageStarted
    }

    func validate(token: String) async throws {}

    func page(token: String, cursor: String?, updatedAfter: Date?, limit: Int) async throws -> IntegrationPage {
        await pageStarted.open()
        try await Task.sleep(for: .seconds(60))
        throw IntegrationError.invalidResponse
    }

    func rawSourceURL(token: String, itemID: String) async throws -> URL? { nil }
    func moveItem(token: String, itemID: String, locationVendorID: String) async throws {}
}

struct RaindropPageCall: Equatable, Sendable {
    let page: Int
    let perPage: Int
}

actor ScriptedRaindropService: RaindropServing {
    private let collectionValues: [ReadLaterCollection]
    private let collectionError: IntegrationError?
    private var pages: [IntegrationPage]
    private let terminalError: IntegrationError?
    private let moveError: IntegrationError?
    private let pageStarted: IntegrationTestGate?
    private let pageRelease: IntegrationTestGate?
    private let moveStarted: IntegrationTestGate?
    private let moveRelease: IntegrationTestGate?
    private var recordedPageCalls: [RaindropPageCall] = []
    private var recordedMoveCalls: [IntegrationMoveCall] = []
    private var collectionCallCount = 0

    init(
        collections: [ReadLaterCollection] = [],
        collectionError: IntegrationError? = nil,
        pages: [IntegrationPage] = [],
        terminalError: IntegrationError? = nil,
        moveError: IntegrationError? = nil,
        pageStarted: IntegrationTestGate? = nil,
        pageRelease: IntegrationTestGate? = nil,
        moveStarted: IntegrationTestGate? = nil,
        moveRelease: IntegrationTestGate? = nil
    ) {
        self.collectionValues = collections
        self.collectionError = collectionError
        self.pages = pages
        self.terminalError = terminalError
        self.moveError = moveError
        self.pageStarted = pageStarted
        self.pageRelease = pageRelease
        self.moveStarted = moveStarted
        self.moveRelease = moveRelease
    }

    func validate(token: String) async throws {}

    func collections(token: String) async throws -> [ReadLaterCollection] {
        collectionCallCount += 1
        if let collectionError { throw collectionError }
        return collectionValues
    }

    func page(token: String, page: Int, perPage: Int) async throws -> IntegrationPage {
        recordedPageCalls.append(.init(page: page, perPage: perPage))
        if let pageStarted { await pageStarted.open() }
        if let pageRelease { await pageRelease.wait() }
        guard pages.isEmpty == false else { throw terminalError ?? IntegrationError.invalidResponse }
        return pages.removeFirst()
    }

    func moveItem(token: String, itemID: String, collectionVendorID: String) async throws {
        recordedMoveCalls.append(.init(itemID: itemID, collectionVendorID: collectionVendorID))
        if let moveStarted { await moveStarted.open() }
        if let moveRelease { await moveRelease.wait() }
        if let moveError { throw moveError }
    }

    func pageCalls() -> [RaindropPageCall] { recordedPageCalls }
    func moveCalls() -> [IntegrationMoveCall] { recordedMoveCalls }
    func collectionsCalls() -> Int { collectionCallCount }
}

actor RecordingIntegrationDownloader: IntegrationDownloading {
    private let payload: Data
    private let headers: [String: String]
    private var requestedURLs: [URL] = []

    init(payload: Data, headers: [String: String] = [:]) {
        self.payload = payload
        self.headers = headers
    }

    func download(
        _ request: URLRequest,
        to temporaryURL: URL,
        maximumBytes: Int,
        progress: @escaping @Sendable (Double?) async -> Void
    ) async throws -> IntegrationDownloadResult {
        guard let url = request.url else { throw IntegrationError.invalidResponse }
        requestedURLs.append(url)
        guard payload.count <= maximumBytes else { throw IntegrationError.downloadTooLarge }
        try payload.write(to: temporaryURL, options: .atomic)
        await progress(1)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return .init(temporaryURL: temporaryURL, response: response)
    }

    func requests() -> [URL] { requestedURLs }
}

/// Captures requests seen by a StubURLProtocol handler, draining the body
/// stream at record time (URLProtocol exposes bodies only as httpBodyStream).
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(request: URLRequest, body: Data)] = []

    func record(_ request: URLRequest) {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        lock.lock()
        recorded.append((request, data))
        lock.unlock()
    }

    func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.request) }
    func bodies() -> [Data] { lock.lock(); defer { lock.unlock() }; return recorded.map(\.body) }
}

enum IntegrationTemporaryRoot {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum IntegrationTestFixtureError: Error {
    case invalidItem
    case couldNotCreatePDF
    case couldNotCreateUserDefaults
}

func makeIntegrationItem(
    provider: IntegrationProvider,
    id: String,
    updatedAt: Date,
    kind: ReadLaterKind = .article,
    sourceURL: URL? = nil,
    pdfRetrieval: PDFRetrievalStrategy? = nil
) throws -> ReadLaterItem {
    guard let item = ReadLaterItem(
        provider: provider,
        vendorID: id,
        sourceURL: sourceURL ?? URL(string: "https://example.com/\(id)"),
        title: id,
        kind: kind,
        savedAt: updatedAt,
        updatedAt: updatedAt,
        pdfRetrieval: pdfRetrieval
    ) else {
        throw IntegrationTestFixtureError.invalidItem
    }
    return item
}

func integrationPage(
    items: [ReadLaterItem],
    nextCursor: String? = nil,
    skipped: Int = 0,
    responseWasEmpty: Bool = false
) -> IntegrationPage {
    IntegrationPage(
        items: items,
        nextCursor: nextCursor,
        hasMore: nextCursor != nil,
        skippedRecordCount: skipped,
        responseWasEmpty: responseWasEmpty
    )
}

func integrationFingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
}

func makeIntegrationPreferences(suiteName: String) throws -> IntegrationPreferences {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw IntegrationTestFixtureError.couldNotCreateUserDefaults
    }
    return IntegrationPreferences(defaults: defaults)
}

func integrationTestPDFData() throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        throw IntegrationTestFixtureError.couldNotCreatePDF
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw IntegrationTestFixtureError.couldNotCreatePDF
    }
    context.beginPDFPage(nil)
    context.move(to: CGPoint(x: 20, y: 20))
    context.addLine(to: CGPoint(x: 180, y: 180))
    context.strokePath()
    context.endPDFPage()
    context.closePDF()
    return data as Data
}
