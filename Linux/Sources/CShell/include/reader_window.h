#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct _GtkStack GtkStack;
typedef struct ReaderWindow ReaderWindow;
typedef struct ReaderSettings ReaderSettings;
typedef enum {
    READER_OPEN, READER_SELECT, READER_PREVIOUS, READER_NEXT, READER_CLOSE, READER_SEARCH,
    READER_CHAT_TOGGLE, READER_CHAT_SEND, READER_CHAT_STOP, READER_CHAT_RETRY, READER_CHAT_DRAFT,
    READER_SETTINGS_DONE, READER_CHOOSE_LIBRARY, READER_REOPEN_LIBRARY,
    READER_CHANGE_PROVIDER, READER_CHECK_KEY, READER_SAVE_KEY, READER_REMOVE_KEY, READER_CLOSE_REQUEST, READER_TOGGLE_EDITING
} ReaderEvent;
// Text, when supplied, is borrowed only for the duration of the callback.
typedef void (*ReaderCallback)(ReaderWindow *, ReaderEvent, int entry, const char *text, void *context);

// All calls and callbacks run on GTK's startup pthread. The window is borrowed
// until reader_run returns. Every exit from an opened window sends CLOSE once.
// reader_finish_close acknowledges that all controller work has drained.
int reader_run(ReaderCallback callback, void *context);
// Borrowed stack on the GTK thread. Native content widgets installed here
// share the same sidebar and window; the stack owns each added child.
GtkStack *reader_content_stack(ReaderWindow *reader);
ReaderSettings *reader_settings(ReaderWindow *reader);
typedef struct ScratchpadPanel ScratchpadPanel;
ScratchpadPanel *reader_scratchpad_panel(ReaderWindow *reader);
void reader_set_close_pending(ReaderWindow *reader, bool pending);
typedef void (*ReaderLeaveReply)(void *context, bool discard);
typedef enum { LEAVE_SCRATCHPAD, LEAVE_CHAT } ReaderLeaveKind;
void reader_confirm_leave(ReaderWindow *reader, ReaderLeaveKind kind, ReaderLeaveReply reply, void *context);
typedef void (*ReaderRecoveryReply)(void *context, int choice);
void reader_confirm_recovered(ReaderWindow *reader, ReaderRecoveryReply reply, void *context);
void reader_notice(ReaderWindow *reader, const char *message);
void reader_article_location(ReaderWindow *reader, int page, int percent);
void reader_commit_close(ReaderWindow *reader);
void reader_finish_close(ReaderWindow *reader);
void reader_enable_search(ReaderWindow *reader);
void reader_reset_search(ReaderWindow *reader);
const char *reader_search_query(ReaderWindow *reader);
void reader_clear_rows(ReaderWindow *reader);
void reader_show_no_matches(ReaderWindow *reader);
void reader_add_row(ReaderWindow *reader, int entry, const char *title, const char *filename);
void reader_reselect_entry(ReaderWindow *reader, int entry);
void reader_select_row(ReaderWindow *reader, int index);
void reader_set_message(ReaderWindow *reader, const char *title, const char *message);
void reader_page_message(ReaderWindow *reader, const char *title, const char *message, int number, int count);
void reader_set_position(ReaderWindow *reader, int number, int count);
void reader_set_page(ReaderWindow *reader, const char *title, int number, int count,
                     const uint8_t *pixels, int width, int height, size_t stride);
void reader_web_ready(ReaderWindow *reader, const char *title, const char *position);

void reader_settings_add_provider(ReaderSettings *settings, const char *name);
void reader_settings_set_provider(ReaderSettings *settings, unsigned index, const char *message);
void reader_settings_set_library(ReaderSettings *settings, const char *path, const char *message, bool busy);
void reader_set_editing(ReaderWindow *reader, bool enabled, bool available);
void reader_settings_set_editing(ReaderSettings *settings, bool enabled, bool available);
void reader_show_status(ReaderWindow *reader, const char *message);
void reader_settings_set_key(ReaderSettings *settings, const char *message, bool busy, bool removable);
bool reader_settings_key_is_open(ReaderSettings *settings);

#include "reader_chat.h"
