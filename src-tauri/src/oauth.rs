//! "Sign in with ChatGPT" OAuth support.
//!
//! This module is deliberately self-contained: every unofficial OpenAI endpoint,
//! header, and constant used to reach a user's ChatGPT subscription lives here.
//! Using ChatGPT-subscription OAuth from a distributed third-party app is not
//! sanctioned by OpenAI and may be blocked/changed at any time — quarantining it
//! here (plus the `callChatGpt` path on the JS side) keeps it easy to remove or
//! repair without touching the rest of the app.
//!
//! Secrets never leave Rust: the refresh token and access token are stored in the
//! OS keychain and the renderer only ever receives short-lived access tokens.

use base64::Engine;
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Protocol constants (unofficial — reused from Codex's public OAuth client)
// ---------------------------------------------------------------------------

const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const AUTHORIZE_URL: &str = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const REDIRECT_URI: &str = "http://localhost:1455/auth/callback";
const CALLBACK_ADDR: &str = "127.0.0.1:1455";
const SCOPE: &str = "openid profile email offline_access";
const ORIGINATOR: &str = "vellum";

const KEYRING_SERVICE: &str = "com.vellum.app";
const KEYRING_USER: &str = "chatgpt-oauth";

/// Refresh when the access token is within this many seconds of expiry.
const EXPIRY_SKEW_SECS: u64 = 60;

// ---------------------------------------------------------------------------
// Stored credential blob (keychain) + command return types
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
struct StoredTokens {
    access_token: String,
    refresh_token: String,
    /// Unix epoch seconds at which `access_token` expires.
    expires_at: u64,
    account_id: String,
    email: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct LoginResult {
    pub account_id: String,
    pub email: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AccessTokenResult {
    pub access_token: String,
    pub account_id: String,
}

#[derive(Debug, Serialize)]
pub struct OauthStatus {
    pub signed_in: bool,
    pub email: Option<String>,
    pub account_id: Option<String>,
}

// ---------------------------------------------------------------------------
// Token endpoint payloads
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    id_token: Option<String>,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn base64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn random_bytes(len: usize) -> Vec<u8> {
    use rand::RngCore;
    let mut buf = vec![0u8; len];
    rand::rngs::OsRng.fill_bytes(&mut buf);
    buf
}

fn sha256(input: &str) -> Vec<u8> {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hasher.finalize().to_vec()
}

// ---------------------------------------------------------------------------
// Keychain persistence
// ---------------------------------------------------------------------------

fn keyring_entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)
        .map_err(|e| format!("Failed to open keychain entry: {}", e))
}

fn save_tokens(tokens: &StoredTokens) -> Result<(), String> {
    let blob = serde_json::to_string(tokens)
        .map_err(|e| format!("Failed to serialize tokens: {}", e))?;
    keyring_entry()?
        .set_password(&blob)
        .map_err(|e| format!("Failed to save tokens to keychain: {}", e))
}

fn load_tokens() -> Result<Option<StoredTokens>, String> {
    match keyring_entry()?.get_password() {
        Ok(blob) => {
            let tokens = serde_json::from_str(&blob)
                .map_err(|e| format!("Corrupt token blob in keychain: {}", e))?;
            Ok(Some(tokens))
        }
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(format!("Failed to read tokens from keychain: {}", e)),
    }
}

fn clear_tokens() -> Result<(), String> {
    match keyring_entry()?.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(format!("Failed to delete tokens from keychain: {}", e)),
    }
}

// ---------------------------------------------------------------------------
// id_token (JWT) decoding
// ---------------------------------------------------------------------------

/// Extract `chatgpt_account_id` and `email` from an id_token's payload.
///
/// The account id lives under the custom `https://api.openai.com/auth` claim.
fn decode_id_token(id_token: &str) -> Result<(String, Option<String>), String> {
    let payload_b64 = id_token
        .split('.')
        .nth(1)
        .ok_or("id_token is not a well-formed JWT")?;
    let payload_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload_b64)
        .map_err(|e| format!("Failed to decode id_token payload: {}", e))?;
    let claims: serde_json::Value = serde_json::from_slice(&payload_bytes)
        .map_err(|e| format!("Failed to parse id_token claims: {}", e))?;

    let account_id = claims
        .get("https://api.openai.com/auth")
        .and_then(|auth| auth.get("chatgpt_account_id"))
        .and_then(|v| v.as_str())
        .ok_or("id_token is missing chatgpt_account_id")?
        .to_string();

    let email = claims
        .get("email")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    Ok((account_id, email))
}

// ---------------------------------------------------------------------------
// Loopback callback server
// ---------------------------------------------------------------------------

struct CallbackResult {
    code: String,
    state: String,
}

/// Bind the loopback listener, accept exactly one request, and parse the
/// `code`/`state` from the callback. Returns a success page to the browser.
fn wait_for_callback(listener: TcpListener) -> Result<CallbackResult, String> {
    let (mut stream, _) = listener
        .accept()
        .map_err(|e| format!("Failed to accept OAuth callback: {}", e))?;

    // Read just the request line (first line), which carries the query string.
    let mut buf = [0u8; 4096];
    let n = stream
        .read(&mut buf)
        .map_err(|e| format!("Failed to read OAuth callback request: {}", e))?;
    let request = String::from_utf8_lossy(&buf[..n]);
    let request_line = request.lines().next().unwrap_or("");

    // "GET /auth/callback?code=...&state=... HTTP/1.1"
    let path = request_line.split_whitespace().nth(1).unwrap_or("");
    let query = path.split_once('?').map(|(_, q)| q).unwrap_or("");

    let mut code: Option<String> = None;
    let mut state: Option<String> = None;
    let mut error: Option<String> = None;
    for pair in query.split('&') {
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        let decoded = urlencoding_decode(value);
        match key {
            "code" => code = Some(decoded),
            "state" => state = Some(decoded),
            "error" => error = Some(decoded),
            _ => {}
        }
    }

    let (body, response_body) = if error.is_some() || code.is_none() {
        (
            Err(format!(
                "Authorization failed: {}",
                error.unwrap_or_else(|| "no authorization code returned".to_string())
            )),
            "<html><body style=\"font-family:system-ui;text-align:center;padding-top:4rem\">\
             <h2>Sign-in failed</h2><p>You can close this tab and try again in Vellum.</p></body></html>",
        )
    } else {
        (
            Ok(()),
            "<html><body style=\"font-family:system-ui;text-align:center;padding-top:4rem\">\
             <h2>Signed in to ChatGPT</h2><p>You can close this tab and return to Vellum.</p></body></html>",
        )
    };

    let http = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        response_body.len(),
        response_body
    );
    let _ = stream.write_all(http.as_bytes());
    let _ = stream.flush();

    body?;

    Ok(CallbackResult {
        code: code.ok_or("Missing authorization code")?,
        state: state.unwrap_or_default(),
    })
}

/// Minimal percent-decoding for query-string values.
fn urlencoding_decode(input: &str) -> String {
    let bytes = input.replace('+', " ");
    let bytes = bytes.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hi, lo) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ---------------------------------------------------------------------------
// Token exchange / refresh (reqwest)
// ---------------------------------------------------------------------------

fn http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {}", e))
}

async fn exchange_code(code: &str, verifier: &str) -> Result<StoredTokens, String> {
    let params = [
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", REDIRECT_URI),
        ("client_id", CLIENT_ID),
        ("code_verifier", verifier),
    ];

    let resp = http_client()?
        .post(TOKEN_URL)
        .form(&params)
        .send()
        .await
        .map_err(|e| format!("Token request failed: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("Token endpoint returned {}: {}", status, text));
    }

    let token: TokenResponse = resp
        .json()
        .await
        .map_err(|e| format!("Failed to parse token response: {}", e))?;

    let id_token = token
        .id_token
        .ok_or("Token response is missing id_token")?;
    let (account_id, email) = decode_id_token(&id_token)?;

    Ok(StoredTokens {
        access_token: token.access_token,
        refresh_token: token
            .refresh_token
            .ok_or("Token response is missing refresh_token")?,
        expires_at: now_secs() + token.expires_in.unwrap_or(3600),
        account_id,
        email,
    })
}

async fn refresh_tokens(existing: &StoredTokens) -> Result<StoredTokens, String> {
    let params = [
        ("grant_type", "refresh_token"),
        ("refresh_token", existing.refresh_token.as_str()),
        ("client_id", CLIENT_ID),
    ];

    let resp = http_client()?
        .post(TOKEN_URL)
        .form(&params)
        .send()
        .await
        .map_err(|e| format!("Token refresh request failed: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("Token refresh returned {}: {}", status, text));
    }

    let token: TokenResponse = resp
        .json()
        .await
        .map_err(|e| format!("Failed to parse refresh response: {}", e))?;

    // A refresh response may omit id_token/refresh_token; keep prior values.
    let (account_id, email) = match &token.id_token {
        Some(id_token) => decode_id_token(id_token)?,
        None => (existing.account_id.clone(), existing.email.clone()),
    };

    Ok(StoredTokens {
        access_token: token.access_token,
        refresh_token: token
            .refresh_token
            .unwrap_or_else(|| existing.refresh_token.clone()),
        expires_at: now_secs() + token.expires_in.unwrap_or(3600),
        account_id,
        email,
    })
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

/// Run the full "Sign in with ChatGPT" flow: PKCE authorize → loopback callback
/// → token exchange → persist to keychain.
#[tauri::command]
pub async fn chatgpt_oauth_login() -> Result<LoginResult, String> {
    // 1. PKCE + state.
    let verifier = base64url(&random_bytes(64));
    let challenge = base64url(&sha256(&verifier));
    let state = base64url(&random_bytes(32));

    // 2. Bind the loopback listener before opening the browser so we can't miss
    //    the redirect.
    let listener = TcpListener::bind(CALLBACK_ADDR).map_err(|e| {
        format!(
            "Failed to start local sign-in server on {} (is another sign-in in progress?): {}",
            CALLBACK_ADDR, e
        )
    })?;

    let authorize_url = build_authorize_url(&challenge, &state);
    open::that(&authorize_url)
        .map_err(|e| format!("Failed to open the sign-in page in your browser: {}", e))?;

    // 3. Wait for the callback on a blocking thread.
    let expected_state = state.clone();
    let callback = tauri::async_runtime::spawn_blocking(move || wait_for_callback(listener))
        .await
        .map_err(|e| format!("Sign-in task failed: {}", e))??;

    if callback.state != expected_state {
        return Err("OAuth state mismatch — sign-in was rejected for safety.".to_string());
    }

    // 4-6. Exchange the code and persist.
    let tokens = exchange_code(&callback.code, &verifier).await?;
    save_tokens(&tokens)?;

    Ok(LoginResult {
        account_id: tokens.account_id,
        email: tokens.email,
    })
}

fn build_authorize_url(challenge: &str, state: &str) -> String {
    let mut url = url::Url::parse(AUTHORIZE_URL).expect("static authorize URL is valid");
    url.query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", CLIENT_ID)
        .append_pair("redirect_uri", REDIRECT_URI)
        .append_pair("scope", SCOPE)
        .append_pair("code_challenge", challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("state", state)
        .append_pair("id_token_add_organizations", "true")
        .append_pair("codex_cli_simplified_flow", "true")
        .append_pair("originator", ORIGINATOR);
    url.to_string()
}

/// Return a fresh short-lived access token + account id, refreshing if the
/// stored token is expired or close to expiry.
#[tauri::command]
pub async fn chatgpt_get_access_token() -> Result<AccessTokenResult, String> {
    let tokens = load_tokens()?.ok_or("Not signed in to ChatGPT.")?;

    if now_secs() + EXPIRY_SKEW_SECS < tokens.expires_at {
        return Ok(AccessTokenResult {
            access_token: tokens.access_token,
            account_id: tokens.account_id,
        });
    }

    let refreshed = refresh_tokens(&tokens).await?;
    save_tokens(&refreshed)?;
    Ok(AccessTokenResult {
        access_token: refreshed.access_token,
        account_id: refreshed.account_id,
    })
}

/// Report sign-in status for the settings UI.
#[tauri::command]
pub async fn chatgpt_oauth_status() -> Result<OauthStatus, String> {
    match load_tokens()? {
        Some(tokens) => Ok(OauthStatus {
            signed_in: true,
            email: tokens.email,
            account_id: Some(tokens.account_id),
        }),
        None => Ok(OauthStatus {
            signed_in: false,
            email: None,
            account_id: None,
        }),
    }
}

/// Sign out by deleting the stored credentials.
#[tauri::command]
pub async fn chatgpt_oauth_logout() -> Result<(), String> {
    clear_tokens()
}
