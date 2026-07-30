import Foundation

struct IntegrationPreferences {
    private enum Key {
        static let autoRefresh = "integrations.autoRefresh"
        static let enabledPrefix = "integrations.enabled."
        static let generationPrefix = "integrations.generation."
        static let fingerprintPrefix = "integrations.accountFingerprint."
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.autoRefresh: true])
    }

    var autoRefreshEnabled: Bool {
        get { defaults.bool(forKey: Key.autoRefresh) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoRefresh) }
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
