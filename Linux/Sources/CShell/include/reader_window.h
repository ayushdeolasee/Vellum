#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct _GtkStack GtkStack;
typedef struct ReaderWindow ReaderWindow;
typedef enum { READER_OPEN, READER_SELECT, READER_PREVIOUS, READER_NEXT, READER_CLOSE } ReaderEvent;
typedef void (*ReaderCallback)(ReaderWindow *, ReaderEvent, int row, void *context);

// All calls and callbacks run on GTK's startup pthread. The window is borrowed
// until reader_run returns. CLOSE is deferred until Swift has drained page work.
int reader_run(ReaderCallback callback, void *context);
// Borrowed stack on the GTK thread. Native content widgets installed here
// share the same sidebar and window; the stack owns each added child.
GtkStack *reader_content_stack(ReaderWindow *reader);
void reader_finish_close(ReaderWindow *reader);
void reader_add_row(ReaderWindow *reader, const char *name);
void reader_select_row(ReaderWindow *reader, int index);
void reader_set_message(ReaderWindow *reader, const char *title, const char *message);
void reader_set_position(ReaderWindow *reader, int number, int count);
void reader_set_page(ReaderWindow *reader, const char *title, int number, int count,
                     const uint8_t *pixels, int width, int height, size_t stride);
