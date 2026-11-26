#include "CShell.h"
#include <gtk/gtk.h>

struct ScratchpadPanel {
    GtkWidget *root, *toggle, *status, *text, *images, *save, *attach;
    GtkTextBuffer *buffer;
    GCancellable *chooser;
    ScratchpadCallback callback;
    void *context;
    gboolean setting_text;
};

static void emit(ScratchpadPanel *panel, ScratchpadEvent event, const char *text) {
    g_assert(shell_on_gtk_thread());
    if (panel->callback) panel->callback(event, text, panel->context);
}

static void toggled(GtkToggleButton *button, GtkWidget *root) {
    ScratchpadPanel *panel = g_object_get_data(G_OBJECT(root), "vellum-scratchpad");
    gboolean visible = gtk_toggle_button_get_active(button);
    gtk_widget_set_visible(panel->root, visible);
    if (visible) emit(panel, SCRATCHPAD_SHOW, NULL);
}

static void changed(GtkTextBuffer *buffer, ScratchpadPanel *panel) {
    if (panel->setting_text) return;
    GtkTextIter start, end;
    gtk_text_buffer_get_bounds(buffer, &start, &end);
    g_autofree char *text = gtk_text_buffer_get_text(buffer, &start, &end, TRUE);
    emit(panel, SCRATCHPAD_CHANGE, text);
}

static void save_clicked(GtkButton *button, ScratchpadPanel *panel) {
    emit(panel, SCRATCHPAD_SAVE, NULL);
}

static void image_chosen(GObject *source, GAsyncResult *result, gpointer data) {
    g_autoptr(GtkWidget) root = data;
    ScratchpadPanel *panel = g_object_get_data(G_OBJECT(root), "vellum-scratchpad");
    g_autoptr(GFile) file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(source), result, NULL);
    gboolean valid = panel->chooser && !g_cancellable_is_cancelled(panel->chooser);
    g_clear_object(&panel->chooser);
    if (valid && file) {
        g_autofree char *path = g_file_get_path(file);
        if (path) emit(panel, SCRATCHPAD_ATTACH, path);
    }
}

static void attach_clicked(GtkButton *button, ScratchpadPanel *panel) {
    if (panel->chooser) return;
    GtkRoot *root = gtk_widget_get_root(panel->root);
    if (!GTK_IS_WINDOW(root)) return;
    g_autoptr(GtkFileDialog) dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Attach an image");
    GFile *directory = g_object_get_data(G_OBJECT(panel->root), "vellum-import-directory");
    if (directory) gtk_file_dialog_set_initial_folder(dialog, directory);
    g_autoptr(GtkFileFilter) filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Raster images");
    const char *extensions[] = {"png", "jpeg", "jpg", "gif", "webp", "tiff", "tif", "heic"};
    for (size_t i = 0; i < G_N_ELEMENTS(extensions); i++)
        gtk_file_filter_add_suffix(filter, extensions[i]);
    gtk_file_dialog_set_default_filter(dialog, filter);
    panel->chooser = g_cancellable_new();
    gtk_file_dialog_open(dialog, GTK_WINDOW(root), panel->chooser, image_chosen, g_object_ref(panel->root));
}

ScratchpadPanel *scratchpad_panel_new(void) {
    ScratchpadPanel *panel = g_new0(ScratchpadPanel, 1);
    panel->root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    g_object_set_data_full(G_OBJECT(panel->root), "vellum-scratchpad", panel, g_free);
    gtk_widget_set_size_request(panel->root, 310, -1);
    gtk_widget_set_margin_start(panel->root, 12);
    gtk_widget_set_margin_end(panel->root, 12);
    gtk_widget_set_margin_top(panel->root, 12);
    gtk_widget_set_margin_bottom(panel->root, 12);
    gtk_widget_set_visible(panel->root, FALSE);
    panel->toggle = gtk_toggle_button_new_with_label("Scratchpad");
    gtk_widget_set_sensitive(panel->toggle, FALSE);
    g_signal_connect_object(panel->toggle, "toggled", G_CALLBACK(toggled), panel->root, G_CONNECT_DEFAULT);

    panel->status = gtk_label_new("Select a document to open its scratchpad.");
    gtk_label_set_xalign(GTK_LABEL(panel->status), 0);
    gtk_label_set_wrap(GTK_LABEL(panel->status), TRUE);
    gtk_widget_add_css_class(panel->status, "dim-label");
    gtk_box_append(GTK_BOX(panel->root), panel->status);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    panel->text = gtk_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(panel->text), GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_monospace(GTK_TEXT_VIEW(panel->text), TRUE);
    gtk_text_view_set_left_margin(GTK_TEXT_VIEW(panel->text), 8);
    gtk_text_view_set_right_margin(GTK_TEXT_VIEW(panel->text), 8);
    gtk_text_view_set_top_margin(GTK_TEXT_VIEW(panel->text), 6);
    gtk_text_view_set_editable(GTK_TEXT_VIEW(panel->text), FALSE);
    gtk_text_view_set_cursor_visible(GTK_TEXT_VIEW(panel->text), FALSE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(panel->text),
                                   GTK_ACCESSIBLE_PROPERTY_LABEL, "Scratchpad Markdown", -1);
    panel->buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(panel->text));
    g_signal_connect(panel->buffer, "changed", G_CALLBACK(changed), panel);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), panel->text);
    gtk_box_append(GTK_BOX(panel->root), scroll);

    GtkWidget *images_scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(images_scroll), 190);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(images_scroll), TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(images_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    panel->images = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(images_scroll), panel->images);
    gtk_box_append(GTK_BOX(panel->root), images_scroll);

    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    panel->attach = gtk_button_new_with_label("Attach Image");
    panel->save = gtk_button_new_with_label("Save");
    gtk_widget_add_css_class(panel->save, "suggested-action");
    g_signal_connect(panel->attach, "clicked", G_CALLBACK(attach_clicked), panel);
    g_signal_connect(panel->save, "clicked", G_CALLBACK(save_clicked), panel);
    gtk_box_append(GTK_BOX(actions), panel->attach);
    gtk_box_append(GTK_BOX(actions), panel->save);
    gtk_box_append(GTK_BOX(panel->root), actions);
    scratchpad_panel_set_state(panel, "Select a document to open its scratchpad.", false, false, false);
    return panel;
}

GtkWidget *scratchpad_panel_widget(ScratchpadPanel *panel) { return panel->root; }
GtkWidget *scratchpad_panel_toggle(ScratchpadPanel *panel) { return panel->toggle; }

void scratchpad_panel_connect(ScratchpadPanel *panel, ScratchpadCallback callback, void *context) {
    panel->callback = callback;
    panel->context = context;
    gtk_widget_set_sensitive(panel->toggle, TRUE);
}

void scratchpad_panel_disconnect(ScratchpadPanel *panel) {
    panel->callback = NULL;
    panel->context = NULL;
    if (panel->chooser) g_cancellable_cancel(panel->chooser);
}

bool scratchpad_panel_visible(ScratchpadPanel *panel) { return gtk_widget_get_visible(panel->root); }

void scratchpad_panel_show(ScratchpadPanel *panel) {
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(panel->toggle), TRUE);
}

void scratchpad_panel_set_note(ScratchpadPanel *panel, const char *markdown) {
    if (panel->chooser) g_cancellable_cancel(panel->chooser);
    panel->setting_text = TRUE;
    // Programmatic document changes must not put the prior document in Undo.
    gtk_text_buffer_set_enable_undo(panel->buffer, FALSE);
    gtk_text_buffer_set_text(panel->buffer, markdown, -1);
    gtk_text_buffer_set_enable_undo(panel->buffer, TRUE);
    panel->setting_text = FALSE;
}

void scratchpad_panel_set_state(ScratchpadPanel *panel, const char *message,
                                bool available, bool editable, bool can_save) {
    gtk_label_set_text(GTK_LABEL(panel->status), message);
    gtk_text_view_set_editable(GTK_TEXT_VIEW(panel->text), available && editable);
    gtk_text_view_set_cursor_visible(GTK_TEXT_VIEW(panel->text), available && editable);
    gtk_widget_set_visible(panel->attach, editable);
    gtk_widget_set_visible(panel->save, editable);
    gtk_widget_set_sensitive(panel->attach, available);
    gtk_widget_set_sensitive(panel->save, can_save);
}

void scratchpad_panel_set_import_directory(ScratchpadPanel *panel, const char *path) {
    g_object_set_data_full(G_OBJECT(panel->root), "vellum-import-directory",
                           g_file_new_for_path(path), g_object_unref);
}

void scratchpad_panel_clear_images(ScratchpadPanel *panel) {
    while (gtk_widget_get_first_child(panel->images))
        gtk_box_remove(GTK_BOX(panel->images), gtk_widget_get_first_child(panel->images));
}

static void image_size_prepared(GdkPixbufLoader *loader, int width, int height, gboolean *safe) {
    *safe = width > 0 && height > 0 && width <= 4096 && height <= 4096;
    if (!*safe) {
        gdk_pixbuf_loader_set_size(loader, 1, 1);
    } else if (width > 280 || height > 170) {
        double ratio = MIN(280.0 / width, 170.0 / height);
        gdk_pixbuf_loader_set_size(loader, MAX(1, (int)(width * ratio)), MAX(1, (int)(height * ratio)));
    }
}

GdkTexture *scratchpad_image_decode(const char *format, const uint8_t *bytes, size_t length) {
    // Pick a raster decoder by type. Never sniff SVG, fetch URLs or pass
    // Markdown to a renderer with script or navigation privileges.
    gboolean safe = FALSE;
    g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new_with_type(format, NULL);
    if (!loader) return NULL;
    g_signal_connect(loader, "size-prepared", G_CALLBACK(image_size_prepared), &safe);
    gboolean loaded = gdk_pixbuf_loader_write(loader, bytes, length, NULL);
    gboolean complete = gdk_pixbuf_loader_close(loader, NULL);
    if (!loaded || !complete || !safe) return NULL;
    GdkPixbuf *pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
    return pixbuf ? gdk_texture_new_for_pixbuf(pixbuf) : NULL;
}

void scratchpad_image_release(GdkTexture *texture) { g_object_unref(texture); }

void scratchpad_panel_add_image(ScratchpadPanel *panel, GdkTexture *texture) {
    GtkWidget *picture = gtk_picture_new_for_paintable(GDK_PAINTABLE(texture));
    gtk_widget_set_halign(picture, GTK_ALIGN_CENTER);
    gtk_picture_set_can_shrink(GTK_PICTURE(picture), FALSE);
    gtk_picture_set_alternative_text(GTK_PICTURE(picture), "Scratchpad image");
    gtk_box_append(GTK_BOX(panel->images), picture);
}
