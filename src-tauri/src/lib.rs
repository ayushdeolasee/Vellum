mod commands;
mod models;
mod oauth;
mod pdf_annotations;
mod pdf_session;

use commands::AppState;
use std::collections::HashMap;
use std::sync::Mutex;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_http::init())
        .manage(AppState {
            sessions: Mutex::new(HashMap::new()),
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
            commands::save_file,
            commands::close_file,
            commands::read_pdf_bytes,
            commands::get_annotations,
            commands::create_annotation,
            commands::update_annotation,
            commands::delete_annotation,
            commands::set_document_metadata,
            oauth::chatgpt_oauth_login,
            oauth::chatgpt_get_access_token,
            oauth::chatgpt_oauth_status,
            oauth::chatgpt_oauth_logout,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
