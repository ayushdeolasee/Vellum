#include "CShell.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

enum { samples = 64, input_interval_ms = 2, starvation_limit_us = 100000 };
static const char *paths[] = {"MainActor", "Dispatch"};
static const char *expected[] = {"MainActor OK", "Dispatch OK"};
static GtkApplication *app;
static GtkWidget *labels[2], *trigger, *input;
static ShellCallback submit;
static const char *capture_dir;
static bool under_load, outstanding;
static int completed, marks, result = 1;
static uint64_t latency_ns[2][samples], idle_wakes;
static gint64 idle_start, last_input, max_gap;
static guint input_source, input_count;
static clock_t idle_cpu;
static long threads[2];

static int compare_latency(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static void clicked(GtkButton *button, gpointer unused) {
    if (outstanding || completed == samples) return;
    outstanding = true;
    marks = 0;
    submit();
}

static gboolean emit_sample(gpointer unused) {
    g_signal_emit_by_name(trigger, "clicked");
    return G_SOURCE_REMOVE;
}

static void record_input_gap(void) {
    gint64 now = g_get_monotonic_time();
    max_gap = MAX(max_gap, now - last_input);
    last_input = now;
}

static void input_clicked(GtkButton *button, gpointer unused) {
    record_input_gap();
    ++input_count;
    gtk_widget_queue_draw(GTK_WIDGET(button));
}

static gboolean emit_input(gpointer unused) {
    g_signal_emit_by_name(input, "clicked");
    return G_SOURCE_CONTINUE;
}

static gboolean begin_samples(gpointer unused) {
    g_print("idle_wall_us=%" G_GINT64_FORMAT " idle_cpu_ms=%.3f idle_wakes=%" G_GUINT64_FORMAT "\n",
            g_get_monotonic_time() - idle_start,
            1000.0 * (clock() - idle_cpu) / CLOCKS_PER_SEC, shell_pump_wakes() - idle_wakes);
    if (under_load) {
        last_input = g_get_monotonic_time();
        input_source = g_timeout_add(input_interval_ms, emit_input, NULL);
    }
    return emit_sample(NULL);
}

static gboolean baseline(gpointer unused) {
    idle_start = g_get_monotonic_time();
    idle_cpu = clock();
    idle_wakes = shell_pump_wakes();
    g_timeout_add(1000, begin_samples, NULL);
    return G_SOURCE_REMOVE;
}

static gboolean wait_for_capture(gpointer path) {
    if (!g_file_test(path, G_FILE_TEST_EXISTS)) return G_SOURCE_CONTINUE;
    g_application_quit(G_APPLICATION(app));
    return G_SOURCE_REMOVE;
}

static void after_paint(GdkFrameClock *clock, gpointer unused) {
    g_signal_handlers_disconnect_by_func(clock, after_paint, NULL);
    g_autofree char *ready = g_build_filename(capture_dir, "ready", NULL);
    if (!g_file_set_contents(ready, "", 0, NULL)) {
        result = 1;
        g_application_quit(G_APPLICATION(app));
        return;
    }
    g_timeout_add_full(G_PRIORITY_DEFAULT, 20, wait_for_capture,
                       g_build_filename(capture_dir, "captured", NULL), g_free);
}

static void finish(void) {
    result = 0;
    if (under_load) {
        g_source_remove(input_source);
        record_input_gap(); // Include the time since the final input signal.
        g_print("input_clicks=%u input_max_gap_us=%" G_GINT64_FORMAT "\n", input_count, max_gap);
        if (!input_count || max_gap > starvation_limit_us) result = 1;
    }
    for (int i = 0; i < 2; ++i) {
        if (!gtk_widget_get_mapped(labels[i]) ||
            strcmp(gtk_label_get_text(GTK_LABEL(labels[i])), expected[i]) != 0)
            result = 1;
        qsort(latency_ns[i], samples, sizeof(uint64_t), compare_latency);
        g_print("path=%s tid=%ld samples=%d p50_us=%.2f p95_us=%.2f max_us=%.2f\n",
                paths[i], threads[i], samples, latency_ns[i][31] / 1000.0,
                latency_ns[i][60] / 1000.0, latency_ns[i][63] / 1000.0);
    }
    if (result == 0 && capture_dir) {
        GdkFrameClock *clock = gtk_widget_get_frame_clock(labels[0]);
        g_signal_connect(clock, "after-paint", G_CALLBACK(after_paint), NULL);
        gtk_widget_queue_draw(labels[0]);
    } else {
        g_application_quit(G_APPLICATION(app));
    }
}

void shell_probe_mark(int slot, uint64_t elapsed) {
    g_assert(shell_on_gtk_thread() && outstanding && (slot == 0 || slot == 1));
    g_assert(completed < samples && !(marks & (1 << slot)));
    threads[slot] = syscall(SYS_gettid);
    latency_ns[slot][completed] = elapsed;
    gtk_label_set_text(GTK_LABEL(labels[slot]), expected[slot]);
    marks |= 1 << slot;
    if (marks == 3) {
        outstanding = false;
        if (++completed == samples) finish();
        else g_timeout_add(5, emit_sample, NULL);
    }
}

static void activated(GtkApplication *application, gpointer unused) {
    g_assert(shell_on_gtk_thread());
    g_print("gtk_tid=%ld\n", syscall(SYS_gettid));
    GtkWidget *window = gtk_application_window_new(application);
    gtk_window_set_title(GTK_WINDOW(window), "Vellum");
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    gtk_window_set_child(GTK_WINDOW(window), box);
    GtkWidget *title = gtk_label_new("Vellum · GTK loop probe");
    gtk_widget_add_css_class(title, "title-1");
    gtk_box_append(GTK_BOX(box), title);
    for (int i = 0; i < 2; ++i) {
        labels[i] = gtk_label_new(paths[i]);
        gtk_box_append(GTK_BOX(box), labels[i]);
    }
    trigger = gtk_button_new_with_label("Probe");
    input = gtk_button_new_with_label("Input");
    gtk_box_append(GTK_BOX(box), trigger);
    gtk_box_append(GTK_BOX(box), input);
    g_signal_connect(trigger, "clicked", G_CALLBACK(clicked), NULL);
    g_signal_connect(input, "clicked", G_CALLBACK(input_clicked), NULL);
    gtk_window_present(GTK_WINDOW(window));
    g_timeout_add(250, baseline, NULL);
}

int shell_probe_run(bool busy, ShellCallback pressed, const char *capture) {
    under_load = busy;
    submit = pressed;
    capture_dir = capture;
    app = gtk_application_new("org.vellum.LoopProbe", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activated), NULL);
    int status = g_application_run(G_APPLICATION(app), 0, NULL);
    g_object_unref(app);
    return status ? status : result;
}
