import Foundation
import LinuxServices
import VellumCore

enum LinuxAIProvider: String, CaseIterable, Sendable {
    case gemini, openai, openrouter, opencode, opencodeGo

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .opencode: "OpenCode Zen"
        case .opencodeGo: "OpenCode Go"
        }
    }

    // Match Vellum's AI credential accounts. Chat reads through the same
    // provider lookup as Settings, only when it needs the selected key.
    static let credentialService = "com.vellum.ai"
    var credentialAccount: String { self == .opencodeGo ? "opencode-go" : rawValue }

    func readCredential() async -> CredentialRead {
        await SecretServiceStore().read(credentialAccount, service: Self.credentialService)
    }
}

struct ReaderPreferences: Sendable {
    static let defaultLibrary = URL(fileURLWithPath: "/library", isDirectory: true)
    static let defaultProvider: LinuxAIProvider = .gemini

    private let directory: URL

    init() {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["XDG_CONFIG_HOME"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        let home = environment["HOME"].flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
        }
        directory = (config ?? (home ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent(".config", isDirectory: true))
            .appendingPathComponent("vellum", isDirectory: true)
    }

    @concurrent
    func loadLibrary() async -> URL {
        guard let path = read("library"), path.hasPrefix("/"), !path.utf8.contains(0) else {
            return Self.defaultLibrary
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @concurrent
    func loadProvider() async -> LinuxAIProvider {
        read("ai-provider").flatMap(LinuxAIProvider.init(rawValue:)) ?? Self.defaultProvider
    }

    @concurrent
    func saveLibrary(_ root: URL) async throws {
        try write(root.path, to: "library")
    }

    @concurrent
    func saveProvider(_ provider: LinuxAIProvider) async throws {
        try write(provider.rawValue, to: "ai-provider")
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func write(_ value: String, to name: String) throws {
        // Each value is atomically replaced so separate reader launches can
        // update different preferences without overwriting each other.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(value.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
