#include "CShell.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <glib-unix.h>
#include <pthread.h>

static pthread_t owner;
static guint source;
static ShellCallback run_turn;
static uint64_t wakes, yields;
static gint64 slice_start, last_turn_end;
static bool strict_fd;
static const char *effective;

const char *shell_effective_pump(void) { return effective; }

bool shell_on_gtk_thread(void) {
    return pthread_equal(owner, pthread_self()) != 0;
}

uint64_t shell_pump_wakes(void) { return wakes; }
uint64_t shell_pump_yields(void) { return yields; }

static gboolean service_swift(gpointer unused) {
    g_assert(shell_on_gtk_thread());
    ++wakes;
    run_turn();
    return G_SOURCE_CONTINUE;
}

static guint start_timer(void) {
    effective = "timer";
    return g_timeout_add(8, service_swift, NULL);
}

static guint watch_fd(int fd);

static gboolean resume_fd(gpointer data) {
    slice_start = g_get_monotonic_time();
    source = watch_fd(GPOINTER_TO_INT(data));
    return G_SOURCE_REMOVE;
}

static gboolean fd_ready(gint fd, GIOCondition condition, gpointer unused) {
    if (condition & (G_IO_NVAL | G_IO_HUP | G_IO_ERR)) {
        if (strict_fd) g_error("effective=failed strict eventfd condition=0x%x", condition);
        g_warning("eventfd condition=0x%x effective=timer", condition);
        source = start_timer();
        return G_SOURCE_REMOVE;
    }
    // Dispatch owns the descriptor and consumes its wake during the Swift turn.
    gint64 start = g_get_monotonic_time();
    if (start - last_turn_end >= 2000) slice_start = start;
    service_swift(NULL);
    last_turn_end = g_get_monotonic_time();
    // A level-ready fd at default priority can indefinitely suppress GTK redraws.
    // Leave a 1 ms scheduling gap after a 2 ms burst, including long single turns.
    if (last_turn_end - slice_start >= 2000) {
        ++yields;
        source = g_timeout_add(1, resume_fd, GINT_TO_POINTER(fd));
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static guint watch_fd(int fd) {
    return g_unix_fd_add(fd, G_IO_IN | G_IO_NVAL | G_IO_HUP | G_IO_ERR, fd_ready, NULL);
}

int shell_install_pump(ShellPump mode, ShellCallback turn) {
    g_assert(!source && turn);
    owner = pthread_self();
    run_turn = turn;
    wakes = yields = 0;
    last_turn_end = 0;
    strict_fd = mode == SHELL_EVENTFD;
    if (mode != SHELL_TIMER) {
        typedef int (*GetHandle)(void);
        GetHandle get = mode == SHELL_MISSING ? NULL :
            (GetHandle)dlsym(RTLD_DEFAULT, "_dispatch_get_main_queue_handle_4CF");
        int fd = get ? get() : -1;
        if (fd >= 0 && fcntl(fd, F_GETFD) != -1) {
            source = watch_fd(fd);
            if (source) {
                effective = "eventfd";
                return SHELL_EVENTFD;
            }
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
