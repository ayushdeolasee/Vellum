import Foundation
import VellumCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A three-way comparison of tiny, disposable libraries. Only transport is simulated.
struct SyncthingSimulator {
    struct Peer {
        let id: String
        let root: URL
        var store: LocalFolderFileStore { LocalFolderFileStore(root: root) }
    }

    struct File {
        let bytes: Data
        let modified: Date
    }

    let a: Peer
    let b: Peer
    private var baseline: [String: Data] = [:]
    private var generation = 0

    init(a: Peer, b: Peer) { self.a = a; self.b = b }

    // Interpret the managed block's POSIX globs, anchored paths and ** directories.
    // Refuse unsupported directives instead of claiming they protected a fixture.
    private func ignores(_ peer: Peer) async throws -> [String] {
        guard let bytes = try await peer.store.read(peer.root.appendingPathComponent(".stignore"))
        else { return [] }
        let rules = String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        guard !rules.contains(where: { $0.hasPrefix("#") || $0.hasPrefix("!") }) else {
            throw CocoaError(.featureUnsupported)
        }
        return rules
    }

    private func matches(_ path: String, rule: String) -> Bool {
        var pattern = rule
        var candidate = path
        if pattern.hasPrefix("(?d)") { pattern.removeFirst(4) }
        if pattern.hasPrefix("(?i)") { pattern.removeFirst(4); candidate = path.lowercased(); pattern = pattern.lowercased() }
        let parts = candidate.split(separator: "/")
        let globs = pattern.split(separator: "/")
        func match(_ names: ArraySlice<Substring>, _ patterns: ArraySlice<Substring>) -> Bool {
            guard let glob = patterns.first else { return true } // includes descendants
            if glob == "**" {
                return match(names, patterns.dropFirst()) || (!names.isEmpty && match(names.dropFirst(), patterns))
            }
            guard let name = names.first, fnmatch(String(glob), String(name), 0) == 0 else { return false }
            return match(names.dropFirst(), patterns.dropFirst())
        }
        if pattern.hasPrefix("/") { return match(parts[...], globs[...]) }
        return parts.indices.contains { match(parts[$0...], globs[...]) }
    }

    private func snapshot(_ peer: Peer, rules: [String]) throws -> [String: File] {
        var files: [String: File] = [:]
        func visit(_ directory: URL, prefix: String) throws {
            for entry in try peer.store.contents(of: directory) {
                let name = entry.url.lastPathComponent
                let path = prefix + name
                if [".stignore", ".stfolder", ".stversions"].contains(path)
                    || (name.hasPrefix(".syncthing.") && name.hasSuffix(".tmp"))
                    || rules.contains(where: { matches(path, rule: $0) }) { continue }
                if entry.isDirectory { try visit(entry.url, prefix: path + "/"); continue }
                let date = try entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                files[path] = File(bytes: try Data(contentsOf: entry.url), modified: date ?? .distantPast)
            }
        }
        try visit(peer.root, prefix: "")
        return files
    }

    @discardableResult
    mutating func sync() async throws -> Set<String> {
        let rules = try await ignores(a) + ignores(b)
        let left = try snapshot(a, rules: rules)
        let right = try snapshot(b, rules: rules)
        let paths = Set(left.keys).union(right.keys).union(baseline.keys)
        var conflicts = Set<String>()
        generation += 1

        func install(_ file: File?, at path: String, on peer: Peer, replacing old: File?) async throws {
            guard file?.bytes != old?.bytes else { return }
            let url = peer.root.appendingPathComponent(path)
            if let file {
                try await peer.store.replace(url, with: file.bytes)
                try FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: url.path)
            } else { try await peer.store.remove(url) }
        }

        for path in paths.sorted() where !rules.contains(where: { matches(path, rule: $0) }) {
            let x = left[path], y = right[path]
            let winner: File?
            if x?.bytes == y?.bytes { winner = x }
            else if x?.bytes == baseline[path] { winner = y }
            else if y?.bytes == baseline[path] { winner = x }
            else if let x, let y {
                let firstWins = (x.modified, a.id) > (y.modified, b.id)
                winner = firstWins ? x : y
                let loser = firstWins ? y : x
                let file = path as NSString
                let token = String(format: ".sync-conflict-20260101-%06d-", generation) + (firstWins ? b.id : a.id)
                let sibling = file.deletingPathExtension + token + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension)
                guard left[sibling] == nil, right[sibling] == nil else { throw CocoaError(.fileWriteFileExists) }
                try await install(loser, at: sibling, on: a, replacing: nil)
                try await install(loser, at: sibling, on: b, replacing: nil)
                baseline[sibling] = loser.bytes
                conflicts.insert(path)
            } else { winner = x ?? y } // concurrent deletion vs modification
            try await install(winner, at: path, on: a, replacing: x)
            try await install(winner, at: path, on: b, replacing: y)
            baseline[path] = winner?.bytes
        }
        return conflicts
    }
}
