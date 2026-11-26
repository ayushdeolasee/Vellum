public enum CredentialRead: Equatable, Sendable {
    case value(String), missing, unavailable
}

public enum CredentialWrite: Equatable, Sendable {
    case saved, failed
    /// A write may have committed, but cleanup/restoration could not verify.
    case needsReview
}

public protocol CredentialStore: Sendable {
    func read(_ account: String, service: String) async -> CredentialRead
    func write(_ value: String, account: String, service: String) async -> CredentialWrite
    func delete(_ account: String, service: String) async -> Bool
}
