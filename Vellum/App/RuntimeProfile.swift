import Foundation

/// Build identity and process-local sync policy shared by the app and its
/// extensions. Debug products contain a `dev` bundle-id component; Release
/// products keep the production identifiers.
enum RuntimeProfile: Sendable {
    case production
    case development

    static let current = RuntimeProfile(bundleIdentifier: Bundle.main.bundleIdentifier)

    init(bundleIdentifier: String?) {
        let components = bundleIdentifier?.split(separator: ".") ?? []
        self = components.contains("dev") ? .development : .production
    }

    var isDevelopment: Bool { self == .development }

    var syncEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("--disable-sync")
    }

    var cloudContainerIdentifier: String {
        isDevelopment
            ? "iCloud.com.ayushdeolasee.vellum.dev"
            : "iCloud.com.ayushdeolasee.vellum"
    }

    var appGroupIdentifier: String {
        isDevelopment
            ? "group.com.ayushdeolasee.vellum.dev"
            : "group.com.ayushdeolasee.vellum"
    }

    var localStorageDirectoryName: String { isDevelopment ? "Vellum Dev" : "Vellum" }

    var keychainVaultService: String {
        isDevelopment ? "com.vellum.dev.vault" : "com.vellum.vault"
    }

    var urlScheme: String { isDevelopment ? "vellum-dev" : "vellum" }

    var readLaterBackgroundTaskIdentifier: String {
        isDevelopment
            ? "com.ayushdeolasee.vellum.dev.readlater.refresh"
            : "com.ayushdeolasee.vellum.readlater.refresh"
    }

    var captureBackgroundSessionIdentifier: String {
        isDevelopment
            ? "com.ayushdeolasee.vellum.dev.capture-wake"
            : "com.ayushdeolasee.vellum.capture-wake"
    }
}
