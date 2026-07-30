import Foundation

protocol IntegrationCredentials: Sendable {
    func credential(for provider: IntegrationProvider) async -> String?
    func setCredential(_ credential: String, for provider: IntegrationProvider) async -> Bool
    func deleteCredential(for provider: IntegrationProvider) async -> Bool
}

struct KeychainIntegrationCredentials: IntegrationCredentials {
    static let service = "com.vellum.integrations"

    func credential(for provider: IntegrationProvider) async -> String? {
        KeychainStore.get(account(for: provider), service: Self.service)
    }

    func setCredential(_ credential: String, for provider: IntegrationProvider) async -> Bool {
        KeychainStore.set(account(for: provider), credential, service: Self.service)
    }

    func deleteCredential(for provider: IntegrationProvider) async -> Bool {
        KeychainStore.delete(account(for: provider), service: Self.service)
    }

    private func account(for provider: IntegrationProvider) -> String {
        "read-later.\(provider.rawValue)"
    }
}
