#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct _GtkStack GtkStack;
typedef struct ReaderWindow ReaderWindow;
typedef enum { READER_OPEN, READER_SELECT, READER_PREVIOUS, READER_NEXT, READER_CLOSE, READER_SEARCH, READER_CLOSE_REQUEST } ReaderEvent;
typedef void (*ReaderCallback)(ReaderWindow *, ReaderEvent, int entry, void *context);

// All calls and callbacks run on GTK's startup pthread. The window is borrowed
// until reader_run returns. Every exit from an opened window sends CLOSE once.
// reader_finish_close acknowledges that all controller work has drained.
int reader_run(ReaderCallback callback, void *context);
// Borrowed stack on the GTK thread. Native content widgets installed here
// share the same sidebar and window; the stack owns each added child.
GtkStack *reader_content_stack(ReaderWindow *reader);
typedef struct ScratchpadPanel ScratchpadPanel;
ScratchpadPanel *reader_scratchpad_panel(ReaderWindow *reader);
void reader_set_close_pending(ReaderWindow *reader, bool pending);
void reader_commit_close(ReaderWindow *reader);
void reader_finish_close(ReaderWindow *reader);
void reader_enable_search(ReaderWindow *reader);
const char *reader_search_query(ReaderWindow *reader);
void reader_clear_rows(ReaderWindow *reader);
void reader_show_no_matches(ReaderWindow *reader);
void reader_add_row(ReaderWindow *reader, int entry, const char *title, const char *filename);
void reader_select_row(ReaderWindow *reader, int index);
void reader_set_message(ReaderWindow *reader, const char *title, const char *message);
void reader_page_message(ReaderWindow *reader, const char *title, const char *message, int number, int count);
void reader_set_position(ReaderWindow *reader, int number, int count);
void reader_set_page(ReaderWindow *reader, const char *title, int number, int count,
                     const uint8_t *pixels, int width, int height, size_t stride);
void reader_web_ready(ReaderWindow *reader, const char *title, const char *position);
