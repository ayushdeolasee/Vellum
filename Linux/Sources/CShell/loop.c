#include "CShell.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <glib-unix.h>
#include <pthread.h>

static pthread_t owner;
static guint source;
static ShellCallback run_turn;
static uint64_t wakes;
static bool strict_fd;

bool shell_on_gtk_thread(void) {
    return pthread_equal(owner, pthread_self()) != 0;
}

uint64_t shell_pump_wakes(void) { return wakes; }

static gboolean service_swift(gpointer unused) {
    g_assert(shell_on_gtk_thread());
    ++wakes;
    run_turn();
    return G_SOURCE_CONTINUE;
}

static guint start_timer(void) {
    return g_timeout_add(8, service_swift, NULL);
}

static gboolean fd_ready(gint fd, GIOCondition condition, gpointer unused) {
    if (condition & (G_IO_NVAL | G_IO_HUP | G_IO_ERR)) {
        if (strict_fd) g_error("dispatch wake fd failed in strict eventfd mode");
        g_warning("dispatch wake fd failed, switching to the timer");
        source = start_timer();
        return G_SOURCE_REMOVE;
    }
    // Dispatch owns the descriptor and consumes its wake during the Swift turn.
    return service_swift(NULL);
}

int shell_install_pump(ShellPump mode, ShellCallback turn) {
    g_assert(!source && turn);
    owner = pthread_self();
    run_turn = turn;
    wakes = 0;
    strict_fd = mode == SHELL_EVENTFD;
    if (mode != SHELL_TIMER) {
        typedef int (*GetHandle)(void);
        GetHandle get = mode == SHELL_MISSING ? NULL :
            (GetHandle)dlsym(RTLD_DEFAULT, "_dispatch_get_main_queue_handle_4CF");
        int fd = get ? get() : -1;
        if (fd >= 0 && fcntl(fd, F_GETFD) != -1) {
            source = g_unix_fd_add(fd, G_IO_IN | G_IO_NVAL | G_IO_HUP | G_IO_ERR,
                                   fd_ready, NULL);
            if (source) return SHELL_EVENTFD;
        }
    }
    if (strict_fd) return -1;
    source = start_timer();
    return source ? SHELL_TIMER : -1;
}

void shell_remove_pump(void) {
    g_assert(shell_on_gtk_thread());
    if (source) g_source_remove(source);
    source = 0;
    run_turn = NULL;
}
