#include "reader_chat_private.h"

struct ReaderChatPanel {
    GtkWidget *box, *toggle, *entry, *send, *stop, *status;
    GtkTextView *transcript;
    ReaderWindow *window;
    ChatNotify notify;
};

static void toggled(GtkToggleButton *button, ReaderChatPanel *p) {
    gboolean open = gtk_toggle_button_get_active(button);
    gtk_widget_set_visible(p->box, open);
    p->notify(p->window, READER_CHAT_TOGGLE);
    if (open) gtk_widget_grab_focus(p->entry);
}

static void send_chat(GtkWidget *widget, ReaderChatPanel *p) {
    if (gtk_widget_is_sensitive(p->send)) p->notify(p->window, READER_CHAT_SEND);
}

static void stop_chat(GtkButton *button, ReaderChatPanel *p) {
    p->notify(p->window, READER_CHAT_STOP);
}

ReaderChatPanel *reader_chat_install(GtkHeaderBar *header, GtkBox *body, ReaderWindow *window, ChatNotify notify) {
    ReaderChatPanel *p = g_new0(ReaderChatPanel, 1);
    p->window = window;
    p->notify = notify;
    p->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    g_object_set_data_full(G_OBJECT(p->box), "reader-chat", p, g_free);
    gtk_widget_set_margin_start(p->box, 12);
    gtk_widget_set_margin_end(p->box, 12);
    gtk_widget_set_visible(p->box, FALSE);
    gtk_box_append(body, p->box);
    p->toggle = gtk_toggle_button_new_with_label("Chat");
    gtk_header_bar_pack_start(header, p->toggle);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 138);
    p->transcript = GTK_TEXT_VIEW(gtk_text_view_new());
    gtk_text_view_set_wrap_mode(p->transcript, GTK_WRAP_WORD_CHAR);
    gtk_text_view_set_editable(p->transcript, FALSE);
    gtk_text_view_set_cursor_visible(p->transcript, FALSE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(p->transcript), GTK_ACCESSIBLE_PROPERTY_LABEL, "Conversation", -1);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(p->transcript));
    gtk_box_append(GTK_BOX(p->box), scroll);
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    p->entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(p->entry), "Ask about this document");
    gtk_accessible_update_property(GTK_ACCESSIBLE(p->entry), GTK_ACCESSIBLE_PROPERTY_LABEL, "Question", -1);
    gtk_entry_set_max_length(GTK_ENTRY(p->entry), 12000);
    gtk_widget_set_hexpand(p->entry, TRUE);
    p->send = gtk_button_new_with_label("Send");
    p->stop = gtk_button_new_with_label("Stop");
    gtk_box_append(GTK_BOX(row), p->entry);
    gtk_box_append(GTK_BOX(row), p->send);
    gtk_box_append(GTK_BOX(row), p->stop);
    gtk_box_append(GTK_BOX(p->box), row);
    p->status = gtk_label_new(NULL);
    gtk_label_set_xalign(GTK_LABEL(p->status), 0);
    gtk_label_set_wrap(GTK_LABEL(p->status), TRUE);
    gtk_box_append(GTK_BOX(p->box), p->status);
    g_signal_connect(p->entry, "activate", G_CALLBACK(send_chat), p);
    g_signal_connect(p->send, "clicked", G_CALLBACK(send_chat), p);
    g_signal_connect(p->stop, "clicked", G_CALLBACK(stop_chat), p);
    g_signal_connect(p->toggle, "toggled", G_CALLBACK(toggled), p);
    return p;
}

bool reader_chat_visible(ReaderChatPanel *p) { return gtk_widget_get_visible(p->box); }
void reader_chat_show_toggle(ReaderChatPanel *p, gboolean visible) { gtk_widget_set_visible(p->toggle, visible); }
const char *reader_chat_draft(ReaderChatPanel *p) { return gtk_editable_get_text(GTK_EDITABLE(p->entry)); }
void reader_chat_set_draft(ReaderChatPanel *p, const char *text) { gtk_editable_set_text(GTK_EDITABLE(p->entry), text); }

void reader_chat_set_transcript(ReaderChatPanel *p, const char *text) {
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(p->transcript), text, -1);
}

void reader_chat_append(ReaderChatPanel *p, const char *text) {
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(p->transcript);
    GtkTextIter end;
    gtk_text_buffer_get_end_iter(buffer, &end);
    gtk_text_buffer_insert(buffer, &end, text, -1);
    gtk_text_view_scroll_to_iter(p->transcript, &end, 0, FALSE, 0, 0);
}

void reader_chat_state(ReaderChatPanel *p, const char *message, bool ready, bool streaming) {
    gtk_label_set_text(GTK_LABEL(p->status), message);
    gtk_widget_set_sensitive(p->entry, ready);
    gtk_widget_set_sensitive(p->send, ready);
    gtk_widget_set_visible(p->stop, streaming);
}
