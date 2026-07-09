import Foundation
import CryptoKit

/// PKCE (RFC 7636) helpers plus JWT payload decoding, matching the Codex CLI
/// login flow (codex-rs/login/src/pkce.rs). All base64 is URL-safe with no
/// padding, which is what OpenAI's OAuth endpoints expect.
enum PKCE {
    /// One PKCE pair: the high-entropy `verifier` kept locally and the derived
    /// `challenge` (S256) sent in the authorize request.
    struct Pair: Sendable {
        let verifier: String
        let challenge: String
    }

    /// verifier = base64url(64 random bytes); challenge = base64url(sha256(verifier)).
    static func generate() throws -> Pair {
        let verifier = base64URLNoPad(try randomBytes(64))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Pair(verifier: verifier, challenge: base64URLNoPad(Data(digest)))
    }

    /// Opaque anti-forgery value echoed back on the callback (32 random bytes).
    static func generateState() throws -> String {
        base64URLNoPad(try randomBytes(32))
    }

    /// Cryptographically secure random bytes. Throws rather than returning the
    /// zero-filled (or partially written) buffer when the RNG fails.
    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw AiClientError.message("Could not generate secure random bytes (OSStatus \(status)).")
        }
        return Data(bytes)
    }

    /// RFC 4648 §5 URL-safe base64 without `=` padding.
    static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal JWT payload reader — decodes the middle (claims) segment only. These
/// tokens come from OpenAI's own auth server, so we never verify the signature;
/// we only read the account id and expiry a signed token already carries.
enum JWT {
    /// Decodes the claims segment of a JWT into a JSON dictionary, or nil if the
    /// token is malformed.
    static func payload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let data = decodeSegment(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Standard `exp` claim as a Date, if present.
    static func expiration(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// ChatGPT account id, nested under the `https://api.openai.com/auth` claim
    /// as `chatgpt_account_id` (codex-rs/login/src/token_data.rs).
    static func chatgptAccountId(_ idToken: String) -> String? {
        guard let auth = payload(idToken)?["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return auth["chatgpt_account_id"] as? String
    }

    /// Account email, from the top-level `email` claim or the profile claim.
    static func email(_ token: String) -> String? {
        guard let payload = payload(token) else { return nil }
        if let email = payload["email"] as? String { return email }
        if let profile = payload["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String {
            return email
        }
        return nil
    }

    /// ChatGPT plan type (e.g. "plus", "pro"), nested under the auth claim.
    static func chatgptPlanType(_ idToken: String) -> String? {
        guard let auth = payload(idToken)?["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return auth["chatgpt_plan_type"] as? String
    }

    /// base64url segment decode, tolerating missing padding.
    private static func decodeSegment(_ segment: String) -> Data? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
