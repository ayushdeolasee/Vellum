#pragma once
#include "CShell.h"
#include <gtk/gtk.h>

typedef void (*ChatNotify)(ReaderWindow *, ReaderEvent);
ReaderChatPanel *reader_chat_install(GtkHeaderBar *header, GtkBox *body, ReaderWindow *window, ChatNotify notify);
void reader_chat_show_toggle(ReaderChatPanel *panel, gboolean visible);
