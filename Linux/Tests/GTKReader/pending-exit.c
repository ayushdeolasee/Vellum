// Test-only interposer: keep a real page load in flight until GTK delivers an
// exit on its main thread. Never install this in the reader or PDFium worker.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fpdfview.h>
#include <gtk/gtk.h>

static GMutex mutex;
static GCond gate;
static gboolean released;
static int page_finished;

static gboolean release_worker(gpointer unused) {
    g_mutex_lock(&mutex);
    released = TRUE;
    g_cond_signal(&gate);
    g_mutex_unlock(&mutex);
    return G_SOURCE_REMOVE;
}

static gboolean request_exit(gpointer unused) {
    GtkApplication *app = GTK_APPLICATION(g_application_get_default());
    GtkWindow *window = gtk_application_get_active_window(app);
    const char *mode = g_getenv("READER_TEST_EXIT");
    g_assert(GTK_IS_WINDOW(window));
    if (g_str_equal(mode, "close")) gtk_window_close(window);
    else if (g_str_equal(mode, "destroy")) gtk_window_destroy(window);
    else if (g_str_equal(mode, "quit")) g_application_quit(G_APPLICATION(app));
    else g_error("Unknown test exit: %s", mode);
    g_timeout_add(25, release_worker, NULL);
    return G_SOURCE_REMOVE;
}

FPDF_PAGE FPDF_LoadPage(FPDF_DOCUMENT doc, int index) {
    FPDF_PAGE (*load)(FPDF_DOCUMENT, int) = dlsym(RTLD_NEXT, "FPDF_LoadPage");
    g_assert(load && !g_main_context_is_owner(g_main_context_default()));
    g_mutex_lock(&mutex);
    g_idle_add(request_exit, NULL);
    while (!released) g_cond_wait(&gate, &mutex);
    g_mutex_unlock(&mutex);
    FPDF_PAGE page = load(doc, index);
    g_assert(page);
    g_atomic_int_set(&page_finished, TRUE);
    return page;
}

void FPDF_DestroyLibrary(void) {
    void (*destroy)(void) = dlsym(RTLD_NEXT, "FPDF_DestroyLibrary");
    g_assert(destroy && g_atomic_int_get(&page_finished));
    destroy();
    g_printerr("Drained pending PDF on %s\n", g_getenv("READER_TEST_EXIT"));
}
