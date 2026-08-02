import Foundation

struct IntegrationPreferences {
    private enum Key {
        static let autoRefresh = "integrations.autoRefresh"
        static let offlineReading = "integrations.offlineReading"
        static let enabledPrefix = "integrations.enabled."
        static let generationPrefix = "integrations.generation."
        static let fingerprintPrefix = "integrations.accountFingerprint."
    }

    /// Nil in the app, where the domain resolves through `AppDefaults.current`
    /// on every access rather than once at init: that redirect is a task-local
    /// (see `AppDefaults`), so a hosted test can bind and unbind it around a
    /// value that outlives the binding, and connection state must never land in
    /// the real user's defaults just because this type was built too early.
    /// Tests that want their own suite inject one directly.
    private let injectedDefaults: UserDefaults?
    var defaults: UserDefaults { injectedDefaults ?? AppDefaults.current }

    init(defaults: UserDefaults? = nil) {
        self.injectedDefaults = defaults
    }

    /// Read with an inline default instead of `register(defaults:)`, which would
    /// pin the registration to whichever domain happened to be current at init.
    var autoRefreshEnabled: Bool {
        get { defaults.object(forKey: Key.autoRefresh) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.autoRefresh) }
    }

    /// "Download for offline reading" (#157). Default ON, read the same
    /// inline-default way as `autoRefreshEnabled` rather than through
    /// `register(defaults:)`, which would pin the registration to whichever
    /// defaults domain happened to be current when this value was built.
    var offlineReadingEnabled: Bool {
        get { defaults.object(forKey: Key.offlineReading) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.offlineReading) }
    }

    func metadata(for provider: IntegrationProvider) -> IntegrationConnectionMetadata {
        IntegrationConnectionMetadata(
            enabled: defaults.bool(forKey: Key.enabledPrefix + provider.rawValue),
            generation: defaults.integer(forKey: Key.generationPrefix + provider.rawValue),
            accountFingerprint: defaults.string(forKey: Key.fingerprintPrefix + provider.rawValue))
    }

    func persist(_ metadata: IntegrationConnectionMetadata, for provider: IntegrationProvider) {
        defaults.set(metadata.enabled, forKey: Key.enabledPrefix + provider.rawValue)
        defaults.set(metadata.generation, forKey: Key.generationPrefix + provider.rawValue)
        if let fingerprint = metadata.accountFingerprint {
            defaults.set(fingerprint, forKey: Key.fingerprintPrefix + provider.rawValue)
        } else {
            defaults.removeObject(forKey: Key.fingerprintPrefix + provider.rawValue)
        }
    }
}

struct IntegrationConnectionMetadata: Hashable, Sendable {
    var enabled: Bool
    var generation: Int
    var accountFingerprint: String?
}
