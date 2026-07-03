mod commands;
mod models;
mod pdf_annotations;
mod pdf_session;
mod web_archive;
mod web_page;

use commands::AppState;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use tauri::Manager;

/// Serve a captured subresource from an installed archive dir:
/// `/asset/<key>/<name>` -> `<app_data>/web/archives/<key>/assets/<name>`.
fn serve_archive_asset(data_dir: Option<&Path>, rest: &str) -> tauri::http::Response<Vec<u8>> {
    let not_found = || html_response(404, "<h1>Asset not found</h1>".to_string());

    let Some(data_dir) = data_dir else {
        return not_found();
    };
    let Some((key, name)) = rest.split_once('/') else {
        return not_found();
    };
    // Keys are sha256 hex; names are flat generated file names. Anything else
    // is rejected (path traversal guard).
    if key.is_empty()
        || !key.chars().all(|c| c.is_ascii_hexdigit())
        || name.is_empty()
        || name.contains("..")
        || name.contains('/')
        || name.contains('\\')
        || name.starts_with('.')
    {
        return not_found();
    }

    let path = web_archive::archive_dir(data_dir, key).join("assets").join(name);
    match std::fs::read(&path) {
        Ok(bytes) => tauri::http::Response::builder()
            .status(200)
            .header("Content-Type", web_archive::content_type_for_name(name))
            .header("Cache-Control", "public, max-age=604800")
            .body(bytes)
            .unwrap_or_else(|_| tauri::http::Response::new(Vec::new())),
        Err(_) => not_found(),
    }
}

/// Serve the installed self-contained snapshot (from a .vellumweb import or
/// export), with asset placeholders resolved to proxy asset URLs.
fn serve_installed_snapshot(
    data_dir: Option<&Path>,
    key: &str,
    page_url: &str,
    asset_base: &str,
) -> Option<tauri::http::Response<Vec<u8>>> {
    let data_dir = data_dir?;
    let html =
        std::fs::read_to_string(web_archive::archive_dir(data_dir, key).join("snapshot.html"))
            .ok()?;
    let resolved = web_archive::resolve_asset_placeholders(
        &html,
        &format!("{}/asset/{}", asset_base, key),
    );
    Some(html_response(
        200,
        web_page::prepare_html(&resolved, page_url, true),
    ))
}

/// Serve a proxied webpage for the `vellum-web://` iframe protocol.
/// Routes: `/?url=<encoded-url>` (page loads) and `/asset/<key>/<name>`
/// (subresources of installed .vellumweb snapshots).
async fn handle_vellum_web_request(
    app: tauri::AppHandle,
    uri: tauri::http::Uri,
) -> tauri::http::Response<Vec<u8>> {
    let data_dir = app.path().app_data_dir().ok();

    if let Some(rest) = uri.path().strip_prefix("/asset/") {
        return serve_archive_asset(data_dir.as_deref(), rest);
    }

    let raw_url = uri.query().and_then(|query| {
        url::form_urlencoded::parse(query.as_bytes())
            .find(|(key, _)| key == "url")
            .map(|(_, value)| value.into_owned())
    });

    let Some(raw_url) = raw_url else {
        return html_response(404, "<h1>Missing url parameter</h1>".to_string());
    };

    let page_url = match web_page::normalize_url(&raw_url) {
        Ok(url) => url,
        Err(e) => {
            return html_response(
                400,
                web_page::prepare_html(&web_page::error_page(&raw_url, &e), &raw_url, false),
            )
        }
    };

    // Base for absolute asset URLs inside served snapshots, matching however
    // this webview addresses the protocol on the current platform.
    let asset_base = match (uri.scheme_str(), uri.authority()) {
        (Some(scheme), Some(authority)) => format!("{}://{}", scheme, authority),
        _ => "vellum-web://localhost".to_string(),
    };

    // Sidecar state drives snapshot refresh and the loading policy.
    let key = web_page::page_key(&page_url);
    let snapshot_file = data_dir
        .as_deref()
        .map(|dir| web_page::store_dir(dir).join(format!("{}.snapshot.html", key)));
    let record = data_dir
        .as_deref()
        .and_then(|dir| web_page::load_record(&web_page::store_dir(dir).join(format!("{}.json", key))));
    let record_saved = record.as_ref().map(|r| r.saved).unwrap_or(false);
    let snapshot_only = record
        .as_ref()
        .and_then(|r| r.loading_policy.as_deref())
        == Some("snapshot-only");

    // Pinned-snapshot policy (from an imported archive): don't hit the
    // network at all when the installed snapshot is available.
    if snapshot_only {
        if let Some(response) =
            serve_installed_snapshot(data_dir.as_deref(), &key, &page_url, &asset_base)
        {
            return response;
        }
    }

    match web_page::fetch_page(&page_url).await {
        Ok(web_page::FetchedPage::Html { html, final_url }) => {
            // Redirects change the page's effective identity (http -> https,
            // moved articles): serve under the final URL so relative
            // subresources resolve correctly and the app shell can rebind
            // the tab to the canonical address.
            let effective_url = web_page::normalize_url(&final_url)
                .unwrap_or_else(|_| page_url.clone());

            // Keep the offline snapshot of saved pages fresh on every
            // successful visit, under the effective identity.
            if effective_url == page_url {
                if record_saved {
                    if let Some(snapshot_file) = &snapshot_file {
                        web_page::write_snapshot_atomic(snapshot_file, &html);
                    }
                }
            } else if let Some(dir) = data_dir.as_deref() {
                let effective_key = web_page::page_key(&effective_url);
                let effective_record = web_page::load_record(
                    &web_page::store_dir(dir).join(format!("{}.json", effective_key)),
                );
                if effective_record.map(|r| r.saved).unwrap_or(false) {
                    web_page::write_snapshot_atomic(
                        &web_page::store_dir(dir)
                            .join(format!("{}.snapshot.html", effective_key)),
                        &html,
                    );
                }
            }

            html_response(200, web_page::prepare_html(&html, &effective_url, false))
        }
        Ok(web_page::FetchedPage::Other { content_type, body }) => {
            tauri::http::Response::builder()
                .status(200)
                .header("Content-Type", content_type)
                .header("Cache-Control", "no-store")
                .body(body)
                .unwrap_or_else(|_| tauri::http::Response::new(Vec::new()))
        }
        Err(fetch_error) => {
            // Offline / link-rot fallback: prefer the self-contained
            // .vellumweb snapshot, then the plain saved snapshot.
            if let Some(response) =
                serve_installed_snapshot(data_dir.as_deref(), &key, &page_url, &asset_base)
            {
                return response;
            }
            let snapshot = snapshot_file
                .as_deref()
                .and_then(|path| std::fs::read_to_string(path).ok());
            match snapshot {
                Some(html) => html_response(200, web_page::prepare_html(&html, &page_url, true)),
                None => html_response(
                    502,
                    web_page::prepare_html(
                        &web_page::error_page(&page_url, &fetch_error),
                        &page_url,
                        false,
                    ),
                ),
            }
        }
    }
}

fn html_response(status: u16, body: String) -> tauri::http::Response<Vec<u8>> {
    tauri::http::Response::builder()
        .status(status)
        .header("Content-Type", "text/html; charset=utf-8")
        .header("Cache-Control", "no-store")
        .body(body.into_bytes())
        .unwrap_or_else(|_| tauri::http::Response::new(Vec::new()))
}

#[cfg(test)]
mod protocol_tests {
    use super::*;

    fn install_asset(data_dir: &std::path::Path, key: &str, name: &str, bytes: &[u8]) {
        let dir = web_archive::archive_dir(data_dir, key).join("assets");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(name), bytes).unwrap();
    }

    #[test]
    fn archive_assets_are_served_with_content_type() {
        let tmp = tempfile::tempdir().unwrap();
        let key = "abc123def456";
        install_asset(tmp.path(), key, "a0.css", b"body{}");

        let response = serve_archive_asset(Some(tmp.path()), &format!("{}/a0.css", key));
        assert_eq!(response.status(), 200);
        assert_eq!(
            response.headers().get("Content-Type").unwrap(),
            "text/css"
        );
        assert_eq!(response.body(), b"body{}");
    }

    #[test]
    fn asset_route_rejects_traversal_and_bad_keys() {
        let tmp = tempfile::tempdir().unwrap();
        let key = "abc123def456";
        install_asset(tmp.path(), key, "a0.css", b"body{}");

        for rest in [
            format!("{}/../{}/a0.css", key, key),
            format!("{}/..%2Fa0.css", key),
            format!("{}/.hidden", key),
            "not-hex-key!/a0.css".to_string(),
            format!("{}/", key),
            key.to_string(), // no name at all
        ] {
            let response = serve_archive_asset(Some(tmp.path()), &rest);
            assert_eq!(response.status(), 404, "should reject {:?}", rest);
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .manage(AppState {
            sessions: Mutex::new(HashMap::new()),
        })
        .register_asynchronous_uri_scheme_protocol("vellum-web", |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            let uri = request.uri().clone();
            tauri::async_runtime::spawn(async move {
                responder.respond(handle_vellum_web_request(app, uri).await);
            });
        });

    #[cfg(desktop)]
    let builder = builder.plugin(tauri_plugin_process::init());

    builder
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            #[cfg(desktop)]
            app.handle()
                .plugin(tauri_plugin_updater::Builder::new().build())?;

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::open_file,
            commands::open_web_document,
            commands::save_file,
            commands::close_file,
            commands::read_pdf_bytes,
            commands::get_annotations,
            commands::create_annotation,
            commands::update_annotation,
            commands::delete_annotation,
            commands::set_document_metadata,
            commands::set_webpage_saved,
            commands::get_webpage_saved,
            commands::list_saved_webpages,
            commands::remove_saved_webpage,
            commands::export_vellumweb,
            commands::open_vellumweb_file,
            commands::archive_webpage_default,
            commands::run_codex_ai,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
