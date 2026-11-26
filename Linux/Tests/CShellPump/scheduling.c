// Exercise the real pump against GLib with a permanently readable, borrowed test fd.
#include "CShell.h"
#include <glib.h>
#include <sys/eventfd.h>
#include <unistd.h>

static int handle, turns, idle_calls;
static gint64 returned_at, resumed_at;

int _dispatch_get_main_queue_handle_4CF(void) { return handle; }

static gboolean always_ready(gpointer unused) {
    ++idle_calls;
    return G_SOURCE_CONTINUE;
}

static void slow_turn(void) {
    ++turns;
    g_usleep(12000); // Longer than the timer interval and the old fd slice.
    returned_at = g_get_monotonic_time();
}

static void check_handoff(ShellPump mode, gint priority) {
    turns = idle_calls = 0;
    g_assert_cmpint(shell_install_pump(mode, slow_turn), ==, mode);
    while (!turns) g_main_context_iteration(NULL, TRUE);
    guint idle = g_idle_add_full(priority, always_ready, NULL, NULL);
    for (int i = 1; i <= 3; ++i) {
        // Deschedule BETWEEN dispatch rounds until either wall-clock resume is overdue.
        g_usleep(15000);
        g_main_context_iteration(NULL, FALSE);
        g_assert_cmpint(idle_calls, ==, i);
        g_assert_cmpint(turns, ==, i);
        g_main_context_iteration(NULL, FALSE);
        g_assert_cmpint(turns, ==, i + 1);
    }
    shell_remove_pump();
    g_source_remove(idle);
}

static void replacement(void) {
    ++turns;
    resumed_at = g_get_monotonic_time();
    shell_remove_pump();
}

static void replace_inside_turn(void) {
    slow_turn();
    shell_remove_pump();
    g_assert_cmpint(shell_install_pump(SHELL_TIMER, replacement), ==, SHELL_TIMER);
}

static void check_replacement(ShellPump mode) {
    turns = 0;
    g_assert_cmpint(shell_install_pump(mode, replace_inside_turn), ==, mode);
    while (turns < 2) g_main_context_iteration(NULL, TRUE);
    g_assert_cmpint(resumed_at - returned_at, >=, 8000);
    g_usleep(15000);
    g_assert_false(g_main_context_iteration(NULL, FALSE));
    g_assert_cmpstr(shell_effective_pump(), ==, "stopped");
}

static void timed_turn(void) {
    if (turns) {
        gint64 gap = g_get_monotonic_time() - returned_at;
        g_assert_cmpint(gap, >=, 8000);
        g_print("timer post-turn gap: %.2f ms\n", gap / 1000.0);
    }
    slow_turn();
}

int main(void) {
    handle = eventfd(1, EFD_NONBLOCK | EFD_CLOEXEC);
    g_assert_cmpint(handle, >=, 0);
    ShellPump modes[] = { SHELL_EVENTFD, SHELL_TIMER };
    for (unsigned i = 0; i < G_N_ELEMENTS(modes); ++i) {
        check_handoff(modes[i], G_PRIORITY_HIGH_IDLE + 20); // GTK redraw (120)
        check_handoff(modes[i], G_PRIORITY_DEFAULT_IDLE);   // Synthetic input (200)
        check_replacement(modes[i]);
    }
    turns = 0;
    shell_install_pump(SHELL_TIMER, timed_turn);
    while (turns < 3) g_main_context_iteration(NULL, TRUE);
    shell_remove_pump();
    g_assert_cmpint(close(handle), ==, 0);
    g_print("Delayed handoff, always-ready peers, timer spacing and teardown passed\n");
}
