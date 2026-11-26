#pragma once

#include "CShell.h"
#include <gtk/gtk.h>

ReaderSettings *reader_settings_new(GtkWindow *parent, ReaderWindow *reader, ReaderCallback callback);
GtkWidget *reader_settings_page(ReaderSettings *settings);
void reader_settings_dismiss(ReaderSettings *settings);
void reader_settings_free(ReaderSettings *settings);
