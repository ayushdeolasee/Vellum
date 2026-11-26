// Test-only trigger for the actual GApplication shutdown path, after AT-SPI has
// entered a draft or received a streamed reply in the ordinary reader.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <gio/gio.h>
#include <glib-unix.h>

static gboolean quit(gpointer app) {
    g_application_quit(G_APPLICATION(app));
    return G_SOURCE_REMOVE;
}

int g_application_run(GApplication *app, int argc, char **argv) {
    int (*run)(GApplication *, int, char **) = dlsym(RTLD_NEXT, "g_application_run");
    g_assert(run);
    g_unix_signal_add(SIGUSR1, quit, app);
    return run(app, argc, argv);
}
