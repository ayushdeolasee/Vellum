#include "web_reader.h"
#include <webkit/webkit.h>
#include <string.h>

static const char world[] = "VellumReader";
static const char policy[] =
    "default-src 'none'; base-uri 'none'; form-action 'none'; "
    "img-src vellum-web: data:; style-src vellum-web: 'unsafe-inline'; font-src vellum-web: data:";

struct WebReader {
    GtkStack *stack;
    GtkWidget *box;
    WebKitWebView *view;
    char *uri;
    WebResource resource;
    WebEvent message, denied;
    void *owner;
};

void web_reader_respond(WebKitURISchemeRequest *request, const char *mime,
                        const void *bytes, size_t count) {
    g_autoptr(GBytes) copy = g_bytes_new(bytes, count);
    g_autoptr(GInputStream) stream = g_memory_input_stream_new_from_bytes(copy);
    g_autoptr(WebKitURISchemeResponse) response = webkit_uri_scheme_response_new(stream, count);
    SoupMessageHeaders *headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    soup_message_headers_append(headers, "Cache-Control", "no-store");
    soup_message_headers_append(headers, "X-Content-Type-Options", "nosniff");
    webkit_uri_scheme_response_set_http_headers(response, headers); // takes ownership
    webkit_uri_scheme_response_set_content_type(response, mime);
    webkit_uri_scheme_response_set_status(response, 200, NULL);
    webkit_uri_scheme_request_finish_with_response(request, response);
}

static void request_resource(WebKitURISchemeRequest *request, gpointer unused) {
    // WebKit can retain the context after widget removal. Resolve the owner
    // through the requesting view, cleared synchronously on selection/close.
    WebKitWebView *view = webkit_uri_scheme_request_get_web_view(request);
    WebReader *r = view ? g_object_get_data(G_OBJECT(view), world) : NULL;
    if (r && r->resource(r->owner, webkit_uri_scheme_request_get_uri(request), request)) return;
    g_autoptr(GError) error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "Archive resource unavailable");
    webkit_uri_scheme_request_finish_error(request, error);
}

static gboolean decide(WebKitWebView *view, WebKitPolicyDecision *decision,
                       WebKitPolicyDecisionType type, WebReader *r) {
    if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) return FALSE;
    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(
        WEBKIT_NAVIGATION_POLICY_DECISION(decision));
    const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
    // Internal text anchors remain usable. All other navigations and popups are denied.
    size_t length = strcspn(uri, "#");
    if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
        length == strlen(r->uri) && strncmp(r->uri, uri, length) == 0) return FALSE;
    webkit_policy_decision_ignore(decision);
    if (r->denied) r->denied(r->owner, uri);
    return TRUE;
}

static void received(WebKitUserContentManager *manager, JSCValue *value, WebReader *r) {
    g_autofree char *json = jsc_value_to_json(value, 0);
    if (json) r->message(r->owner, json);
}

static void show_error(WebReader *r) {
    if (!gtk_widget_get_visible(GTK_WIDGET(r->view))) return;
    gtk_widget_set_visible(GTK_WIDGET(r->view), FALSE);
    gtk_box_append(GTK_BOX(r->box), gtk_label_new("Could not display the offline archive."));
}

static gboolean failed(WebKitWebView *view, WebKitLoadEvent event, const char *uri,
                       GError *error, WebReader *r) {
    if (g_strcmp0(uri, r->uri) == 0 &&
        !g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED))
        show_error(r);
    return TRUE;
}

static void terminated(WebKitWebView *view, WebKitWebProcessTerminationReason reason, WebReader *r) {
    show_error(r);
}

static void cancel_download(WebKitNetworkSession *session, WebKitDownload *download, gpointer unused) {
    webkit_download_cancel(download);
}

WebReader *web_reader_new(GtkStack *stack, const char *uri, bool ink, const char *script,
                          WebResource resource, WebEvent message, WebEvent denied, void *owner) {
    WebReader *r = g_new0(WebReader, 1);
    r->stack = stack;
    r->uri = g_strdup(uri);
    r->resource = resource;
    r->message = message;
    r->denied = denied;
    r->owner = owner;
    g_autoptr(WebKitWebContext) context = webkit_web_context_new();
    webkit_web_context_register_uri_scheme(context, "vellum-web", request_resource, NULL, NULL);
    g_autoptr(WebKitNetworkSession) session = webkit_network_session_new_ephemeral();
    g_signal_connect(session, "download-started", G_CALLBACK(cancel_download), NULL);
    g_autoptr(WebKitUserContentManager) manager = webkit_user_content_manager_new();
    g_signal_connect(manager, "script-message-received::vellum", G_CALLBACK(received), r);
    gboolean registered = webkit_user_content_manager_register_script_message_handler(manager, "vellum", world);
    g_assert(registered);
    g_autoptr(WebKitUserScript) injected = webkit_user_script_new_for_world(script,
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, world, NULL, NULL);
    webkit_user_content_manager_add_script(manager, injected);
    g_autoptr(WebKitSettings) settings = webkit_settings_new();
    webkit_settings_set_enable_javascript_markup(settings, FALSE);
    webkit_settings_set_enable_page_cache(settings, FALSE);
    r->view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", context, "network-session", session,
        "user-content-manager", manager, "settings", settings, "default-content-security-policy", policy, NULL);
    g_object_set_data(G_OBJECT(r->view), world, r);
    g_signal_connect(r->view, "decide-policy", G_CALLBACK(decide), r);
    g_signal_connect(r->view, "load-failed", G_CALLBACK(failed), r);
    g_signal_connect(r->view, "web-process-terminated", G_CALLBACK(terminated), r);

    r->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    if (ink) {
        GtkWidget *badge = gtk_label_new("Has handwriting: view on iPad/Mac");
        gtk_widget_set_margin_top(badge, 8);
        gtk_widget_set_margin_bottom(badge, 8);
        gtk_box_append(GTK_BOX(r->box), badge);
    }
    gtk_widget_set_vexpand(GTK_WIDGET(r->view), TRUE);
    gtk_box_append(GTK_BOX(r->box), GTK_WIDGET(r->view));
    gtk_stack_add_child(stack, r->box);
    gtk_stack_set_visible_child(stack, r->box);
    webkit_web_view_load_uri(r->view, r->uri);
    return r;
}

void web_reader_free(WebReader *r) {
    WebKitUserContentManager *manager = webkit_web_view_get_user_content_manager(r->view);
    g_object_set_data(G_OBJECT(r->view), world, NULL);
    g_signal_handlers_disconnect_by_data(manager, r);
    g_signal_handlers_disconnect_by_data(r->view, r);
    webkit_user_content_manager_unregister_script_message_handler(manager, "vellum", world);
    webkit_web_view_stop_loading(r->view);
    gtk_stack_remove(r->stack, r->box);
    g_free(r->uri);
    g_free(r);
}

typedef struct {
    WebEvent reply;
    void *owner;
} LocationReply;

static void location_ready(GObject *view, GAsyncResult *result, gpointer data) {
    g_autofree LocationReply *reply = data;
    g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(view), result, NULL);
    g_autofree char *json = value && jsc_value_is_object(value) ? jsc_value_to_json(value, 0) : NULL;
    reply->reply(reply->owner, json);
}

void web_reader_location(WebReader *r, WebEvent callback, void *owner) {
    LocationReply *reply = g_new(LocationReply, 1);
    *reply = (LocationReply){callback, owner};
    webkit_web_view_evaluate_javascript(r->view, "window.vellumLocation?.()", -1, world,
                                        NULL, NULL, location_ready, reply);
}
