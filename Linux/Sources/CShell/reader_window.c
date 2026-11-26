#include "reader_settings.h"

struct ReaderWindow {
    GtkWindow *window;
    GtkListBox *list;
    GtkWidget *pdf_page;
    PdfAnnotations *annotations;
    GtkEventController *keys;
    GtkWidget *search, *no_matches;
    GtkWidget *title, *page, *previous, *next, *message, *picture, *stack, *status;
    GtkStack *screens;
    GtkWidget *paging, *body, *settings_button;
    ReaderSettings *settings;
    ScratchpadPanel *scratchpad;
    ReaderCallback callback;
    void *context;
    gboolean closing, drained;
};

static void notify(ReaderWindow *r, ReaderEvent event, int entry) {
    g_assert(shell_on_gtk_thread());
    r->callback(r, event, entry, NULL, r->context);
}

static void selected(GtkListBox *list, GtkListBoxRow *row, ReaderWindow *r) {
    if (row && !r->closing)
        notify(r, READER_SELECT, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "entry-id")) - 1);
}

static void search_changed(GtkEditable *entry, ReaderWindow *r) {
    if (!r->closing && gtk_widget_get_sensitive(r->search)) notify(r, READER_SEARCH, -1);
}

static void search_activated(GtkSearchEntry *entry, ReaderWindow *r) {
    GtkListBoxRow *first = gtk_list_box_get_row_at_index(r->list, 0);
    if (!r->closing && first && *gtk_editable_get_text(GTK_EDITABLE(entry)))
        gtk_list_box_select_row(r->list, first);
}

static void search_stopped(GtkSearchEntry *entry, ReaderWindow *r) {
    if (!r->closing) gtk_editable_set_text(GTK_EDITABLE(entry), "");
}

static gboolean focus_search(GtkEventControllerKey *controller, guint key, guint keycode,
                             GdkModifierType state, ReaderWindow *r) {
    GdkModifierType modifiers = state & gtk_accelerator_get_default_mod_mask();
    if (!r->closing && gtk_stack_get_visible_child(r->screens) == r->body &&
        key == GDK_KEY_f && modifiers == GDK_CONTROL_MASK)
        return gtk_widget_grab_focus(r->search);
    return FALSE;
}

static void clicked(GtkButton *button, ReaderWindow *r) {
    if (!r->closing)
        notify(r, GTK_WIDGET(button) == r->previous ? READER_PREVIOUS : READER_NEXT, -1);
}

// close-request, window removal and application shutdown can arrive in any
// order. Invalidate the Swift generation synchronously, exactly once.
static void begin_close(ReaderWindow *r) {
    if (!r->window || r->closing) return;
    r->closing = TRUE;
    reader_settings_dismiss(r->settings);
    notify(r, READER_CLOSE, -1);
}

static void window_removed(GtkApplication *app, GtkWindow *window, ReaderWindow *r) {
    if (window == r->window) begin_close(r);
}

static gboolean close_requested(GtkWindow *window, ReaderWindow *r) {
    if (!r->closing) notify(r, READER_CLOSE_REQUEST, -1);
    return TRUE;
}

ScratchpadPanel *reader_scratchpad_panel(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    return r->scratchpad;
}

void reader_set_close_pending(ReaderWindow *r, bool pending) {
    g_assert(shell_on_gtk_thread());
    if (!r->closing) gtk_widget_set_sensitive(GTK_WIDGET(r->window), !pending);
}

void reader_commit_close(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    reader_set_close_pending(r, true);
    begin_close(r);
}

GtkStack *reader_content_stack(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    return GTK_STACK(r->stack);
}

PdfAnnotations *reader_pdf_annotations(ReaderWindow *r) { return r->annotations; }

void reader_pdf_editable(ReaderWindow *r) { gtk_label_set_text(GTK_LABEL(r->status), "PDF open · Editing enabled"); }
ReaderSettings *reader_settings(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    return r->settings;
}

void reader_finish_close(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread() && r->closing);
    gtk_window_destroy(r->window);
    r->drained = TRUE;
}

void reader_enable_search(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    gtk_widget_set_sensitive(r->search, TRUE);
}

void reader_reset_search(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    gtk_widget_set_sensitive(r->search, FALSE);
    gtk_editable_set_text(GTK_EDITABLE(r->search), "");
    reader_clear_rows(r);
}

const char *reader_search_query(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    return gtk_editable_get_text(GTK_EDITABLE(r->search));
}

void reader_clear_rows(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    gtk_list_box_remove_all(r->list);
    gtk_widget_set_visible(r->no_matches, FALSE);
}

void reader_show_no_matches(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    gtk_widget_set_visible(r->no_matches, TRUE);
}

static GtkWidget *row_label(const char *text) {
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    return label;
}

void reader_add_row(ReaderWindow *r, int entry, const char *title, const char *filename) {
    g_assert(shell_on_gtk_thread());
    GtkWidget *row = gtk_list_box_row_new();
    g_object_set_data(G_OBJECT(row), "entry-id", GINT_TO_POINTER(entry + 1));
    gtk_widget_set_tooltip_text(row, filename);
    GtkWidget *label = row_label(title);
    if (g_strcmp0(title, filename) != 0) {
        GtkWidget *labels = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        GtkWidget *subtitle = row_label(filename);
        gtk_widget_add_css_class(subtitle, "dim-label");
        gtk_box_append(GTK_BOX(labels), label);
        gtk_box_append(GTK_BOX(labels), subtitle);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), labels);
    } else {
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), label);
    }
    gtk_list_box_append(r->list, row);
}

void reader_select_row(ReaderWindow *r, int index) {
    g_assert(shell_on_gtk_thread());
    gtk_list_box_select_row(r->list, gtk_list_box_get_row_at_index(r->list, index));
}

static void set_title(ReaderWindow *r, const char *title) {
    gtk_label_set_text(GTK_LABEL(r->title), title);
    if (gtk_stack_get_visible_child(r->screens) == r->body)
        gtk_window_set_title(r->window, title);
}

void reader_set_position(ReaderWindow *r, int number, int count) {
    g_assert(shell_on_gtk_thread());
    g_autofree char *position = count ? g_strdup_printf("Page %d of %d", number, count) : NULL;
    gtk_label_set_text(GTK_LABEL(r->page), position ? position : "");
    gboolean previous = count > 0 && number > 1, next = number < count;
    GtkWidget *focus = gtk_window_get_focus(r->window);
    if (previous) gtk_widget_set_sensitive(r->previous, TRUE);
    if (next) gtk_widget_set_sensitive(r->next, TRUE);
    if (focus == r->previous && !previous && next) gtk_widget_grab_focus(r->next);
    if (focus == r->next && !next && previous) gtk_widget_grab_focus(r->previous);
    if (!previous) gtk_widget_set_sensitive(r->previous, FALSE);
    if (!next) gtk_widget_set_sensitive(r->next, FALSE);
}

void reader_page_message(ReaderWindow *r, const char *title, const char *message, int number, int count) {
    g_assert(shell_on_gtk_thread());
    set_title(r, title);
    gtk_picture_set_paintable(GTK_PICTURE(r->picture), NULL);
    gtk_label_set_text(GTK_LABEL(r->message), message);
    gtk_stack_set_visible_child(reader_content_stack(r), r->message);
    reader_set_position(r, number, count);
    gtk_label_set_text(GTK_LABEL(r->status), "Read-only library");
}

void reader_web_ready(ReaderWindow *r, const char *title, const char *position) {
    g_assert(shell_on_gtk_thread());
    set_title(r, title);
    gtk_label_set_text(GTK_LABEL(r->page), position);
    gtk_label_set_text(GTK_LABEL(r->status), "Offline archive · Read only");
}

void reader_set_message(ReaderWindow *r, const char *title, const char *message) {
    reader_page_message(r, title, message, 0, 0);
}

void reader_set_page(ReaderWindow *r, const char *title, int number, int count,
                     const uint8_t *pixels, int width, int height, size_t stride) {
    g_assert(shell_on_gtk_thread());
    // The bounded PDFium bitmap is borrowed for this call. GBytes owns the
    // copy, the texture retains the bytes and GtkPicture retains the texture.
    g_autoptr(GBytes) bytes = g_bytes_new(pixels, stride * height);
    g_autoptr(GdkTexture) texture = gdk_memory_texture_new(width, height,
                                      GDK_MEMORY_B8G8R8A8, bytes, stride);
    gtk_picture_set_paintable(GTK_PICTURE(r->picture), GDK_PAINTABLE(texture));
    gtk_stack_set_visible_child(reader_content_stack(r), r->pdf_page);
    set_title(r, title);
    reader_set_position(r, number, count);
    gtk_label_set_text(GTK_LABEL(r->status), "PDF open · Read only");
}

static GtkWidget *page_button(const char *icon, const char *name, ReaderWindow *r) {
    GtkWidget *button = gtk_button_new_from_icon_name(icon);
    gtk_widget_set_tooltip_text(button, name);
    gtk_accessible_update_property(GTK_ACCESSIBLE(button), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
    g_signal_connect(button, "clicked", G_CALLBACK(clicked), r);
    return button;
}

static void show_settings(GSimpleAction *action, GVariant *parameter, ReaderWindow *r) {
    if (r->closing) return;
    gtk_stack_set_visible_child(r->screens, reader_settings_page(r->settings));
    gtk_widget_set_visible(r->title, FALSE);
    gtk_widget_set_visible(r->paging, FALSE);
    gtk_widget_set_visible(r->settings_button, FALSE);
    gtk_window_set_title(r->window, "Vellum Settings");
}

static void settings_event(ReaderWindow *r, ReaderEvent event, int index, const char *text, void *unused) {
    g_assert(shell_on_gtk_thread());
    if (r->closing) return;
    if (event == READER_SETTINGS_DONE) {
        reader_settings_dismiss(r->settings);
        gtk_stack_set_visible_child(r->screens, r->body);
        gtk_widget_set_visible(r->title, TRUE);
        gtk_widget_set_visible(r->paging, TRUE);
        gtk_widget_set_visible(r->settings_button, TRUE);
        gtk_window_set_title(r->window, gtk_label_get_text(GTK_LABEL(r->title)));
    } else {
        r->callback(r, event, index, text, r->context);
    }
}

// Settings and document panels can register with the same window action map.
static void add_window_action(ReaderWindow *r, const char *name, GCallback activate) {
    g_autoptr(GSimpleAction) action = g_simple_action_new(name, NULL);
    g_signal_connect(action, "activate", activate, r);
    g_action_map_add_action(G_ACTION_MAP(r->window), G_ACTION(action));
}

static void activated(GtkApplication *app, ReaderWindow *r) {
    if (r->closing) return;
    if (r->window) {
        gtk_window_present(r->window);
        return;
    }
    r->window = GTK_WINDOW(gtk_application_window_new(app));
    // GTK drops its toplevel reference on programmatic destroy. Keep the
    // window and its child hierarchy alive until the controller has drained.
    g_object_ref(r->window);
    gtk_window_set_default_size(r->window, 960, 640);
    g_signal_connect(r->window, "close-request", G_CALLBACK(close_requested), r);

    GtkWidget *header = gtk_header_bar_new();
    r->title = gtk_label_new(NULL);
    gtk_label_set_ellipsize(GTK_LABEL(r->title), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(r->title, "title");
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), r->title);
    add_window_action(r, "settings", G_CALLBACK(show_settings));
    r->settings_button = gtk_button_new_with_label("Settings");
    gtk_actionable_set_action_name(GTK_ACTIONABLE(r->settings_button), "win.settings");
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), r->settings_button);
    r->paging = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    r->previous = page_button("go-previous-symbolic", "Previous page", r);
    r->next = page_button("go-next-symbolic", "Next page", r);
    r->page = gtk_label_new(NULL);
    gtk_box_append(GTK_BOX(r->paging), r->previous);
    gtk_box_append(GTK_BOX(r->paging), r->page);
    gtk_box_append(GTK_BOX(r->paging), r->next);
    r->scratchpad = scratchpad_panel_new();
    gtk_box_append(GTK_BOX(r->paging), scratchpad_panel_toggle(r->scratchpad));
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), r->paging);
    gtk_window_set_titlebar(r->window, header);

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    r->body = body;
    r->screens = GTK_STACK(gtk_stack_new());
    gtk_stack_set_hhomogeneous(r->screens, FALSE);
    gtk_stack_set_vhomogeneous(r->screens, FALSE);
    gtk_window_set_child(r->window, GTK_WIDGET(r->screens));
    gtk_stack_add_child(r->screens, body);
    r->settings = reader_settings_new(r->window, r, settings_event);
    gtk_stack_add_child(r->screens, reader_settings_page(r->settings));
    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_vexpand(paned, TRUE);
    gtk_box_append(GTK_BOX(body), paned);
    GtkWidget *sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    r->search = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(r->search), "Search library");
    gtk_accessible_update_property(GTK_ACCESSIBLE(r->search), GTK_ACCESSIBLE_PROPERTY_LABEL, "Search library", -1);
    gtk_widget_set_margin_start(r->search, 6);
    gtk_widget_set_margin_end(r->search, 6);
    gtk_widget_set_margin_top(r->search, 6);
    gtk_widget_set_sensitive(r->search, FALSE);
    gtk_box_append(GTK_BOX(sidebar), r->search);
    // Editable's immediate change signal clears old results before Enter can use them.
    g_signal_connect(r->search, "changed", G_CALLBACK(search_changed), r);
    g_signal_connect(r->search, "activate", G_CALLBACK(search_activated), r);
    g_signal_connect(r->search, "stop-search", G_CALLBACK(search_stopped), r);
    r->keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(r->keys, GTK_PHASE_CAPTURE);
    g_signal_connect(r->keys, "key-pressed", G_CALLBACK(focus_search), r);
    gtk_widget_add_controller(GTK_WIDGET(r->window), r->keys);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    r->list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(r->list, GTK_SELECTION_SINGLE);
    gtk_widget_add_css_class(GTK_WIDGET(r->list), "navigation-sidebar");
    r->no_matches = gtk_label_new("No matching documents");
    gtk_widget_add_css_class(r->no_matches, "dim-label");
    gtk_widget_set_margin_top(r->no_matches, 8);
    gtk_widget_set_visible(r->no_matches, FALSE);
    gtk_box_append(GTK_BOX(sidebar), r->no_matches);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(r->list));
    gtk_box_append(GTK_BOX(sidebar), scroll);
    gtk_paned_set_start_child(GTK_PANED(paned), sidebar);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_position(GTK_PANED(paned), 220);
    g_signal_connect(r->list, "row-selected", G_CALLBACK(selected), r);

    GtkWidget *reader_area = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    r->stack = gtk_stack_new();
    gtk_widget_set_hexpand(r->stack, TRUE);
    gtk_box_append(GTK_BOX(reader_area), r->stack);
    gtk_box_append(GTK_BOX(reader_area), scratchpad_panel_widget(r->scratchpad));
    gtk_paned_set_end_child(GTK_PANED(paned), reader_area);
    r->message = gtk_label_new(NULL);
    gtk_label_set_wrap(GTK_LABEL(r->message), TRUE);
    gtk_stack_add_child(reader_content_stack(r), r->message);
    r->picture = gtk_picture_new();
    gtk_picture_set_content_fit(GTK_PICTURE(r->picture), GTK_CONTENT_FIT_CONTAIN);
    r->pdf_page = pdf_annotations_new(r->picture, &r->annotations);
    gtk_stack_add_child(reader_content_stack(r), r->pdf_page);
    gtk_box_append(GTK_BOX(body), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    r->status = gtk_label_new(NULL);
    gtk_widget_set_margin_top(r->status, 5);
    gtk_widget_set_margin_bottom(r->status, 5);
    gtk_box_append(GTK_BOX(body), r->status);
    reader_set_message(r, "Vellum", "Opening library…");
    gtk_window_present(r->window);
    notify(r, READER_OPEN, -1);
}

int reader_run(ReaderCallback callback, void *context) {
    g_assert(shell_on_gtk_thread());
    ReaderWindow reader = { .callback = callback, .context = context };
    g_autoptr(GtkApplication) app = gtk_application_new("org.vellum.Reader", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activated), &reader);
    g_signal_connect(app, "window-removed", G_CALLBACK(window_removed), &reader);
    g_signal_connect_swapped(app, "shutdown", G_CALLBACK(begin_close), &reader);
    int status = g_application_run(G_APPLICATION(app), 0, NULL);
    // g_application_quit() exits even when a window or a worker is pending.
    // Keep the GLib/Swift pump, callback context and window alive until CLOSE
    // has joined outstanding requests and shut down PDFium.
    begin_close(&reader);
    while (reader.closing && !reader.drained)
        g_main_context_iteration(NULL, TRUE);
    g_signal_handlers_disconnect_by_data(app, &reader);
    if (reader.window) {
        g_signal_handlers_disconnect_by_data(reader.window, &reader);
        g_signal_handlers_disconnect_by_data(reader.keys, &reader);
        g_signal_handlers_disconnect_by_data(reader.list, &reader);
        g_signal_handlers_disconnect_by_data(reader.search, &reader);
        g_signal_handlers_disconnect_by_data(reader.previous, &reader);
        g_signal_handlers_disconnect_by_data(reader.next, &reader);
        g_clear_object(&reader.window);
        reader_settings_free(reader.settings);
    }
    return status;
}
