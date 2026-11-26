import CSecret
import Foundation
import VellumCore

public struct SecretServiceStore: CredentialStore {
    // libsecret's synchronous calls can wait for D-Bus. Keep them off both the
    // GTK main loop and Swift's cooperative pool. No connection opens at init.
    private static let queue = DispatchQueue(label: "com.vellum.secret-service")

    public init() {}

    public func read(_ account: String, service: String) async -> CredentialRead {
        guard valid(account, service) else { return .unavailable }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                var text: UnsafeMutablePointer<CChar>?
                let result = vellum_secret_read(service, account, &text)
                defer { g_free(text) }
                switch result {
                case VELLUM_MISSING: continuation.resume(returning: .missing)
                case VELLUM_VALUE:
                    let value = text.flatMap { String(validatingCString: $0) }
                    continuation.resume(returning: value.map(CredentialRead.value) ?? .unavailable)
                default: continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    public func write(_ value: String, account: String, service: String) async -> CredentialWrite {
        guard valid(account, service), !value.utf8.contains(0) else { return .failed }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return await delete(account, service: service) ? .saved : .failed }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: vellum_secret_write(service, account, trimmed) != 0 ? .saved : .failed)
            }
        }
    }

    public func delete(_ account: String, service: String) async -> Bool {
        guard valid(account, service) else { return false }
        return await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: vellum_secret_delete(service, account) != 0)
            }
        }
    }

    private func valid(_ account: String, _ service: String) -> Bool {
        !account.utf8.contains(0) && !service.utf8.contains(0)
    }
}
