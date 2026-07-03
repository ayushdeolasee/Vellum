import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case none
        case checking
        case available
    }

    private static let feedURL = URL(
        string: "https://github.com/ayushdeolasee/Vellum/releases/latest/download/latest.json")!
    private static let releasesURL = URL(
        string: "https://github.com/ayushdeolasee/Vellum/releases/latest")!

    private(set) var state: State = .none
    private(set) var availableVersion: String?
    private(set) var releaseNotes: String?
    private(set) var message = "Check for updates"

    var tooltip: String {
        guard let releaseNotes, !releaseNotes.isEmpty else { return message }
        return "\(message)\n\n\(releaseNotes)"
    }

    func check(silent: Bool = false) async {
        state = .checking
        if !silent {
            message = "Checking for updates..."
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: Self.feedURL)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw UpdateError.invalidResponse
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            if Self.isNewer(manifest.version, than: Self.currentVersion) {
                availableVersion = manifest.version
                releaseNotes = manifest.notes
                state = .available
                message = "Update \(manifest.version) is ready to install"
            } else {
                availableVersion = nil
                releaseNotes = nil
                state = .none
                message = "You are up to date"
            }
        } catch {
            NSLog("[Toolbar] Failed to check for updates: \(error)")
            availableVersion = nil
            releaseNotes = nil
            state = .none
            message = silent ? "Check for updates" : (error as? LocalizedError)?.errorDescription
                ?? "Failed to check for updates"
        }
    }

    /// Native package installation is intentionally out of scope. The update
    /// chip takes the user to the latest signed release instead.
    func install() {
        NSWorkspace.shared.open(Self.releasesURL)
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0.0.0"
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = versionParts(candidate)
        let currentParts = versionParts(current)
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in
                Int(component.prefix(while: { $0.isNumber })) ?? 0
            }
    }

    private struct UpdateManifest: Decodable {
        let version: String
        let notes: String?
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse

        var errorDescription: String? { "Failed to check for updates" }
    }
}
