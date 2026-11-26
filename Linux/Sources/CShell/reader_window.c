#include "CShell.h"
#include <gtk/gtk.h>

struct ReaderWindow {
    GtkWindow *window;
    GtkListBox *list;
    GtkWidget *title, *page, *previous, *next, *message, *picture, *stack, *status;
    ReaderCallback callback;
    void *context;
    gboolean closing, drained;
};

static void notify(ReaderWindow *r, ReaderEvent event, int row) {
    g_assert(shell_on_gtk_thread());
    r->callback(r, event, row, r->context);
}

static void selected(GtkListBox *list, GtkListBoxRow *row, ReaderWindow *r) {
    if (row && !r->closing) notify(r, READER_SELECT, gtk_list_box_row_get_index(row));
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
    notify(r, READER_CLOSE, -1);
}

static void window_removed(GtkApplication *app, GtkWindow *window, ReaderWindow *r) {
    if (window == r->window) begin_close(r);
}

static gboolean close_requested(GtkWindow *window, ReaderWindow *r) {
    gtk_widget_set_sensitive(GTK_WIDGET(window), FALSE);
    begin_close(r);
    return TRUE;
}

GtkStack *reader_content_stack(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread());
    return GTK_STACK(r->stack);
}

void reader_finish_close(ReaderWindow *r) {
    g_assert(shell_on_gtk_thread() && r->closing);
    gtk_window_destroy(r->window);
    r->drained = TRUE;
}

void reader_add_row(ReaderWindow *r, const char *name) {
    g_assert(shell_on_gtk_thread());
    GtkWidget *label = gtk_label_new(name);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_widget_set_tooltip_text(label, name);
    gtk_list_box_append(r->list, label);
}

void reader_select_row(ReaderWindow *r, int index) {
    g_assert(shell_on_gtk_thread());
    gtk_list_box_select_row(r->list, gtk_list_box_get_row_at_index(r->list, index));
}

static void set_title(ReaderWindow *r, const char *title) {
    gtk_window_set_title(r->window, title);
    gtk_label_set_text(GTK_LABEL(r->title), title);
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
    gtk_stack_set_visible_child(reader_content_stack(r), r->picture);
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
    GtkWidget *controls = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    r->previous = page_button("go-previous-symbolic", "Previous page", r);
    r->next = page_button("go-next-symbolic", "Next page", r);
    r->page = gtk_label_new(NULL);
    gtk_box_append(GTK_BOX(controls), r->previous);
    gtk_box_append(GTK_BOX(controls), r->page);
    gtk_box_append(GTK_BOX(controls), r->next);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), controls);
    gtk_window_set_titlebar(r->window, header);

    GtkWidget *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_window_set_child(r->window, body);
    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_widget_set_vexpand(paned, TRUE);
    gtk_box_append(GTK_BOX(body), paned);
    GtkWidget *sidebar = gtk_scrolled_window_new();
    r->list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(r->list, GTK_SELECTION_BROWSE);
    gtk_widget_add_css_class(GTK_WIDGET(r->list), "navigation-sidebar");
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(sidebar), GTK_WIDGET(r->list));
    gtk_paned_set_start_child(GTK_PANED(paned), sidebar);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_position(GTK_PANED(paned), 220);
    g_signal_connect(r->list, "row-selected", G_CALLBACK(selected), r);

    r->stack = gtk_stack_new();
    gtk_paned_set_end_child(GTK_PANED(paned), r->stack);
    r->message = gtk_label_new(NULL);
    gtk_label_set_wrap(GTK_LABEL(r->message), TRUE);
    gtk_stack_add_child(reader_content_stack(r), r->message);
    r->picture = gtk_picture_new();
    gtk_picture_set_content_fit(GTK_PICTURE(r->picture), GTK_CONTENT_FIT_CONTAIN);
    gtk_stack_add_child(reader_content_stack(r), r->picture);
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
        g_signal_handlers_disconnect_by_data(reader.list, &reader);
        g_signal_handlers_disconnect_by_data(reader.previous, &reader);
        g_signal_handlers_disconnect_by_data(reader.next, &reader);
        g_clear_object(&reader.window);
    }
    return status;
}
