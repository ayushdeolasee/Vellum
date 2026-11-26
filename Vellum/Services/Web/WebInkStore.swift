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
        // A pre-I4 save may carry a newer or malformed wire value alongside
        // a usable native drawing. Keep that value intact for read-only export.
        var unreadableStrokes: JSONValue? = nil

        var hasPortablePayload: Bool { strokes != nil || unreadableStrokes != nil }
        var bounds: Bounds
        var anchor: Anchor?
    }

    var history = InkMergeHistory()
    // Session-only PencilKit undo provenance, excluded from Codable.
    var rememberedClusters: [String: Cluster] = [:]
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
        case deleted = "deleted_ids", restored = "restored_ids", updated = "stroke_updated_at", nativeIDs = "stroke_native_ids"
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
        do {
            if container.contains(.strokes) {
                strokes = try container.decode([PortableStroke].self, forKey: .strokes)
            }
        } catch {
            guard drawing != nil else { throw error }
            unreadableStrokes = try container.decode(JSONValue.self, forKey: .strokes)
        }
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
        if let unreadableStrokes {
            try container.encode(unreadableStrokes, forKey: .strokes)
        } else {
            try container.encodeIfPresent(strokes, forKey: .strokes)
        }
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

    func validateForEditing() throws {
        var seen: Set<String> = []
        for cluster in clusters where cluster.hasPortablePayload {
            _ = try cluster.portableIndices(for: cluster.localDrawing())
            for wire in cluster.strokes ?? [] where !seen.insert(wire.rawPathID).inserted {
                throw SessionServiceError.invalidDocument("Multiple saved strokes match the same canvas path.")
            }
        }
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
        if let drawing {
            let native = try PKDrawing(data: drawing)
            guard !native.strokes.isEmpty else { throw SessionServiceError.invalidDocument("Invalid ink cluster drawing") }
            return native
        }
        guard let strokes else { throw SessionServiceError.invalidDocument("Missing ink cluster data") }
        return try PKDrawing(portableStrokes: strokes)
    }

    /// Maps native stroke order to wire indices by I3 raw-path identity.
    /// Missing wire entries are allowed only for invisible native strokes.
    func portableIndices(for native: PKDrawing) throws -> [Int?] {
        let conflict = SessionServiceError.invalidDocument("The native and portable handwriting cannot be edited together.")
        guard unreadableStrokes == nil else { throw conflict }
        guard let strokes else { return Array(repeating: nil, count: native.strokes.count) }
        guard Set(strokes.map(\.id)).count == strokes.count else { throw conflict }
        if drawing == nil {
            guard native.strokes.count == strokes.count else { throw conflict }
            return try strokes.indices.map { i in
                let stroke = native.strokes[i]
                guard try strokes[i].rawPathID == PortableStroke.rawPathID(of: stroke),
                      try strokes[i].describes(stroke) else { throw conflict }
                return i
            }
        }
        var available: [String: Int] = [:]
        for (index, stroke) in strokes.enumerated() {
            guard available.updateValue(index, forKey: stroke.rawPathID) == nil else { throw conflict }
        }
        var seen: Set<String> = []
        let indices = try native.strokes.map { stroke -> Int? in
            let key = try PortableStroke.rawPathID(of: stroke)
            guard seen.insert(key).inserted else { throw conflict }
            guard let index = available.removeValue(forKey: key) else {
                guard stroke.maskedPathRanges.isEmpty else { throw conflict }
                return nil
            }
            guard try strokes[index].describes(stroke) else { throw conflict }
            return index
        }
        guard available.isEmpty else { throw conflict }
        return indices
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
        try? loadRecordForExport(forKey: key, timeout: timeout)
    }

    static func loadRecord(at path: URL) -> WebInkRecord? {
        try? readRecord(at: path)
    }

    private static func readRecord(at path: URL) throws -> WebInkRecord {
        let data: Data
        do { data = try Data(contentsOf: path) } catch {
            throw SessionServiceError.io("Failed to read this page's ink: \(error.localizedDescription)")
        }
        do {
            let record = try JSONDecoder().decode(WebInkRecord.self, from: data)
            _ = try record.validatedMergedDrawing()
            return record
        } catch {
            throw SessionServiceError.invalidDocument("This page's handwriting could not be read: \(error.localizedDescription)")
        }
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
            return try readRecord(at: path)
        }
        return nil
    }

    /// Atomic tmp→rename write to the active layout's ink path, serialized per
    /// path through the shared `WebLibrary` lock registry so two sessions on
    /// the same page can never interleave ink writes (decision 6).
    static func saveRecord(_ record: WebInkRecord, forKey key: String) throws {
        try withLockedCandidateRecords(forKey: key) { destination, current in
            if let current {
                try current.validateForEditing()
                _ = try coordinatedSnapshot(current: current, baseline: current, incoming: record,
                                            returningObservation: false) { try writeRecord($0, to: destination) }
            } else {
                try writeRecord(record, to: destination)
            }
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
        forKey key: String,
        returningObservation: Bool = false
    ) throws -> WebInkRecord {
        try withLockedCandidateRecords(forKey: key) { destination, current in
            try baseline?.validateForEditing()
            if current == nil, baseline == nil {
                var first = incoming
                try discardDeleted(from: &first)
                _ = try first.validatedMergedDrawing()
                try writeRecord(first, to: destination)
                return first
            }
            var empty = incoming
            empty.clusters = []
            return try coordinatedSnapshot(current: current ?? baseline ?? empty, baseline: baseline, incoming: incoming,
                                           returningObservation: returningObservation) {
                try writeRecord($0, to: destination)
            }
        }
    }

    /// Neighboring canvas strokes can have identical geometry but different wire IDs.
    /// Keep the cluster and slot with the native stroke all the way through reclustering.
    private final class Source {
        let cluster: WebInkRecord.Cluster
        let local: PKDrawing
        let strokes: [PKStroke]
        let wireIndices: [Int?]

        init(_ cluster: WebInkRecord.Cluster) throws {
            self.cluster = cluster
            local = try cluster.localDrawing()
            wireIndices = try cluster.portableIndices(for: local)
            strokes = local.transformed(using: CGAffineTransform(translationX: cluster.bounds.x,
                                                                 y: cluster.bounds.y)).strokes
        }
    }

    private struct Member {
        var id: String
        let nativeID: String
        let source: Source
        let slot: Int
        var stroke: PKStroke { source.strokes[slot] }
        var portable: PortableStroke? { source.wireIndices[slot].flatMap { source.cluster.strokes?[$0] } }
    }

    private static func members(_ record: WebInkRecord) throws -> [Member] {
        guard (1...WebInkRecord.currentVersion).contains(record.version) else {
            throw SessionServiceError.invalidDocument("Unsupported web ink version")
        }
        return try record.clusters.flatMap { cluster in
            let source = try Source(cluster)
            return try source.strokes.enumerated().map { i, stroke in
                let nativeID = try PortableStroke.rawPathID(of: stroke)
                let wire = source.wireIndices[i].flatMap { cluster.strokes?[$0] }
                return Member(id: wire?.id ?? nativeID, nativeID: nativeID, source: source, slot: i)
            }
        }
    }

    private struct Identities {
        var byNative: [String: Set<String>] = [:]

        init(_ members: [Member], history: InkMergeHistory) {
            for member in members where member.source.cluster.hasPortablePayload {
                byNative[member.nativeID, default: []].insert(member.id)
            }
            for (id, nativeID) in history.nativeIDs where nativeID != id {
                byNative[nativeID, default: []].insert(id)
            }
        }

        /// An erase first seen on a drawing-only canvas has only the I3 digest.
        /// Once a wire copy arrives, bind that receipt to its actual, opaque ID.
        func bindingNativeErases(in original: InkMergeHistory) throws -> InkMergeHistory {
            var result = original
            for (native, erase) in original.deleted where original.nativeIDs[native] == native {
                guard let candidates = byNative[native] else { continue }
                guard candidates.count == 1, let id = candidates.first else {
                    throw SessionServiceError.invalidDocument("Ambiguous erased handwriting identity")
                }
                guard id != native else { continue }
                var receipt = InkMergeHistory()
                receipt.deleted[id] = erase
                receipt.restored[id] = original.restored[native]
                receipt.nativeIDs[id] = native
                result.formUnion(receipt)
            }
            return result
        }

        /// An old native-only archive cannot identify a foreign, opaque deletion
        /// without its raw-path alias. Refuse this ambiguous import intact.
        func validateOffline(_ members: [Member], from source: InkMergeHistory, against combined: InkMergeHistory) throws {
            guard members.contains(where: { !$0.source.cluster.hasPortablePayload && byNative[$0.nativeID] == nil }) else { return }
            let knownWireIDs = Set(byNative.values.flatMap { $0 })
            for (id, erase) in combined.deleted where !combined.admits(id, from: combined) {
                if combined.nativeIDs[id] != nil || knownWireIDs.contains(id) || source.deleted[id] == erase { continue }
                let isDigest = id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                if !isDigest { throw SessionServiceError.invalidDocument("Missing native identity for erased portable ink") }
            }
        }

        func resolve(_ input: [Member]) throws -> [Member] {
            var seen: Set<String> = []
            return try input.map { member in
                var resolved = member
                if !member.source.cluster.hasPortablePayload, let ids = byNative[member.nativeID] {
                    guard ids.count == 1, let id = ids.first else {
                        throw SessionServiceError.invalidDocument("Ambiguous native handwriting identity")
                    }
                    resolved.id = id
                }
                guard seen.insert(resolved.id).inserted else {
                    throw SessionServiceError.invalidDocument("Duplicate handwriting identity")
                }
                return resolved
            }
        }
    }

    /// Native snapshots have no place for a foreign ID. The observation returned to
    /// the editor remembers its own erase receipts and source clusters for PencilKit undo.
    /// This session-only provenance is never encoded or added to the visible drawing.
    private static func coordinatedSnapshot(
        current: WebInkRecord, baseline: WebInkRecord?, incoming: WebInkRecord,
        returningObservation: Bool, write: (WebInkRecord) throws -> Void
    ) throws -> WebInkRecord {
        let disk = try members(current)
        let canvas = try members(incoming)
        let observed = try baseline.map(members) ?? []
        var remembered = baseline?.rememberedClusters ?? [:]
        var old = incoming
        old.clusters = Array(remembered.values)
        let undoSources = try members(old).filter { remembered[$0.id] != nil }
        var history = current.history
        history.formUnion(incoming.history)
        if let baseline { history.formUnion(baseline.history) }
        let ids = Identities(disk + canvas + observed + undoSources, history: history)
        history = try ids.bindingNativeErases(in: history)
        let diskHistory = try ids.bindingNativeErases(in: current.history)
        let latest = try ids.resolve(disk)
        let pending = try ids.resolve(canvas)
        let base = try ids.resolve(observed)
        let baseByID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let pendingIDs = Set(pending.map(\.id))
        let surviving = latest.filter { history.admits($0.id, from: diskHistory) }
        var chosen = Dictionary(uniqueKeysWithValues: surviving.map { ($0.id, $0) })
        var observationHistory = baseline?.history ?? InkMergeHistory()
        observationHistory.formUnion(incoming.history)
        observationHistory = try ids.bindingNativeErases(in: observationHistory)
        func editTime(_ id: String) -> String {
            let prior = baseline?.history.updated[id] ?? baseline?.updatedAt
            return InkMergeHistory.next(incoming.updatedAt, after: prior)
        }
        for member in base where !pendingIDs.contains(member.id) {
            let id = member.id
            let time = InkMergeHistory.next(editTime(id), after: observationHistory.restored[id])
            var erase = InkMergeHistory()
            erase.deleted[id] = time
            if member.nativeID != id || !member.source.cluster.hasPortablePayload {
                erase.nativeIDs[id] = member.nativeID
            }
            observationHistory.formUnion(erase)
            history.formUnion(erase)
            if returningObservation {
                var erased = member.source.cluster
                if member.source.strokes.count > 1 {
                    erased.strokes = member.portable.map { [$0] }
                    if erased.drawing != nil {
                        let local = member.source.local.strokes[member.slot]
                        erased.drawing = PKDrawing(strokes: [local]).dataRepresentation()
                    }
                }
                remembered[id] = erased
            }
            if !history.admits(id, from: diskHistory) { chosen.removeValue(forKey: id) }
        }
        for member in pending {
            let id = member.id
            let previous = baseByID[id]
            if let previous, strokeSignature(member.stroke) == strokeSignature(previous.stroke) { continue }
            var time = editTime(id)
            if previous == nil, remembered[id] != nil, let seenErase = observationHistory.deleted[id],
               !observationHistory.admits(id, from: observationHistory) {
                time = InkMergeHistory.next(time, after: seenErase)
                observationHistory.restored[id] = time
                history.formUnion(observationHistory)
            }
            guard history.admits(id, from: observationHistory) else { continue }
            if chosen[id] != nil {
                guard previous != nil || remembered[id] != nil else { continue }
                let onDisk = current.history.updated[id] ?? current.updatedAt
                // An observed edit wins over its own base even on an equal clock.
                if let previous, let stored = chosen[id],
                   strokeSignature(previous.stroke) != strokeSignature(stored.stroke),
                   !InkMergeHistory.newer(time, than: onDisk) { continue }
            }
            chosen[id] = member
            history.updated[id] = time
            observationHistory.updated[id] = time
        }
        // Freeze the timestamp of unchanged legacy strokes before the page clock advances.
        for member in latest where chosen[member.id] != nil && history.updated[member.id] == nil {
            history.updated[member.id] = current.updatedAt
        }
        let diskIDs = Set(latest.map(\.id))
        let order = latest.map(\.id) + pending.map(\.id).filter { !diskIDs.contains($0) }
        let sources = latest + base + undoSources + pending
        var result = try mergedSnapshot(order.compactMap { chosen[$0] }, metadata: incoming,
                                        sources: sources, records: [current, incoming])
        result.history = history
        result.updatedAt = WebLibrary.rfc3339Now()
        guard returningObservation else {
            try write(result)
            return result
        }
        // Include only what this canvas saw, even if a concurrent change won on disk.
        var observation = try mergedSnapshot(pending, metadata: incoming, sources: sources, records: [current, incoming])
        observation.history = observationHistory
        for id in pendingIDs { remembered.removeValue(forKey: id) }
        observation.rememberedClusters = remembered
        try write(result)
        return observation
    }

    /// A peer may send both an old payload and its tombstone. Filter in cluster-local
    /// space before any reader, including archive adoption into an empty library.
    static func discardDeleted(from record: inout WebInkRecord) throws {
        if record.history.deleted.keys.contains(where: { record.history.nativeIDs[$0] == $0 }),
           record.clusters.contains(where: { $0.strokes != nil }) {
            var aliases = Identities([], history: record.history)
            for wire in record.clusters.flatMap({ $0.strokes ?? [] }) {
                aliases.byNative[wire.rawPathID, default: []].insert(wire.id)
            }
            record.history = try aliases.bindingNativeErases(in: record.history)
        }
        let erased = Set(record.history.deleted.keys.filter { !record.history.admits($0, from: record.history) })
        guard !erased.isEmpty, !record.clusters.isEmpty else { return }

        // Learn aliases before looking at any drawing-only copies, regardless of cluster order.
        var paired: [Int: Source] = [:]
        for (index, cluster) in record.clusters.enumerated() {
            guard let wire = cluster.strokes, wire.contains(where: { erased.contains($0.id) }) else { continue }
            let source = try Source(cluster)
            paired[index] = source
            for (slot, wireIndex) in source.wireIndices.enumerated() {
                guard let wireIndex, erased.contains(wire[wireIndex].id) else { continue }
                let id = wire[wireIndex].id
                let native = try PortableStroke.rawPathID(of: source.strokes[slot])
                if id != native { record.history.nativeIDs[id] = native }
            }
        }
        let hiddenPaths = Set(erased.map { record.history.nativeIDs[$0] ?? $0 })
        var kept: [WebInkRecord.Cluster] = []
        for (index, original) in record.clusters.enumerated() {
            var cluster = original
            let local = try paired[index]?.local ?? cluster.localDrawing()
            let strokes = local.strokes
            let nativeIDs = try strokes.map(PortableStroke.rawPathID(of:))
            if paired[index] == nil, nativeIDs.allSatisfy({ !hiddenPaths.contains($0) }) {
                // An unrelated deletion must not turn an I4-readable stale dual blob into a load error.
                kept.append(cluster)
                continue
            }
            let slots = try paired[index]?.wireIndices ?? cluster.portableIndices(for: local)
            let survivors = strokes.indices.filter { slot in
                if let i = slots[slot], let wire = cluster.strokes { return !erased.contains(wire[i].id) }
                // An omitted native member of a dual has its own canonical ID.
                return cluster.hasPortablePayload ? !erased.contains(nativeIDs[slot]) : !hiddenPaths.contains(nativeIDs[slot])
            }
            guard !survivors.isEmpty else { continue }
            if survivors.count != strokes.count {
                if cluster.drawing != nil {
                    cluster.drawing = PKDrawing(strokes: survivors.map { strokes[$0] }).dataRepresentation()
                }
                if let wire = cluster.strokes {
                    let indices = survivors.compactMap { slots[$0] }.sorted()
                    cluster.strokes = indices.isEmpty ? nil : indices.map { wire[$0] }
                }
            }
            kept.append(cluster)
        }
        record.clusters = kept
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
    static func relocationSnapshot(current: WebInkRecord, incoming: WebInkRecord) throws -> WebInkRecord {
        var result = WebArchive.newerThan(incoming.updatedAt, current.updatedAt) ? incoming : current
        let other = WebArchive.newerThan(incoming.updatedAt, current.updatedAt) ? current : incoming
        // Relocation still selects the newer whole canvas. Carry older erases
        // without importing strokes absent from the selected snapshot.
        var erases = other.history
        erases.restored = [:]
        erases.updated = [:]
        result.history.formUnion(erases)
        try discardDeleted(from: &result)
        result.history.formUnion(other.history)
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
        var maskEvenOdd: Bool?
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
            mask: stroke.mask?.cgPath, maskEvenOdd: stroke.maskEvenOdd, randomSeed: stroke.randomSeed,
            visibleRanges: stroke.maskedPathRanges)
    }

    /// Additive archive merge at stable stroke identity, then derive clusters
    /// again. Cluster ids are layout/anchor metadata and may legitimately
    /// change when a once-unanchored stroke gains a text anchor, so using them
    /// as content identity can duplicate or replace the user's ink.
    static func additivelyMerged(current: WebInkRecord, incoming: WebInkRecord) throws -> WebInkRecord {
        let incumbent = try members(current)
        let offered = try members(incoming)
        var history = current.history
        history.formUnion(incoming.history)
        let ids = Identities(incumbent + offered, history: history)
        try ids.validateOffline(incumbent, from: current.history, against: history)
        try ids.validateOffline(offered, from: incoming.history, against: history)
        let left = try ids.resolve(incumbent)
        let right = try ids.resolve(offered)
        let selection = try InkMergeHistory.merge(current: ids.bindingNativeErases(in: current.history),
            ids: left.map(\.id), timestamp: current.updatedAt, incoming: ids.bindingNativeErases(in: incoming.history),
            incomingIDs: right.map(\.id), incomingTimestamp: incoming.updatedAt)
        let records = WebArchive.newerThan(incoming.updatedAt, current.updatedAt) ? [incoming, current] : [current, incoming]
        let winners = selection.strokes.map { $0.incoming ? right[$0.index] : left[$0.index] }
        var result = try mergedSnapshot(winners, metadata: records[0], sources: winners + left + right, records: records,
            nativeIDs: Set((left + right).filter { $0.source.cluster.drawing != nil }.map(\.id)))
        result.history = selection.history
        for member in left + right where result.history.deleted[member.id] != nil && member.id != member.nativeID {
            result.history.nativeIDs[member.id] = member.nativeID
        }
        result.version = min(current.version, incoming.version)
        return result
    }

    private static func mergedSnapshot(
        _ winners: [Member], metadata: WebInkRecord, sources: [Member], records: [WebInkRecord], nativeIDs: Set<String> = []
    ) throws -> WebInkRecord {
        let byID = Dictionary(grouping: sources, by: \.id)
        // A canvas snapshot is drawing-only. Recover the portable representation from
        // the persisted source, including its cluster-local transform and native mask.
        let wireSources = winners.map { member in
            member.portable != nil ? member : byID[member.id]?.first { $0.portable != nil }
        }
        let anchors = ([metadata] + records).flatMap(\.clusters)
        func needsNative(_ index: Int) -> Bool {
            wireSources[index]?.source.cluster.drawing != nil || nativeIDs.contains(winners[index].id)
        }
        let reserved = Set(wireSources.compactMap { $0?.source.cluster.id })
        var used: Set<String> = []
        var result = metadata
        result.clusters = []
        for indices in WebInkClustering.groups(of: winners.map(\.stroke)) {
            var start = 0
            while start < indices.count {
                let first = indices[start]
                let wire = wireSources[first]
                var end = start + 1
                var paths: Set<String> = [winners[first].nativeID]
                while end < indices.count {
                    let next = indices[end]
                    guard wireSources[next]?.source === wire?.source, needsNative(next) == needsNative(first) else { break }
                    if wire != nil, needsNative(next), !paths.insert(winners[next].nativeID).inserted { break }
                    end += 1
                }
                let run = indices[start..<end]
                let group = PKDrawing(strokes: run.map { winners[$0].stroke })
                let original = wire?.source ?? winners[first].source
                let anchor = anchors.compactMap { cluster -> (CGFloat, WebInkRecord.Anchor)? in
                    guard let anchor = cluster.anchor else { return nil }
                    let overlap = group.bounds.intersection(cluster.bounds.rect)
                    return overlap.isNull ? nil : (overlap.width * overlap.height, anchor)
                }.max { $0.0 < $1.0 }?.1 ?? (original.cluster.bounds.rect.intersects(group.bounds)
                    ? original.cluster.anchor : nil)
                let unchanged = group.strokes.map(strokeSignature) == original.strokes.map(strokeSignature)
                let bounds = unchanged ? original.cluster.bounds.rect : group.bounds
                var cluster = original.cluster
                if !unchanged || cluster.anchor != anchor {
                    cluster.id = WebInkRecord.clusterId(anchor: anchor, bounds: bounds)
                }
                cluster.anchor = anchor
                cluster.bounds = .init(bounds)
                let local = group.transformed(using: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                if !unchanged, cluster.drawing != nil { cluster.drawing = local.dataRepresentation() }
                if cluster.drawing == nil, needsNative(first) {
                    cluster.drawing = local.dataRepresentation()
                }
                if wire != nil {
                    cluster.strokes = try zip(run, local.strokes).map { i, localStroke in
                        let member = winners[i]
                        guard let prior = wireSources[i], var portable = prior.portable else {
                            throw SessionServiceError.invalidDocument("Missing source for portable ink")
                        }
                        if strokeSignature(member.stroke) == strokeSignature(prior.stroke) {
                            portable.transform[4] += prior.source.cluster.bounds.x - bounds.minX
                            portable.transform[5] += prior.source.cluster.bounds.y - bounds.minY
                        } else {
                            var edited = try PortableStroke(localStroke)
                            guard edited.points.count == portable.points.count,
                                  zip(edited.points, portable.points).allSatisfy({ lhs, rhs in
                                      lhs.x == rhs.x && lhs.y == rhs.y && lhs.t == rhs.t
                                  }) else {
                                throw SessionServiceError.invalidDocument("Inconsistent dual ink paths")
                            }
                            // A move can normalize equivalent AppKit/UIKit path commands.
                            // Keep the exact saved mask whenever its fill geometry still matches.
                            if try portable.matchesMask(of: localStroke) { edited.mask = portable.mask }
                            portable = edited
                            portable.id = member.id
                            // Refuse an edit that cannot reproduce its native erase geometry.
                            _ = try PKStroke(portable)
                        }
                        for source in byID[member.id] ?? [] {
                            if let old = source.portable { portable.inheritInkFields(from: old) }
                        }
                        return portable
                    }
                }
                if wire == nil {
                    // A dual source can omit a fully masked native member. It has no wire ID.
                    for i in run where !winners[i].stroke.maskedPathRanges.isEmpty {
                        if byID[winners[i].id]?.contains(where: { $0.source.cluster.hasPortablePayload && $0.portable == nil }) == true {
                            throw SessionServiceError.invalidDocument("A newly visible stroke has no portable identity")
                        }
                    }
                    cluster.strokes = nil
                    if reserved.contains(cluster.id) { cluster.id += ":native" }
                }
                let base = cluster.id
                var suffix = 1
                while !used.insert(cluster.id).inserted {
                    suffix += 1
                    cluster.id = "\(base):\(suffix)"
                }
                // Use the actual contributing strokes even when cluster IDs/bounds changed.
                for i in run {
                    for source in byID[winners[i].id] ?? [] {
                        inheritClusterFields(into: &cluster, from: source.source.cluster)
                    }
                }
                if cluster.drawing != nil && cluster.strokes != nil && !unchanged {
                    _ = try cluster.portableIndices(for: cluster.localDrawing())
                }
                result.clusters.append(cluster)
                start = end
            }
        }
        for record in records {
            result.unknownFields.inheritInkFields(from: record.unknownFields)
            result.layout.unknownFields.inheritInkFields(from: record.layout.unknownFields)
        }
        return result
    }

    private static func inheritClusterFields(into cluster: inout WebInkRecord.Cluster, from old: WebInkRecord.Cluster) {
        cluster.unknownFields.inheritInkFields(from: old.unknownFields)
        cluster.bounds.unknownFields.inheritInkFields(from: old.bounds.unknownFields)
        if let anchor = old.anchor {
            cluster.anchor?.unknownFields.inheritInkFields(from: anchor.unknownFields)
            cluster.anchor?.rect.unknownFields.inheritInkFields(from: anchor.rect.unknownFields)
        }
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
            guard let merged = try? relocationSnapshot(current: dest, incoming: src) else { return false }
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
        replacing baseline: WebInkRecord? = nil,
        returningObservation: Bool = false
    ) throws -> WebInkRecord {
        try WebInkStore.applySnapshot(record, replacing: baseline, forKey: key, returningObservation: returningObservation)
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
        history = try InkMergeHistory(from: decoder)
        version = try container.decode(Int.self, forKey: .version)
        url = try container.decode(String.self, forKey: .url)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        layout = try container.decode(Layout.self, forKey: .layout)
        clusters = try container.decode([Cluster].self, forKey: .clusters)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
        try WebInkStore.discardDeleted(from: &self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try history.encode(to: encoder)
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
