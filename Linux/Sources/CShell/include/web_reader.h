#pragma once

#include <stdbool.h>
#include <stddef.h>
#include "reader_window.h"

typedef struct WebReader WebReader;
typedef struct _WebKitURISchemeRequest WebKitURISchemeRequest;
typedef bool (*WebResource)(void *, const char *, WebKitURISchemeRequest *);
typedef void (*WebEvent)(void *, const char *);

// GTK-thread only. Each reader binds one selection, with an ephemeral network
// session. The stack outlives it. Free before destroying the hosting window.
WebReader *web_reader_new(GtkStack *, const char *uri, bool ink, const char *script,
                          WebResource resource, WebEvent message, WebEvent denied, void *owner);
void web_reader_free(WebReader *reader);
// Copies borrowed Swift bytes into a stream owned by the request.
void web_reader_respond(WebKitURISchemeRequest *, const char *mime, const void *bytes, size_t count);
// Returns one location from the isolated reader world. The callback runs once,
// with NULL when the document did not finish loading.
void web_reader_location(WebReader *reader, WebEvent reply, void *owner);
