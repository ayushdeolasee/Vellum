#include "reader_settings.h"

typedef struct {
    ReaderSettings *settings;
    GCancellable *cancellable;
} FolderRequest;

typedef struct {
    GtkEntryBuffer parent;
    GtkEntryBuffer *secret;
    const char *inserting; // Borrowed during a synchronous editable insertion.
} ReaderKeyBuffer;
typedef GtkEntryBufferClass ReaderKeyBufferClass;

G_DEFINE_TYPE(ReaderKeyBuffer, reader_key_buffer, GTK_TYPE_ENTRY_BUFFER)

// GTK 4.14 can return a GtkPasswordEntry's editable text over AT-SPI. Keep
// Vellum's input in GTK's original secure buffer and expose only the mask
// through the attached buffer, including its text-change notifications.
static guint key_buffer_insert(GtkEntryBuffer *buffer, guint position, const char *text, guint length) {
    ReaderKeyBuffer *self = (ReaderKeyBuffer *)buffer;
    GtkEntryBufferClass *parent = GTK_ENTRY_BUFFER_CLASS(reader_key_buffer_parent_class);
    const char *secret = self->inserting ? self->inserting : text;
    guint stored = gtk_entry_buffer_insert_text(self->secret, position, secret, length);
    if (!stored) return 0;
    g_autofree char *mask = g_strnfill(stored, '*');
    guint inserted = parent->insert_text(buffer, position, mask, stored);
    if (inserted < stored)
        gtk_entry_buffer_delete_text(self->secret, position + inserted, stored - inserted);
    return inserted;
}

static guint key_buffer_delete(GtkEntryBuffer *buffer, guint position, guint length) {
    ReaderKeyBuffer *self = (ReaderKeyBuffer *)buffer;
    GtkEntryBufferClass *parent = GTK_ENTRY_BUFFER_CLASS(reader_key_buffer_parent_class);
    guint removed = gtk_entry_buffer_delete_text(self->secret, position, length);
    return parent->delete_text(buffer, position, removed);
}

static void reader_key_buffer_dispose(GObject *buffer) {
    ReaderKeyBuffer *self = (ReaderKeyBuffer *)buffer;
    g_clear_object(&self->secret);
    G_OBJECT_CLASS(reader_key_buffer_parent_class)->dispose(buffer);
}

static void reader_key_buffer_class_init(ReaderKeyBufferClass *class) {
    G_OBJECT_CLASS(class)->dispose = reader_key_buffer_dispose;
    class->insert_text = key_buffer_insert;
    class->delete_text = key_buffer_delete;
}

static void reader_key_buffer_init(ReaderKeyBuffer *buffer) {}

static void mask_key_insertion(GtkEditable *entry, const char *text, int bytes, int *position,
                               ReaderKeyBuffer *buffer) {
    if (buffer->inserting) return;
    glong length = g_utf8_strlen(text, bytes);
    if (!length) return;
    // The legacy AT-SPI editable bridge also observes the insertion signal,
    // so let only the masked insertion propagate to its observers.
    g_autofree char *mask = g_strnfill(length, '*');
    g_signal_stop_emission_by_name(entry, "insert-text");
    buffer->inserting = text;
    gtk_editable_insert_text(entry, mask, (int)length, position);
    buffer->inserting = NULL;
}

struct ReaderSettings {
    GtkWindow *parent;
    ReaderWindow *reader;
    ReaderCallback callback;
    FolderRequest *folder_request;
    GtkWidget *page, *path, *library_status, *choose, *reopen;
    GtkWidget *providers, *provider_status, *key_section, *key, *save, *remove, *key_status;
    GtkEntryBuffer *key_material; // Borrowed from the installed ReaderKeyBuffer.
    unsigned provider_count;
    gboolean changing_provider, key_busy;
};

enum { PROVIDERS_PER_ROW = 3 };

static void notify(ReaderSettings *s, ReaderEvent event, int index, const char *text) {
    s->callback(s->reader, event, index, text, NULL);
}

static void folder_response(GObject *dialog, GAsyncResult *result, gpointer data) {
    g_autofree FolderRequest *request = data;
    g_autoptr(GCancellable) cancellable = request->cancellable;
    g_autoptr(GError) error = NULL;
    g_autoptr(GFile) file = gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(dialog), result, &error);
    ReaderSettings *s = request->settings;
    if (!s) return; // The settings page or window was closed during the request.
    s->folder_request = NULL;
    if (g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) return;
    if (!file) {
        gtk_label_set_text(GTK_LABEL(s->library_status), "Could not choose a folder.");
        gtk_widget_set_visible(s->library_status, TRUE);
        return;
    }
    g_autofree char *path = g_file_get_path(file);
    if (path) notify(s, READER_CHOOSE_LIBRARY, -1, path);
    else {
        gtk_label_set_text(GTK_LABEL(s->library_status), "Choose a local folder.");
        gtk_widget_set_visible(s->library_status, TRUE);
    }
}

static void choose_folder(GtkButton *button, ReaderSettings *s) {
    if (s->folder_request) return;
    g_autoptr(GtkFileDialog) dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, "Choose Library Folder");
    gtk_file_dialog_set_accept_label(dialog, "Choose");
    const char *path = gtk_label_get_text(GTK_LABEL(s->path));
    if (*path) {
        g_autoptr(GFile) folder = g_file_new_for_path(path);
        gtk_file_dialog_set_initial_folder(dialog, folder);
    }
    FolderRequest *request = g_new0(FolderRequest, 1);
    request->settings = s;
    request->cancellable = g_cancellable_new();
    s->folder_request = request;
    gtk_file_dialog_select_folder(dialog, s->parent, request->cancellable, folder_response, request);
}

static void reopen(GtkButton *button, ReaderSettings *s) {
    notify(s, READER_REOPEN_LIBRARY, -1, NULL);
}

static void done(GtkButton *button, ReaderSettings *s) {
    notify(s, READER_SETTINGS_DONE, -1, NULL);
}

static void provider_changed(GtkToggleButton *choice, ReaderSettings *s) {
    if (s->changing_provider || !gtk_toggle_button_get_active(choice)) return;
    int index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(choice), "provider-index"));
    gtk_editable_set_text(GTK_EDITABLE(s->key), "");
    notify(s, READER_CHANGE_PROVIDER, index, NULL);
}

static void key_section_changed(GObject *object, GParamSpec *property, ReaderSettings *s) {
    if (reader_settings_key_is_open(s)) notify(s, READER_CHECK_KEY, -1, NULL);
    else gtk_editable_set_text(GTK_EDITABLE(s->key), "");
}

static void key_changed(GtkEditable *key, ReaderSettings *s) {
    gtk_widget_set_sensitive(s->save, !s->key_busy && *gtk_editable_get_text(key));
}

static void save_key(GtkButton *button, ReaderSettings *s) {
    GtkEditable *key = GTK_EDITABLE(s->key);
    const char *text = gtk_entry_buffer_get_text(s->key_material);
    if (*text && !s->key_busy) {
        notify(s, READER_SAVE_KEY, -1, text);
        gtk_editable_set_text(key, "");
    }
}

static void remove_key(GtkButton *button, ReaderSettings *s) {
    gtk_editable_set_text(GTK_EDITABLE(s->key), "");
    notify(s, READER_REMOVE_KEY, -1, NULL);
}

static GtkWidget *label(const char *text, const char *style) {
    GtkWidget *widget = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    if (style) gtk_widget_add_css_class(widget, style);
    return widget;
}

static GtkWidget *button(GtkBox *row, const char *text, GCallback action, ReaderSettings *s) {
    GtkWidget *widget = gtk_button_new_with_label(text);
    g_signal_connect(widget, "clicked", action, s);
    gtk_box_append(row, widget);
    return widget;
}

ReaderSettings *reader_settings_new(GtkWindow *parent, ReaderWindow *reader, ReaderCallback callback) {
    ReaderSettings *s = g_new0(ReaderSettings, 1);
    s->parent = parent;
    s->reader = reader;
    s->callback = callback;
    s->page = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(s->page), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_halign(column, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(column, GTK_ALIGN_START);
    gtk_widget_set_size_request(column, 408, -1);
    gtk_widget_set_margin_top(column, 36);
    gtk_widget_set_margin_bottom(column, 24);
    gtk_widget_set_margin_start(column, 16);
    gtk_widget_set_margin_end(column, 16);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(s->page), column);

    GtkWidget *heading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *title = label("Settings", "title-1");
    gtk_widget_set_hexpand(title, TRUE);
    gtk_box_append(GTK_BOX(heading), title);
    button(GTK_BOX(heading), "Done", G_CALLBACK(done), s);
    gtk_box_append(GTK_BOX(column), heading);

    GtkWidget *library = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_box_append(GTK_BOX(column), library);
    gtk_box_append(GTK_BOX(library), label("Library Folder", "heading"));
    s->path = label(NULL, "dim-label");
    gtk_label_set_ellipsize(GTK_LABEL(s->path), PANGO_ELLIPSIZE_MIDDLE);
    gtk_box_append(GTK_BOX(library), s->path);
    GtkBox *library_buttons = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8));
    gtk_box_append(GTK_BOX(library), GTK_WIDGET(library_buttons));
    s->choose = button(library_buttons, "Choose Folder…", G_CALLBACK(choose_folder), s);
    s->reopen = button(library_buttons, "Reopen", G_CALLBACK(reopen), s);
    s->library_status = label(NULL, "dim-label");
    gtk_box_append(GTK_BOX(library), s->library_status);
    reader_settings_set_library(s, "", "", TRUE);

    gtk_box_append(GTK_BOX(column), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    GtkBox *ai = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8));
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(ai));
    GtkWidget *provider_label = label("AI Provider", "heading");
    gtk_box_append(ai, provider_label);
    s->providers = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(s->providers), 6);
    gtk_grid_set_row_spacing(GTK_GRID(s->providers), 6);
    gtk_accessible_update_relation(GTK_ACCESSIBLE(s->providers), GTK_ACCESSIBLE_RELATION_LABELLED_BY,
                                   provider_label, NULL, -1);
    gtk_box_append(ai, s->providers);
    s->provider_status = label(NULL, "dim-label");
    gtk_box_append(ai, s->provider_status);

    s->key_section = gtk_expander_new("API Key");
    gtk_widget_set_sensitive(s->key_section, FALSE);
    gtk_box_append(ai, s->key_section);
    GtkBox *credentials = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8));
    gtk_widget_set_margin_top(GTK_WIDGET(credentials), 6);
    gtk_expander_set_child(GTK_EXPANDER(s->key_section), GTK_WIDGET(credentials));
    s->key_status = label(NULL, "dim-label");
    gtk_box_append(credentials, s->key_status);
    s->key = gtk_password_entry_new();
    GtkText *editor = GTK_TEXT(gtk_editable_get_delegate(GTK_EDITABLE(s->key)));
    g_autoptr(GtkEntryBuffer) mask = g_object_new(reader_key_buffer_get_type(), NULL);
    s->key_material = g_object_ref(gtk_text_get_buffer(editor));
    ((ReaderKeyBuffer *)mask)->secret = s->key_material;
    gtk_text_set_buffer(editor, mask);
    g_signal_connect_object(s->key, "insert-text", G_CALLBACK(mask_key_insertion), mask, 0);
    g_signal_connect_object(editor, "insert-text", G_CALLBACK(mask_key_insertion), mask, 0);
    gtk_password_entry_set_show_peek_icon(GTK_PASSWORD_ENTRY(s->key), FALSE);
    g_object_set(s->key, "placeholder-text", "Enter API key", NULL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(s->key), GTK_ACCESSIBLE_PROPERTY_LABEL, "API key", -1);
    gtk_box_append(credentials, s->key);
    GtkBox *key_buttons = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8));
    gtk_box_append(credentials, GTK_WIDGET(key_buttons));
    s->save = button(key_buttons, "Save Key", G_CALLBACK(save_key), s);
    s->remove = button(key_buttons, "Remove Key", G_CALLBACK(remove_key), s);
    reader_settings_set_key(s, "", FALSE, FALSE);
    g_signal_connect(s->key, "changed", G_CALLBACK(key_changed), s);
    g_signal_connect(s->key_section, "notify::expanded", G_CALLBACK(key_section_changed), s);
    return s;
}

GtkWidget *reader_settings_page(ReaderSettings *s) {
    return s->page;
}

void reader_settings_dismiss(ReaderSettings *s) {
    if (s->folder_request) {
        FolderRequest *request = g_steal_pointer(&s->folder_request);
        request->settings = NULL;
        g_cancellable_cancel(request->cancellable);
    }
    gtk_expander_set_expanded(GTK_EXPANDER(s->key_section), FALSE);
}

void reader_settings_free(ReaderSettings *s) {
    g_free(s);
}

void reader_settings_add_provider(ReaderSettings *s, const char *name) {
    GtkGrid *grid = GTK_GRID(s->providers);
    GtkWidget *choice = gtk_toggle_button_new_with_label(name);
    GtkWidget *first = gtk_grid_get_child_at(grid, 0, 0);
    if (first) gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(choice), GTK_TOGGLE_BUTTON(first));
    unsigned index = s->provider_count++;
    g_object_set_data(G_OBJECT(choice), "provider-index", GUINT_TO_POINTER(index));
    gtk_grid_attach(grid, choice, index % PROVIDERS_PER_ROW, index / PROVIDERS_PER_ROW, 1, 1);
    g_signal_connect(choice, "toggled", G_CALLBACK(provider_changed), s);
}

void reader_settings_set_provider(ReaderSettings *s, unsigned index, const char *message) {
    s->changing_provider = TRUE;
    GtkWidget *choice = gtk_grid_get_child_at(GTK_GRID(s->providers), index % PROVIDERS_PER_ROW,
                                              index / PROVIDERS_PER_ROW);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(choice), TRUE);
    s->changing_provider = FALSE;
    gtk_label_set_text(GTK_LABEL(s->provider_status), message);
    gtk_widget_set_visible(s->provider_status, *message != '\0');
    gtk_widget_set_sensitive(s->key_section, TRUE);
}

void reader_settings_set_library(ReaderSettings *s, const char *path, const char *message, bool busy) {
    gtk_label_set_text(GTK_LABEL(s->path), path);
    gtk_widget_set_tooltip_text(s->path, path);
    gtk_label_set_text(GTK_LABEL(s->library_status), message);
    gtk_widget_set_visible(s->library_status, *message != '\0');
    gtk_widget_set_sensitive(s->choose, !busy);
    gtk_widget_set_sensitive(s->reopen, !busy && *path);
}

void reader_settings_set_key(ReaderSettings *s, const char *message, bool busy, bool removable) {
    s->key_busy = busy;
    gtk_label_set_text(GTK_LABEL(s->key_status), message);
    gtk_widget_set_sensitive(s->providers, !busy);
    gtk_widget_set_sensitive(s->key, !busy);
    key_changed(GTK_EDITABLE(s->key), s);
    gtk_widget_set_sensitive(s->remove, !busy && removable);
}

bool reader_settings_key_is_open(ReaderSettings *s) {
    return gtk_expander_get_expanded(GTK_EXPANDER(s->key_section));
}
