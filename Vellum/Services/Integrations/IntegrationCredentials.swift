import Foundation

protocol IntegrationCredentials: Sendable {
    func credential(for provider: IntegrationProvider) async -> String?
    func readCredential(for provider: IntegrationProvider) async -> KeychainStore.CredentialRead
    func setCredential(_ credential: String, for provider: IntegrationProvider) async -> Bool
    func deleteCredential(for provider: IntegrationProvider) async -> Bool
}

extension IntegrationCredentials {
    func readCredential(for provider: IntegrationProvider) async -> KeychainStore.CredentialRead {
        await credential(for: provider).map(KeychainStore.CredentialRead.value) ?? .missing
    }
}

struct KeychainIntegrationCredentials: IntegrationCredentials {
    static let service = "com.vellum.integrations"

    // Each call hops to a detached task so a keychain access prompt (or lock
    // contention with another Vellum instance) blocks neither the caller's
    // actor nor, transitively, the sync engine's serial executor.
    func credential(for provider: IntegrationProvider) async -> String? {
        let account = account(for: provider)
        return await Task.detached(priority: .userInitiated) {
            KeychainStore.get(account, service: Self.service)
        }.value
    }

    func readCredential(for provider: IntegrationProvider) async -> KeychainStore.CredentialRead {
        let account = account(for: provider)
        return await Task.detached(priority: .userInitiated) {
            KeychainStore.read(account, service: Self.service)
        }.value
    }

    func setCredential(_ credential: String, for provider: IntegrationProvider) async -> Bool {
        let account = account(for: provider)
        return await Task.detached(priority: .userInitiated) {
            KeychainStore.set(account, credential, service: Self.service)
        }.value
    }

    func deleteCredential(for provider: IntegrationProvider) async -> Bool {
        let account = account(for: provider)
        return await Task.detached(priority: .userInitiated) {
            KeychainStore.delete(account, service: Self.service)
        }.value
    }

    private func account(for provider: IntegrationProvider) -> String {
        "read-later.\(provider.rawValue)"
    }
}
