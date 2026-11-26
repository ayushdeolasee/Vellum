import Foundation
import PencilKit
import VellumCore

// Apple Pencil ink uses a separate `<key>.ink.json` sidecar so page
// annotation edits and drawing snapshots do not replace each other's data.
//
// Everything persisted is normalized to zoom-1 CSS-pixel document space
// (decision 3). Clusters are DERIVED data: at save time strokes are grouped
// from the single live PKDrawing (MVP: one cluster, null anchor); at load time
// cluster drawings are translated back to their document origin and merged
// into one drawing. The format does not change when Phase 3's text anchors
// land — anchors just stop being null.

/// The `<key>.ink.json` sidecar contents. Snake_case JSON, platform-neutral.
struct WebInkRecord: Codable, Equatable, Sendable {
    var unknownFields: [String: JSONValue] = [:]

    /// Version 3 captures only a completed, generation-matched Pencil drawing
    /// against a generation-matched DOM layout. Version 2 added line-aware
    /// clusters and horizontal-span scoring, but an in-flight capture could
    /// still finish after either the stroke or a toolbar-zoom reflow changed;
    /// those anchors are recaptured once on load.
    static let currentVersion = 3

    /// Layout fingerprint captured at draw time (MVP reflow strategy,
    /// decision 8): ink is known-correct when the current layout width matches;
    /// a mismatch still renders best-effort.
    struct Layout: Codable, Equatable, Sendable {
        var unknownFields: [String: JSONValue] = [:]

        /// Document content width in zoom-1 CSS px.
        var contentWidth: Double
        /// Full document height in zoom-1 CSS px.
        var docHeight: Double

        enum CodingKeys: String, CodingKey {
            case contentWidth = "content_width"
            case docHeight = "doc_height"
        }
    }

    /// A rectangle in zoom-1 CSS-pixel document space.
    struct Bounds: Codable, Equatable, Sendable {
        var unknownFields: [String: JSONValue] = [:]

        var x: Double
        var y: Double
        var w: Double
        var h: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            w = rect.width
            h = rect.height
        }

        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    /// Phase 3 text anchor: the same shape as a highlight anchor (raw offset
    /// span + quoted text + prefix/suffix context, so `resolveHighlight`'s
    /// scored fuzzy search can re-find it after content changes) plus the
    /// anchor's document rect at capture time — the reference point clusters
    /// are translated against after reflow. `text`/`endOffset` are optional on
    /// decode for forward compatibility; without them re-resolution degrades
    /// to raw-offset validation, which still survives pure layout reflow.
    struct Anchor: Codable, Equatable, Sendable {
        var unknownFields: [String: JSONValue] = [:]

        var startOffset: Int
        var endOffset: Int?
        var text: String?
        var prefix: String?
        var suffix: String?
        var rect: Bounds
        /// Virtual page (~3600-char chunk) the anchored text sits on, captured
        /// from the live layout when the anchor was made. A display hint for the
        /// sidebar "Handwriting" jump list — derived from `start_offset`, so
        /// it is recomputed, not authoritative; optional for forward/backward
        /// compatibility.
        var page: Int? = nil

        enum CodingKeys: String, CodingKey {
            case startOffset = "start_offset"
            case endOffset = "end_offset"
            case text
            case prefix
            case suffix
            case rect
            case page
        }
    }

    /// One spatial group of strokes. `drawing` is a serialized PKDrawing in
    /// zoom-1 CSS px with a CLUSTER-LOCAL origin (translated so `bounds.origin`
    /// maps to (0,0)) — Phase 3 re-anchoring translates whole clusters without
    /// rewriting stroke data.
    struct Cluster: Equatable, Sendable {
        var unknownFields: [String: JSONValue] = [:]

        /// STABLE, content-derived identity (see `WebInkRecord.clusterId`), NOT
        /// a per-save random UUID: two independently-written copies of the same
        /// page's ink must land on the same ids so `mergeInk`/`adoptInkFile`'s
        /// newer-wins merge-by-id can match them. A fresh UUID per save would
        /// make every id set disjoint, turning every merge into a blind union
        /// that doubles the ink.
        var id: String
        /// Base64 in JSON (Data's default Codable representation).
        var drawing: Data?
        var strokes: [PortableStroke]? = nil
        var bounds: Bounds
        var anchor: Anchor?
    }

    var version: Int
    var url: String
    var updatedAt: String
    var layout: Layout
    var clusters: [Cluster]

    enum CodingKeys: String, CodingKey {
        case version
        case url
        case updatedAt = "updated_at"
        case layout
        case clusters
    }
}

extension WebInkRecord.Cluster: Codable {
    enum CodingKeys: String, CodingKey {
        case id, drawing, strokes, bounds, anchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        drawing = try container.decodeIfPresent(Data.self, forKey: .drawing)
        strokes = try container.decodeIfPresent([PortableStroke].self, forKey: .strokes)
        guard drawing != nil || strokes != nil else {
            throw DecodingError.dataCorruptedError(forKey: .strokes, in: container,
                debugDescription: "An ink cluster requires drawing or strokes")
        }
        bounds = try container.decode(WebInkRecord.Bounds.self, forKey: .bounds)
        anchor = try container.decodeIfPresent(WebInkRecord.Anchor.self, forKey: .anchor)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    /// Custom encode so an MVP cluster writes an explicit `"anchor": null`
    /// (the documented format) instead of omitting the key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(drawing, forKey: .drawing)
        try container.encodeIfPresent(strokes, forKey: .strokes)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
        try container.encode(bounds, forKey: .bounds)
        if let anchor {
            try container.encode(anchor, forKey: .anchor)
        } else {
            try container.encodeNil(forKey: .anchor)
        }
    }
}

extension WebInkRecord {
    /// Deterministic, content-derived cluster identity so two independently-
    /// written copies of the SAME page's ink share ids and the newer-wins
    /// merge-by-id in `WebArchive.mergeInk` / `WebInkStore.adoptInkFile` can
    /// actually match them (a fresh per-save `UUID()` made every id set
    /// disjoint, so every merge blindly unioned and doubled the ink).
    ///
    /// - Anchored clusters key off their text-quote span
    ///   (`start_offset`/`end_offset`): stable across reflow AND across devices
    ///   viewing the same content, the exact property the highlight system
    ///   relies on. Two saves of the same note produce the same id even after
    ///   the paragraph moved.
    /// - Unanchored clusters (pure MVP, or the brief window before a stroke's
    ///   anchor capture lands) key off their quantized document bounds — which
    ///   don't move without an anchor to translate them, so the id is stable
    ///   across saves at a fixed layout.
    static func clusterId(anchor: Anchor?, bounds: CGRect) -> String {
        if let anchor {
            return "a:\(anchor.startOffset):\(anchor.endOffset ?? -1)"
        }
        let x = Int(bounds.minX.rounded())
        let y = Int(bounds.minY.rounded())
        let w = Int(bounds.width.rounded())
        let h = Int(bounds.height.rounded())
        return "b:\(x):\(y):\(w):\(h)"
    }

    /// Snapshot the live drawing (already normalized to zoom-1 CSS-pixel
    /// document space) into a record: strokes are grouped into spatial
    /// proximity clusters (Phase 3, decision 8) and `anchorFor` supplies each
    /// cluster's text anchor from its document bounds (nil = not yet
    /// anchored — the anchor capture is async and the next snapshot fills it
    /// in). Cluster ids are derived deterministically from that anchor (or the
    /// bounds when unanchored) via `clusterId`, never a per-save UUID, so the
    /// merge-by-id paths stay sound. An empty drawing produces zero clusters
    /// (the record still writes, so erasing everything durably clears the
    /// sidecar).
    static func snapshot(
        of drawing: PKDrawing,
        url: String,
        layout: Layout,
        anchorFor: (CGRect) -> Anchor? = { _ in nil }
    ) -> WebInkRecord {
        let clusters = WebInkClustering.clusters(of: drawing).map { cluster -> Cluster in
            let local = cluster.drawing.transformed(using: CGAffineTransform(
                translationX: -cluster.bounds.origin.x, y: -cluster.bounds.origin.y))
            let anchor = anchorFor(cluster.bounds)
            return Cluster(
                id: clusterId(anchor: anchor, bounds: cluster.bounds),
                drawing: local.dataRepresentation(),
                bounds: Bounds(cluster.bounds),
                anchor: anchor)
        }
        return WebInkRecord(
            version: currentVersion,
            url: url,
            updatedAt: WebLibrary.rfc3339Now(),
            layout: layout,
            clusters: clusters)
    }

    func validatedMergedDrawing() throws -> PKDrawing {
        guard (1...Self.currentVersion).contains(version) else {
            throw SessionServiceError.invalidDocument("This page's ink version is not supported")
        }
        return try clusters.reduce(PKDrawing()) { result, cluster in
            try result.appending(cluster.documentDrawing())
        }
    }
}

extension WebInkRecord.Cluster {
    /// A dual record retains its native drawing as Apple's source of truth.
    func localDrawing() throws -> PKDrawing {
        let portable = try strokes.map { try PKDrawing(portableStrokes: $0) }
        if let drawing {
            let native = try PKDrawing(data: drawing)
            guard !native.strokes.isEmpty,
                  portable == nil || native.strokes.count == portable?.strokes.count else {
                throw SessionServiceError.invalidDocument("Invalid ink cluster drawing")
            }
            return native
        }
        guard let portable else { throw SessionServiceError.invalidDocument("Missing ink cluster data") }
        return portable
    }

    func documentDrawing() throws -> PKDrawing {
        try localDrawing().transformed(using: CGAffineTransform(translationX: bounds.x, y: bounds.y))
    }
}

// MARK: - Anchor bridge payloads (content-script round trips)

/// One ink cluster's anchor-capture request: the cluster's full bounding band
/// in zoom-1 CSS-px document space. `y` is the band top (also the sample point
/// old cached content scripts use); `bottom` lets current scripts distinguish
/// an underline from a circle/strike, while `left`/`right` disambiguate two
/// adjacent text lines when the stroke straddles their shared boundary.
struct WebInkAnchorPoint: Sendable {
    var id: String
    var x: Double
    var y: Double
    var bottom: Double
    var left: Double
    var right: Double
}

/// One stored anchor queued for batch re-resolution against the current DOM.
struct WebInkAnchorQuery: Sendable {
    var id: String
    var anchor: WebInkRecord.Anchor
}

// MARK: - Paths + file I/O

/// Path resolution and atomic reads/writes for the ink sidecar. Mirrors the
/// `WebLibrary` record path rules so the sidecar follows the user's storage
/// location (local / iCloud / custom): it lives in the active layout's records
/// dir, with the legacy local store as a read fallback for files a storage
/// migration sweep has not moved yet. Everything resolves per operation — a
/// mid-session storage switch redirects the very next write instead of
/// resurrecting the old location.
enum WebInkStore {
    static func inkPath(forKey key: String) -> URL {
        WebLibrary.activeLayout.recordsDir.appendingPathComponent("\(key).ink.json")
    }

    /// Every place the ink sidecar for `key` may live, primary first (same
    /// contract as `WebLibrary.candidateRecordPaths`).
    static func candidateInkPaths(forKey key: String) -> [URL] {
        var paths = [inkPath(forKey: key)]
        let legacy = WebLibrary.storeDir.appendingPathComponent("\(key).ink.json")
        if legacy != paths[0] { paths.append(legacy) }
        return paths
    }

    /// Load the ink record wherever it currently lives, downloading an evicted
    /// iCloud copy if needed (blocking; call off the main thread — `WebInkIO`
    /// is the production caller).
    static func loadRecord(forKey key: String, timeout: TimeInterval = 10) -> WebInkRecord? {
        for path in candidateInkPaths(forKey: key) {
            _ = WebICloud.materialize(at: path, timeout: timeout)
            if FileManager.default.fileExists(atPath: path.path) { return loadRecord(at: path) }
        }
        return nil
    }

    static func loadRecord(at path: URL) -> WebInkRecord? {
        try? readRecord(at: path)
    }

    private static func readRecord(at path: URL) throws -> WebInkRecord {
        let record = try JSONDecoder().decode(WebInkRecord.self, from: Data(contentsOf: path))
        _ = try record.validatedMergedDrawing()
        return record
    }

    /// Strict loader for an explicit export. A genuinely absent sidecar means
    /// "this page has no ink"; an iCloud placeholder that cannot materialize,
    /// unreadable bytes, invalid JSON, or a damaged PencilKit cluster is an
    /// export error rather than permission to emit an archive with no ink.
    static func loadRecordForExport(forKey key: String, timeout: TimeInterval = 10) throws -> WebInkRecord? {
        for path in candidateInkPaths(forKey: key) {
            let placeholder = WebICloud.placeholderURL(for: path)
            let exists = FileManager.default.fileExists(atPath: path.path)
                || FileManager.default.fileExists(atPath: placeholder.path)
            guard exists else { continue }
            guard WebICloud.materialize(at: path, timeout: timeout) else {
                throw SessionServiceError.io(
                    "This page's ink is in iCloud but hasn't downloaded yet — check your connection and try again")
            }
            let data: Data
            do {
                data = try Data(contentsOf: path)
            } catch {
                throw SessionServiceError.io(
                    "Failed to read this page's ink: \(error.localizedDescription)")
            }
            let record: WebInkRecord
            do {
                record = try JSONDecoder().decode(WebInkRecord.self, from: data)
            } catch {
                throw SessionServiceError.invalidDocument(
                    "This page's ink record is damaged: \(error.localizedDescription)")
            }
            _ = try record.validatedMergedDrawing()
            return record
        }
        return nil
    }

    /// Atomic tmp→rename write to the active layout's ink path, serialized per
    /// path through the shared `WebLibrary` lock registry so two sessions on
    /// the same page can never interleave ink writes (decision 6).
    static func saveRecord(_ record: WebInkRecord, forKey key: String) throws {
        let path = inkPath(forKey: key)
        let lock = WebLibrary.recordLock(for: path)
        lock.lock()
        defer { lock.unlock() }
        if !WebICloud.materialize(at: path),
           FileManager.default.fileExists(atPath: WebICloud.placeholderURL(for: path).path) {
            // Same refusal rule as WebLibrary.withRecord: the sidecar exists in
            // iCloud but its bytes couldn't download — a full-replace write here
            // would overwrite ink made on another device once iCloud reconnects.
            throw SessionServiceError.io(
                "This page's ink is in iCloud but hasn't downloaded yet — check your connection and try again")
        }
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to create web store dir: \(error.localizedDescription)")
        }
        var record = record
        if FileManager.default.fileExists(atPath: path.path) {
            let previous = try readRecord(at: path)
            carryUnknownFields(into: &record, from: [previous], reclustered: true)
        }
        let json: Data
        do {
            json = try WebLibrary.jsonEncoderPretty.encode(record)
        } catch {
            throw SessionServiceError.io("Failed to serialize web ink record: \(error.localizedDescription)")
        }
        let tmp = path.appendingPathExtension("tmp")
        do {
            try json.write(to: tmp)
        } catch {
            throw SessionServiceError.io("Failed to write web ink record: \(error.localizedDescription)")
        }
        guard rename(tmp.path, path.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to commit web ink record: rename failed")
        }
    }

    /// Atomic tmp→rename write to an explicit path, without the layout
    /// resolution or the per-path lock (callers that already hold the lock —
    /// `adoptInkFile` — use this).
    static func writeRecord(_ record: WebInkRecord, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = try WebLibrary.jsonEncoderPretty.encode(record)
        let tmp = path.appendingPathExtension("tmp")
        try json.write(to: tmp)
        guard rename(tmp.path, path.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to commit web ink record: rename failed")
        }
    }

    /// Apply one runtime's full canvas snapshot without treating it as a blind
    /// replacement of every other runtime's state. `baseline` is the last full
    /// snapshot that THIS runtime loaded or durably wrote. The difference from
    /// baseline → incoming is the runtime's intent: missing observed strokes
    /// are deletions, new strokes are additions, and unchanged strokes are
    /// ignored. Applying that delta to the latest file preserves another
    /// runtime's concurrent additions and does not resurrect strokes it erased.
    ///
    /// The complete read-modify-write holds every candidate sidecar path lock,
    /// so two `WebInkIO` actors for the same normalized URL serialize here even
    /// though they belong to different `LiveTabRuntime`s.
    static func applySnapshot(
        _ incoming: WebInkRecord,
        replacing baseline: WebInkRecord?,
        forKey key: String
    ) throws -> WebInkRecord {
        try withLockedCandidateRecords(forKey: key) { destination, current in
            _ = try incoming.validatedMergedDrawing()
            let result = try current.map {
                try coordinatedSnapshot(current: $0, baseline: baseline, incoming: incoming)
            } ?? incoming
            try writeRecord(result, to: destination)
            return result
        }
    }

    /// Observed-remove merge at STROKE granularity. Cluster-level replacement
    /// is insufficient because two runtimes can concurrently add different
    /// strokes near the same paragraph and therefore produce the same cluster
    /// id. A stroke is matched by PencilKit's persisted path creation date plus
    /// its original control-point geometry. Its mutable rendering state
    /// (transform, ink, and eraser mask) is compared separately, so erasing or
    /// moving a stroke is an update rather than a new stroke. Do not use
    /// `PKDrawing.dataRepresentation()` as identity: PencilKit's archive bytes
    /// are not canonical and change after an encode/decode round-trip.
    private static func coordinatedSnapshot(
        current: WebInkRecord,
        baseline: WebInkRecord?,
        incoming: WebInkRecord
    ) throws -> WebInkRecord {
        let currentStrokes = try current.validatedMergedDrawing().strokes
        let baselineStrokes = try baseline?.validatedMergedDrawing().strokes ?? []
        let incomingStrokes = try incoming.validatedMergedDrawing().strokes
        let baselineById = Dictionary(
            baselineStrokes.map { (strokeIdentity($0), $0) }, uniquingKeysWith: { _, newest in newest })
        let incomingById = Dictionary(
            incomingStrokes.map { (strokeIdentity($0), $0) }, uniquingKeysWith: { _, newest in newest })

        var resultStrokes = currentStrokes
        for (id, baselineStroke) in baselineById {
            guard let incomingStroke = incomingById[id] else {
                // This runtime observed the stroke and then removed it.
                resultStrokes.removeAll { strokeIdentity($0) == id }
                continue
            }
            guard strokeSignature(incomingStroke) != strokeSignature(baselineStroke) else {
                // Unchanged observed content is not an addition, so a stale
                // runtime cannot resurrect a stroke another runtime removed.
                continue
            }
            // Eraser masks, ink changes, and re-anchor translations replace
            // the version this runtime observed while preserving list order.
            if let index = resultStrokes.firstIndex(where: { strokeIdentity($0) == id }) {
                resultStrokes[index] = incomingStroke
            } else {
                resultStrokes.append(incomingStroke)
            }
        }
        for incomingStroke in incomingStrokes {
            let id = strokeIdentity(incomingStroke)
            guard baselineById[id] == nil,
                  resultStrokes.contains(where: { strokeIdentity($0) == id }) == false else { continue }
            resultStrokes.append(incomingStroke)
        }

        var result = try mergedSnapshot(strokes: resultStrokes, metadata: incoming,
                                        sources: [current, incoming], anchors: incoming.clusters + current.clusters)
        result.updatedAt = WebLibrary.rfc3339Now()
        return result
    }

    /// Snapshotting rebuilds bounds and can change a cluster's derived id.
    /// Carry extras only onto surviving clusters, by id or shared stroke.
    /// Source order defines precedence when two old clusters coalesce.
    static func carryUnknownFields(
        into result: inout WebInkRecord, from sources: [WebInkRecord], reclustered: Bool = false
    ) {
        for source in sources.reversed() {
            result.unknownFields.merge(source.unknownFields) { _, previous in previous }
            result.layout.unknownFields.merge(source.layout.unknownFields) { _, previous in previous }
            let annotated = source.clusters.filter {
                !$0.unknownFields.isEmpty || !$0.bounds.unknownFields.isEmpty
                    || $0.anchor?.unknownFields.isEmpty == false || $0.anchor?.rect.unknownFields.isEmpty == false
            }
            guard !annotated.isEmpty else { continue }
            let byID = Dictionary(grouping: annotated, by: \.id)
            // Stable stroke identity also handles a changed id or coalesced clusters.
            var byStroke: [StrokeIdentity: [Int]] = [:]
            if reclustered {
                for (index, cluster) in annotated.enumerated() {
                    for id in strokeIDs(in: cluster) { byStroke[id, default: []].append(index) }
                }
            }
            for index in result.clusters.indices {
                let cluster = result.clusters[index]
                let sameID = byID[cluster.id] ?? []
                var matches = sameID
                if !byStroke.isEmpty {
                    let shared = Set(strokeIDs(in: cluster).flatMap { byStroke[$0] ?? [] })
                    matches += shared.sorted().map { annotated[$0] }.filter { $0.id != cluster.id }
                }
                for old in matches.reversed() {
                    result.clusters[index].unknownFields.merge(old.unknownFields) { _, previous in previous }
                    result.clusters[index].bounds.unknownFields.merge(old.bounds.unknownFields) { _, previous in previous }
                    if let anchor = old.anchor {
                        result.clusters[index].anchor?.unknownFields.merge(anchor.unknownFields) { _, previous in previous }
                        result.clusters[index].anchor?.rect.unknownFields.merge(anchor.rect.unknownFields) { _, previous in previous }
                    }
                }
            }
        }
    }

    private static func strokeIDs(in cluster: WebInkRecord.Cluster) -> [StrokeIdentity] {
        (try? cluster.documentDrawing().strokes.map(strokeIdentity)) ?? []
    }

    /// Relocation keeps the newest whole canvas, including its deletions.
    static func relocationSnapshot(current: WebInkRecord, incoming: WebInkRecord) -> WebInkRecord {
        var result = WebArchive.newerThan(incoming.updatedAt, current.updatedAt) ? incoming : current
        carryUnknownFields(into: &result, from: [current, incoming], reclustered: true)
        return result
    }

    private struct StrokeIdentity: Hashable {
        var creationDate: Date
        var points: [StrokeIdentityPoint]
    }

    private struct StrokeIdentityPoint: Hashable {
        var x: CGFloat
        var y: CGFloat
        var timeOffset: TimeInterval
    }

    private struct StrokeSignature: Equatable {
        var identity: StrokeIdentity
        var transform: CGAffineTransform
        var inkType: String
        var colorComponents: [CGFloat]
        var points: [StrokeSignaturePoint]
        var mask: CGPath?
        var randomSeed: UInt32
        var visibleRanges: [ClosedRange<CGFloat>]
    }

    private struct StrokeSignaturePoint: Equatable {
        var size: CGSize
        var opacity: CGFloat
        var force: CGFloat
        var azimuth: CGFloat
        var altitude: CGFloat
        var secondaryScale: CGFloat
    }

    private static func strokeIdentity(_ stroke: PKStroke) -> StrokeIdentity {
        StrokeIdentity(
            creationDate: stroke.path.creationDate,
            points: stroke.path.map {
                StrokeIdentityPoint(
                    x: $0.location.x, y: $0.location.y, timeOffset: $0.timeOffset)
            })
    }

    private static func strokeSignature(_ stroke: PKStroke) -> StrokeSignature {
        StrokeSignature(
            identity: strokeIdentity(stroke),
            transform: stroke.transform,
            inkType: stroke.ink.inkType.rawValue,
            colorComponents: stroke.ink.color.cgColor.components ?? [],
            points: stroke.path.map {
                StrokeSignaturePoint(
                    size: $0.size, opacity: $0.opacity, force: $0.force,
                    azimuth: $0.azimuth, altitude: $0.altitude,
                    secondaryScale: $0.secondaryScale)
            },
            mask: stroke.mask?.cgPath, randomSeed: stroke.randomSeed,
            visibleRanges: stroke.maskedPathRanges)
    }

    /// Additive archive merge at stable stroke identity, then derive clusters
    /// again. Cluster ids are layout/anchor metadata and may legitimately
    /// change when a once-unanchored stroke gains a text anchor, so using them
    /// as content identity can duplicate or replace the user's ink.
    static func additivelyMerged(
        current: WebInkRecord, incoming: WebInkRecord
    ) throws -> WebInkRecord {
        var strokes = try current.validatedMergedDrawing().strokes
        let incomingStrokes = try incoming.validatedMergedDrawing().strokes
        var indices = Dictionary(
            strokes.enumerated().map { (strokeIdentity($0.element), $0.offset) },
            uniquingKeysWith: { _, newest in newest })
        let incomingNewer = WebArchive.newerThan(incoming.updatedAt, current.updatedAt)
        for stroke in incomingStrokes {
            let id = strokeIdentity(stroke)
            if let index = indices[id] {
                if incomingNewer, strokeSignature(strokes[index]) != strokeSignature(stroke) {
                    strokes[index] = stroke
                }
            } else {
                indices[id] = strokes.count
                strokes.append(stroke)
            }
        }

        let metadata = incomingNewer ? incoming : current
        let other = incomingNewer ? current : incoming
        var result = try mergedSnapshot(strokes: strokes, metadata: metadata,
                                        sources: [metadata, other], anchors: metadata.clusters + other.clusters)
        result.version = min(current.version, incoming.version)
        result.updatedAt = metadata.updatedAt
        return result
    }

    /// Keep existing portable records separate from native additions, even when
    /// the canvas groups both under the same text anchor. A portable array must
    /// describe its entire cluster, and new strokes still use drawing only.
    private static func mergedSnapshot(
        strokes: [PKStroke], metadata: WebInkRecord, sources: [WebInkRecord], anchors: [WebInkRecord.Cluster]
    ) throws -> WebInkRecord {
        let originals = sources.flatMap(\.clusters)
        var originalStrokes: [[PKStroke]] = []
        var portableSource: [StrokeIdentity: Int] = [:]
        var nativeSource: [StrokeIdentity: Int] = [:]
        for (index, cluster) in originals.enumerated() {
            let documentStrokes = try cluster.documentDrawing().strokes
            originalStrokes.append(documentStrokes)
            for stroke in documentStrokes {
                let id = strokeIdentity(stroke)
                if cluster.strokes != nil {
                    if portableSource[id] == nil { portableSource[id] = index }
                } else if nativeSource[id] == nil {
                    nativeSource[id] = index
                }
            }
        }

        var result = metadata
        result.clusters = []
        for spatial in WebInkClustering.clusters(of: PKDrawing(strokes: strokes)) {
            let members = spatial.drawing.strokes
            var start = 0
            while start < members.count {
                let source = portableSource[strokeIdentity(members[start])]
                var end = start + 1
                while end < members.count, portableSource[strokeIdentity(members[end])] == source { end += 1 }
                let group = Array(members[start..<end])
                let drawing = PKDrawing(strokes: group)
                let bounds = drawing.bounds
                let anchor = anchors.compactMap { cluster -> (CGFloat, WebInkRecord.Anchor)? in
                    guard let anchor = cluster.anchor else { return nil }
                    let overlap = bounds.intersection(cluster.bounds.rect)
                    return overlap.isNull ? nil : (overlap.width * overlap.height, anchor)
                }.max { $0.0 < $1.0 }?.1
                let candidate = source ?? nativeSource[strokeIdentity(group[0])]
                // Retain the exact original bytes and local coordinate system
                // when the complete source cluster survived.
                if let candidate, group.map(strokeSignature) == originalStrokes[candidate].map(strokeSignature) {
                    var cluster = originals[candidate]
                    if cluster.anchor != anchor {
                        cluster.anchor = anchor
                        cluster.id = WebInkRecord.clusterId(anchor: anchor, bounds: cluster.bounds.rect)
                    }
                    result.clusters.append(cluster)
                } else {
                    let local = drawing.transformed(using: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                    var cluster = WebInkRecord.Cluster(id: WebInkRecord.clusterId(anchor: anchor, bounds: bounds),
                        drawing: local.dataRepresentation(), bounds: .init(bounds), anchor: anchor)
                    if let source, let stored = originals[source].strokes {
                        let old = originals[source]
                        let indices = Dictionary(originalStrokes[source].enumerated().map {
                            (strokeIdentity($0.element), $0.offset)
                        }, uniquingKeysWith: { first, _ in first })
                        cluster.strokes = try zip(group, local.strokes).map { documentStroke, localStroke in
                            guard let i = indices[strokeIdentity(documentStroke)] else {
                                throw SessionServiceError.invalidDocument("Missing original ink stroke")
                            }
                            var wire = stored[i]
                            if strokeSignature(documentStroke) == strokeSignature(originalStrokes[source][i]) {
                                // Only the local origin changed when the cluster split.
                                wire.transform[4] += old.bounds.x - bounds.minX
                                wire.transform[5] += old.bounds.y - bounds.minY
                            } else {
                                var edited = try PortableStroke(localStroke)
                                edited.id = wire.id
                                edited.unknownFields = wire.unknownFields
                                guard edited.points.count == wire.points.count else {
                                    throw SessionServiceError.invalidDocument("Inconsistent dual ink paths")
                                }
                                for p in edited.points.indices {
                                    edited.points[p].unknownFields = wire.points[p].unknownFields
                                }
                                edited.mask?.unknownFields = wire.mask?.unknownFields ?? [:]
                                wire = edited
                            }
                            return wire
                        }
                        if old.drawing == nil { cluster.drawing = nil }
                    }
                    result.clusters.append(cluster)
                }
                start = end
            }
        }
        carryUnknownFields(into: &result, from: sources, reclustered: true)
        return result
    }

    /// Archive import intentionally remains additive, but its whole
    /// load/merge/save cycle uses the same per-path locks as live snapshots.
    /// This prevents a runtime write from landing between the import's read and
    /// write and being silently overwritten.
    static func mergeImportedRecord(
        _ incoming: WebInkRecord,
        normalizedURL: String,
        forKey key: String
    ) throws {
        try withLockedCandidateRecords(forKey: key) { destination, current in
            var merged = current
            try WebArchive.mergeInk(&merged, incoming: incoming)
            guard var merged else { return }
            merged.url = normalizedURL
            try writeRecord(merged, to: destination)
        }
    }

    /// Resolve and lock the active + legacy candidates in stable path order.
    /// Refuse the mutation when any candidate is an unavailable iCloud
    /// placeholder: treating it as absent would lose that copy when sync
    /// resumes.
    private static func withLockedCandidateRecords<Result>(
        forKey key: String,
        _ body: (URL, WebInkRecord?) throws -> Result
    ) throws -> Result {
        let candidates = candidateInkPaths(forKey: key)
        let paths = Dictionary(grouping: candidates, by: \.path)
            .compactMap { $0.value.first }
            .sorted { $0.path < $1.path }
        let locks = paths.map { WebLibrary.recordLock(for: $0) }
        for lock in locks { lock.lock() }
        defer { for lock in locks.reversed() { lock.unlock() } }

        for path in paths {
            if !WebICloud.materialize(at: path),
               FileManager.default.fileExists(atPath: WebICloud.placeholderURL(for: path).path) {
                throw SessionServiceError.io(
                    "This page's ink is in iCloud but hasn't downloaded yet — check your connection and try again")
            }
        }

        let destination = candidates[0]
        let current = try candidates.first { FileManager.default.fileExists(atPath: $0.path) }.map(readRecord(at:))
        return try body(destination, current)
    }

    // MARK: - Storage relocation (WebStorageMigrator)

    /// Ink-sidecar filenames in a directory — including ones iCloud has evicted
    /// to a `.<name>.icloud` placeholder, reported under their real name so a
    /// relocation never silently skips an evicted sidecar. Mirrors
    /// `WebLibrary.recordFileNames`, which deliberately excludes `.ink.json`.
    static func inkFileNames(inDir dir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out = Set<String>()
        for name in names {
            guard !SyncArtifact.matches(name) else { continue }
            if name.hasSuffix(".ink.json") {
                out.insert(name)
            } else if name.hasPrefix("."), name.hasSuffix(".ink.json.icloud") {
                out.insert(String(name.dropFirst().dropLast(".icloud".count)))
            }
        }
        return out.sorted()
    }

    /// Move one ink sidecar between storage layouts. Relocation is a snapshot
    /// move, not an archive import: when both paths exist, the newer whole
    /// record is authoritative. Unioning clusters here would resurrect strokes
    /// that the newer snapshot intentionally erased.
    /// Locking uses the shared `WebLibrary.recordLock` registry (the same locks
    /// `saveRecord` takes) so a concurrent ink write can't interleave.
    @discardableResult
    static func adoptInkFile(from source: URL, to destination: URL) -> Bool {
        let first = source.path < destination.path ? source : destination
        let second = source.path < destination.path ? destination : source
        let lockA = WebLibrary.recordLock(for: first)
        let lockB = WebLibrary.recordLock(for: second)
        lockA.lock()
        defer { lockA.unlock() }
        lockB.lock()
        defer { lockB.unlock() }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard let dest = loadRecord(at: destination) else { return false }
            guard let src = loadRecord(at: source) else {
                // Unreadable source: leave it in place for inspection.
                return false
            }
            let merged = relocationSnapshot(current: dest, incoming: src)
            if merged != dest {
                guard (try? writeRecord(merged, to: destination)) != nil else { return false }
            }
            try? fm.removeItem(at: source)
            return true
        }
        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Background I/O engine

/// Owns ALL ink-sidecar file I/O for one open web document, off the main
/// thread and serialized per document (the same shape as `WebDocumentIO` for
/// the annotation sidecar). The debouncing `WebInkPersister` builds records on
/// the main actor and hands the Sendable value here to touch disk.
actor WebInkIO {
    nonisolated let url: String
    nonisolated let key: String

    init(url: String) {
        let normalized = (try? WebUrl.normalize(url)) ?? url
        self.url = normalized
        key = WebLibrary.pageKey(normalized)
    }

    func load() throws -> WebInkRecord? {
        try WebInkStore.loadRecordForExport(forKey: key)
    }

    @discardableResult
    func write(
        _ record: WebInkRecord,
        replacing baseline: WebInkRecord? = nil
    ) throws -> WebInkRecord {
        try WebInkStore.applySnapshot(record, replacing: baseline, forKey: key)
    }

    /// Complete additive archive merge under the same per-path lock as live
    /// snapshot writes.
    func mergeImported(_ record: WebInkRecord) throws {
        try WebInkStore.mergeImportedRecord(record, normalizedURL: url, forKey: key)
    }

    /// First stroke promotes the page into the saved library (decision 7) —
    /// the exact auto-save behavior of `WebDocumentIO.createAnnotation`, so an
    /// inked page always has an offline snapshot and the layout the ink was
    /// drawn against is never unrecoverable.
    func promoteToSaved() throws {
        try WebLibrary.withRecord(url: url, recordPath: WebLibrary.recordPath(forKey: key)) { record in
            guard !record.saved else { return }
            record.saved = true
            record.savedAt = record.savedAt ?? WebLibrary.rfc3339Now()
        }
    }
}

extension WebInkRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        url = try container.decode(String.self, forKey: .url)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        layout = try container.decode(Layout.self, forKey: .layout)
        clusters = try container.decode([Cluster].self, forKey: .clusters)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(url, forKey: .url)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(layout, forKey: .layout)
        try container.encode(clusters, forKey: .clusters)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

extension WebInkRecord.Layout {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentWidth = try container.decode(Double.self, forKey: .contentWidth)
        docHeight = try container.decode(Double.self, forKey: .docHeight)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentWidth, forKey: .contentWidth)
        try container.encode(docHeight, forKey: .docHeight)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

extension WebInkRecord.Bounds {
    private enum CodingKeys: String, CodingKey {
        case x, y, w, h
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        w = try container.decode(Double.self, forKey: .w)
        h = try container.decode(Double.self, forKey: .h)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(w, forKey: .w)
        try container.encode(h, forKey: .h)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

extension WebInkRecord.Anchor {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startOffset = try container.decode(Int.self, forKey: .startOffset)
        endOffset = try container.decodeIfPresent(Int.self, forKey: .endOffset)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix)
        rect = try container.decode(WebInkRecord.Bounds.self, forKey: .rect)
        page = try container.decodeIfPresent(Int.self, forKey: .page)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startOffset, forKey: .startOffset)
        try container.encodeIfPresent(endOffset, forKey: .endOffset)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(prefix, forKey: .prefix)
        try container.encodeIfPresent(suffix, forKey: .suffix)
        try container.encode(rect, forKey: .rect)
        try container.encodeIfPresent(page, forKey: .page)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}
