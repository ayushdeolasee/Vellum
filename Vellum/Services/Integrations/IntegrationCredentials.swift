import Foundation
import VellumCore

protocol IntegrationCredentials: Sendable {
    func credential(for provider: IntegrationProvider) async -> String?
    func readCredential(for provider: IntegrationProvider) async -> KeychainStore.CredentialRead
    func writeCredential(_ credential: String, for provider: IntegrationProvider) async -> KeychainStore.CredentialWrite
    func setCredential(_ credential: String, for provider: IntegrationProvider) async -> Bool
    func deleteCredential(for provider: IntegrationProvider) async -> Bool
}

extension IntegrationCredentials {
    func writeCredential(_ credential: String, for provider: IntegrationProvider) async -> KeychainStore.CredentialWrite {
        await setCredential(credential, for: provider) ? .saved : .failed
    }

    func readCredential(for provider: IntegrationProvider) async -> KeychainStore.CredentialRead {
        await credential(for: provider).map(KeychainStore.CredentialRead.value) ?? .missing
    }
}

struct KeychainIntegrationCredentials: IntegrationCredentials {
    static let service = "com.vellum.integrations"

    var store: any CredentialStore = AppleCredentialStore()

    func credential(for provider: IntegrationProvider) async -> String? {
        guard case .value(let value) = await readCredential(for: provider) else { return nil }
        return value
    }

    func readCredential(for provider: IntegrationProvider) async -> KeychainStore.CredentialRead {
        await store.read(account(for: provider), service: Self.service)
    }

    func writeCredential(_ credential: String, for provider: IntegrationProvider) async -> KeychainStore.CredentialWrite {
        await store.write(credential, account: account(for: provider), service: Self.service)
    }

    func setCredential(_ credential: String, for provider: IntegrationProvider) async -> Bool {
        await writeCredential(credential, for: provider) == .saved
    }

    func deleteCredential(for provider: IntegrationProvider) async -> Bool {
        await store.delete(account(for: provider), service: Self.service)
    }

    private func account(for provider: IntegrationProvider) -> String {
        "read-later.\(provider.rawValue)"
    }
}
