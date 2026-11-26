#include "CShell.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <glib.h>
#include <pthread.h>

typedef struct {
    GSource source;
    GPollFD fd; // Borrowed from Dispatch. A negative fd selects the timer.
    gint64 next_tick;
    bool strict_fd, yield_next;
    ShellCallback turn;
} Pump;

static Pump *pump;
static pthread_t owner;
static uint64_t wakes, yields;

const char *shell_effective_pump(void) {
    if (!pump) return "stopped";
    return pump->fd.fd >= 0 ? "eventfd" : "timer";
}

bool shell_on_gtk_thread(void) { return pthread_equal(owner, pthread_self()) != 0; }
uint64_t shell_pump_wakes(void) { return wakes; }
uint64_t shell_pump_yields(void) { return yields; }

static gboolean prepare(GSource *source, gint *timeout_ms) {
    Pump *p = (Pump *)source;
    if (p->yield_next) {
        *timeout_ms = 0; // Poll GTK even if the fd is still readable or the timer is overdue.
        return FALSE;
    }
    if (p->fd.fd >= 0) {
        *timeout_ms = -1;
        return FALSE;
    }
    gint64 remaining = MAX((gint64)0, p->next_tick - g_source_get_time(source));
    *timeout_ms = (gint)((remaining + 999) / 1000);
    return remaining == 0;
}

static gboolean check(GSource *source) {
    Pump *p = (Pump *)source;
    if (p->yield_next) {
        // Decline this entire selection round. GLib can dispatch its highest ready
        // non-pump priority. Next round Swift is eligible at normal priority again.
        p->yield_next = false;
        ++yields;
        return FALSE;
    }
    return p->fd.fd >= 0 ? p->fd.revents != 0 : g_source_get_time(source) >= p->next_tick;
}

static gboolean dispatch(GSource *source, GSourceFunc unused, gpointer data) {
    Pump *p = (Pump *)source;
    g_assert(shell_on_gtk_thread());
    if (p->fd.fd >= 0 && (p->fd.revents & (G_IO_NVAL | G_IO_HUP | G_IO_ERR))) {
        if (p->strict_fd) g_error("effective=failed strict eventfd condition=0x%x", p->fd.revents);
        g_warning("eventfd condition=0x%x effective=timer", p->fd.revents);
        g_source_remove_poll(source, &p->fd);
        p->fd.fd = -1;
    } else {
        ++wakes;
        p->turn();
        // A job can remove this source and even install a different pump.
        if (g_source_is_destroyed(source)) return G_SOURCE_REMOVE;
    }
    p->yield_next = true;
    if (p->fd.fd < 0) p->next_tick = g_get_monotonic_time() + 8000;
    return G_SOURCE_CONTINUE;
}

int shell_install_pump(ShellPump mode, ShellCallback turn) {
    g_assert(!pump && turn);
    owner = pthread_self();
    int fd = -1;
    if (mode != SHELL_TIMER && mode != SHELL_MISSING) {
        typedef int (*GetHandle)(void);
        GetHandle get = (GetHandle)dlsym(RTLD_DEFAULT, "_dispatch_get_main_queue_handle_4CF");
        if (get) fd = get();
        if (fd >= 0 && fcntl(fd, F_GETFD) == -1) fd = -1;
    }
    if (fd < 0 && mode == SHELL_EVENTFD) return -1;

    static GSourceFuncs functions = { .prepare = prepare, .check = check, .dispatch = dispatch };
    pump = (Pump *)g_source_new(&functions, sizeof(Pump));
    pump->turn = turn;
    pump->strict_fd = mode == SHELL_EVENTFD;
    pump->fd = (GPollFD){ .fd = fd, .events = G_IO_IN | G_IO_ERR | G_IO_HUP | G_IO_NVAL };
    if (fd >= 0) g_source_add_poll(&pump->source, &pump->fd);
    else pump->next_tick = g_get_monotonic_time() + 8000;
    wakes = yields = 0;
    g_source_attach(&pump->source, NULL);
    return fd >= 0 ? SHELL_EVENTFD : SHELL_TIMER;
}

void shell_remove_pump(void) {
    g_assert(shell_on_gtk_thread());
    if (!pump) return;
    g_source_destroy(&pump->source);
    g_source_unref(&pump->source);
    pump = NULL;
}
