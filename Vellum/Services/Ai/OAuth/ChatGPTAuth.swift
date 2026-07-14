import Foundation
import Observation
import UIKit

/// Tokens minted by the "Sign in with ChatGPT" OAuth flow, persisted as a JSON
/// blob in the Keychain. Mirrors the Codex CLI's stored auth (access + refresh +
/// id token + the ChatGPT account id read from the id token).
struct ChatGPTTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var accountId: String
    var lastRefresh: Date
}

/// Owns the ChatGPT-subscription OAuth lifecycle: interactive sign-in (PKCE +
/// loopback), token persistence, and proactive refresh. Replicates the Codex CLI
/// login flow (codex-rs/login) against OpenAI's own auth server. Observable so
/// the settings UI reflects signed-in/out state live.
///
/// Note: this talks to OpenAI's private CLI backend, not a supported public API.
@MainActor
@Observable
final class ChatGPTAuth {
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer = "https://auth.openai.com"
    private static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    /// The Codex CLI registers both ports; 1457 is the fallback if 1455 is taken.
    private static let ports: [UInt16] = [1455, 1457]
    /// Refresh once the access token is within this window of expiring.
    private static let refreshWindow: TimeInterval = 5 * 60
    /// Fallback refresh cadence when the access token carries no `exp` claim.
    private static let refreshInterval: TimeInterval = 8 * 24 * 60 * 60

    enum AuthError: LocalizedError {
        case notSignedIn
        case stateMismatch
        case tokenExchangeFailed(String)
        case missingAccountId

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in with ChatGPT in AI settings."
            case .stateMismatch: return "Sign-in could not be verified. Please try again."
            case .tokenExchangeFailed(let message): return "Sign-in failed: \(message)"
            case .missingAccountId: return "Your ChatGPT account has no Codex access."
            }
        }
    }

    /// True once tokens are stored; drives the settings UI.
    private(set) var isSignedIn: Bool
    /// "email · plan" for display, derived from the id token.
    private(set) var accountLabel: String?
    /// Set while an interactive sign-in is running so the button can show progress.
    private(set) var isAuthorizing = false

    private var refreshTask: Task<ChatGPTTokens, Error>?

    init() {
        let tokens = Self.loadTokens()
        isSignedIn = tokens != nil
        accountLabel = tokens.map(Self.label(for:)) ?? nil
    }

    // MARK: - Interactive sign-in

    /// Runs the full PKCE loopback flow: binds a local port, opens the browser,
    /// waits for the callback, exchanges the code, and stores the tokens.
    func signIn() async throws {
        isAuthorizing = true
        defer { isAuthorizing = false }

        let pkce = try PKCE.generate()
        let state = try PKCE.generateState()

        // Bind the first available registered port; its number goes into the
        // redirect_uri, which must be identical in authorize and token exchange.
        var server: OAuthLoopbackServer?
        for port in Self.ports {
            let candidate = OAuthLoopbackServer(port: port)
            if (try? candidate.start()) != nil {
                server = candidate
                break
            }
        }
        guard let server else {
            throw OAuthLoopbackServer.ServerError.portUnavailable(Self.ports[0])
        }
        defer { server.stop() }

        let redirectURI = "http://localhost:\(server.port)/auth/callback"
        guard let authorizeURL = Self.authorizeURL(pkce: pkce, state: state, redirectURI: redirectURI) else {
            throw AuthError.tokenExchangeFailed("could not build authorization URL")
        }
        // iOS: opening the authorize URL in Safari backgrounds the app, which
        // can suspend the loopback NWListener. Phase 2 (which wires the sign-in
        // button) should adopt ASWebAuthenticationSession so the app stays
        // foreground and the listener survives; for now this keeps ChatGPTAuth
        // compiling and functional when the app is not suspended.
        UIApplication.shared.open(authorizeURL, options: [:], completionHandler: nil)

        let callback = try await server.waitForCallback()
        guard callback.state == state else { throw AuthError.stateMismatch }

        let tokens = try await exchangeCode(
            callback.code, verifier: pkce.verifier, redirectURI: redirectURI)
        store(tokens)
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        KeychainStore.delete(KeychainStore.Account.chatgptTokens)
        isSignedIn = false
        accountLabel = nil
    }

    // MARK: - Token access for API calls

    /// Returns a currently-valid access token and the ChatGPT account id,
    /// refreshing first if the token is near expiry. Throws if not signed in.
    func validCredentials() async throws -> (accessToken: String, accountId: String) {
        guard let tokens = Self.loadTokens() else { throw AuthError.notSignedIn }
        let fresh = Self.needsRefresh(tokens) ? try await refresh(tokens) : tokens
        return (fresh.accessToken, fresh.accountId)
    }

    // MARK: - Token exchange

    private func exchangeCode(
        _ code: String, verifier: String, redirectURI: String
    ) async throws -> ChatGPTTokens {
        let form = Self.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.clientId,
            "code_verifier": verifier,
        ])
        var request = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.utf8)

        let object = try await Self.postForJSON(request)
        guard let accessToken = object["access_token"] as? String,
              let idToken = object["id_token"] as? String else {
            throw AuthError.tokenExchangeFailed("no tokens returned")
        }
        guard let accountId = JWT.chatgptAccountId(idToken) else {
            throw AuthError.missingAccountId
        }
        return ChatGPTTokens(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String ?? "",
            idToken: idToken,
            accountId: accountId,
            lastRefresh: Date()
        )
    }

    /// Refreshes the access token, deduplicating concurrent callers via a shared
    /// in-flight task so one turn's parallel requests don't refresh twice.
    private func refresh(_ tokens: ChatGPTTokens) async throws -> ChatGPTTokens {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { () throws -> ChatGPTTokens in
            let body: [String: Any] = [
                "client_id": Self.clientId,
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
            ]
            var request = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let object = try await Self.postForJSON(request)
            var updated = tokens
            if let access = object["access_token"] as? String { updated.accessToken = access }
            if let refresh = object["refresh_token"] as? String, !refresh.isEmpty {
                updated.refreshToken = refresh
            }
            if let id = object["id_token"] as? String, !id.isEmpty {
                updated.idToken = id
                if let accountId = JWT.chatgptAccountId(id) { updated.accountId = accountId }
            }
            updated.lastRefresh = Date()
            store(updated)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch {
            // A failed refresh (revoked/expired refresh token) forces re-auth.
            if (error as? URLError) == nil { signOut() }
            throw error
        }
    }

    private static func needsRefresh(_ tokens: ChatGPTTokens) -> Bool {
        if let exp = JWT.expiration(tokens.accessToken) {
            return exp <= Date().addingTimeInterval(refreshWindow)
        }
        return tokens.lastRefresh < Date().addingTimeInterval(-refreshInterval)
    }

    // MARK: - Persistence

    private func store(_ tokens: ChatGPTTokens) {
        Self.saveTokens(tokens)
        isSignedIn = true
        accountLabel = Self.label(for: tokens)
    }

    private static func loadTokens() -> ChatGPTTokens? {
        guard let raw = KeychainStore.get(KeychainStore.Account.chatgptTokens),
              let data = raw.data(using: .utf8),
              let tokens = try? JSONDecoder.chatgpt.decode(ChatGPTTokens.self, from: data)
        else { return nil }
        return tokens
    }

    private static func saveTokens(_ tokens: ChatGPTTokens) {
        guard let data = try? JSONEncoder.chatgpt.encode(tokens),
              let raw = String(data: data, encoding: .utf8) else { return }
        KeychainStore.set(KeychainStore.Account.chatgptTokens, raw)
    }

    private static func label(for tokens: ChatGPTTokens) -> String {
        let email = JWT.email(tokens.idToken)
        let plan = JWT.chatgptPlanType(tokens.idToken)?.capitalized
        switch (email, plan) {
        case let (email?, plan?): return "\(email) · \(plan)"
        case let (email?, nil): return email
        case let (nil, plan?): return "ChatGPT \(plan)"
        default: return "Signed in"
        }
    }

    // MARK: - HTTP helpers

    private static func authorizeURL(pkce: PKCE.Pair, state: String, redirectURI: String) -> URL? {
        var components = URLComponents(string: "\(issuer)/oauth/authorize")
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        return components?.url
    }

    private static func postForJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (object["error_description"] as? String)
                ?? (object["error"] as? String)
                ?? "status \(http.statusCode)"
            throw AuthError.tokenExchangeFailed(message)
        }
        return object
    }

    private static func formEncode(_ pairs: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")
    }
}

private extension JSONEncoder {
    static let chatgpt: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

private extension JSONDecoder {
    static let chatgpt: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
