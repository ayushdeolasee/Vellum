#include "CShell.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

enum { duration_us = 1500000, starvation_us = 120000 };
static const char *paths[] = {"MainActor", "Dispatch"};
static const char *expected[] = {"MainActor OK", "Dispatch OK"};
static GtkApplication *app;
static GtkWidget *labels[2], *trigger, *input, *bar;
static ProbeStart submit;
static const char *capture_dir;
static bool under_load;
static int count[2], work[2], drained[2], result = 1;
static uint64_t latency_ns[2][PROBE_SAMPLES], idle_wakes;
static gint64 idle_start, start, deadline;
static guint input_source, tick;
static clock_t idle_cpu, active_cpu;
static long threads[2];
static int fifo, no_progress, last_progress, paint_priority;

typedef struct { gint64 last, gap; int count; } Observer;
static Observer clicks, paints;
static int idle_calls, jobs_with_idle[2];

static gboolean competing_idle(gpointer unused) {
    static gint64 until;
    static int initial[2];
    if (idle_calls++ == 0) {
        until = g_get_monotonic_time() + 150000;
        memcpy(initial, work, sizeof(initial));
    }
    if (g_get_monotonic_time() < until) return G_SOURCE_CONTINUE;
    for (int i = 0; i < 2; ++i) jobs_with_idle[i] = work[i] - initial[i];
    return G_SOURCE_REMOVE;
}

static void observe(Observer *observer, gint64 now) {
    if (!start || now > deadline) return;
    observer->gap = MAX(observer->gap, now - observer->last);
    observer->last = now;
    ++observer->count;
}

void shell_probe_turn_finished(void) {
    int progress = fifo + count[0] + count[1] + work[0] + work[1];
    if (progress == last_progress) ++no_progress;
    last_progress = progress;
}

void shell_probe_fifo(int sequence) {
    g_assert(shell_on_gtk_thread() && sequence == fifo);
    ++fifo;
}

bool shell_probe_load_step(int slot) {
    ++work[slot];
    if (g_get_monotonic_time() < deadline) return true;
    ++drained[slot];
    return false;
}

static int compare_latency(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static void input_clicked(GtkButton *button, gpointer unused) {
    observe(&clicks, g_get_monotonic_time());
}

static gboolean emit_input(gpointer unused) {
    g_signal_emit_by_name(input, "clicked");
    return G_SOURCE_CONTINUE;
}

static gboolean request_frame(GtkWidget *widget, GdkFrameClock *clock, gpointer unused) {
    gtk_widget_queue_draw(widget);
    return G_SOURCE_CONTINUE;
}

// A fresh Cairo snapshot from GTK's frame clock, independently of input and Swift.
static void draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer unused) {
    gint64 now = g_get_monotonic_time();
    if (!start) return;
    observe(&paints, now);
    if (now <= deadline)
        paint_priority = g_source_get_priority(g_main_current_source());
    cairo_set_source_rgb(cr, 0.20, 0.45, 0.64);
    cairo_rectangle(cr, 0, 0, width * MIN(1.0, (double)(now - start) / duration_us), height);
    cairo_fill(cr);
}

static gboolean finish_when_drained(gpointer unused);

static void clicked(GtkButton *button, gpointer unused) {
    if (start || !idle_start) return;
    start = g_get_monotonic_time();
    active_cpu = clock();
    deadline = start + duration_us;
    if (under_load) {
        clicks.last = paints.last = start;
        g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, competing_idle, NULL, NULL);
        input_source = g_timeout_add_full(G_PRIORITY_DEFAULT_IDLE, 5, emit_input, NULL, NULL);
        tick = gtk_widget_add_tick_callback(bar, request_frame, NULL, NULL);
    }
    submit(under_load);
    g_timeout_add(10, finish_when_drained, NULL);
}

static gboolean begin_samples(gpointer unused) {
    g_print("idle_wall_us=%" G_GINT64_FORMAT " idle_cpu_ms=%.3f idle_wakes=%" G_GUINT64_FORMAT "\n",
            g_get_monotonic_time() - idle_start,
            1000.0 * (clock() - idle_cpu) / CLOCKS_PER_SEC, shell_pump_wakes() - idle_wakes);
    gtk_widget_set_sensitive(trigger, TRUE);
    g_signal_emit_by_name(trigger, "clicked");
    return G_SOURCE_REMOVE;
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

static gboolean finish_when_drained(gpointer unused) {
    if (count[0] != PROBE_SAMPLES || count[1] != PROBE_SAMPLES) return G_SOURCE_CONTINUE;
    if (under_load && (drained[0] != PROBE_LANES || drained[1] != PROBE_LANES))
        return G_SOURCE_CONTINUE;
    result = fifo == PROBE_FIFO ? 0 : 1;
    if (under_load) {
        g_source_remove(input_source);
        gtk_widget_remove_tick_callback(bar, tick);
        // Include both boundaries even if the first GTK update came after the backlog drained.
        clicks.gap = MAX(clicks.gap, deadline - clicks.last);
        paints.gap = MAX(paints.gap, deadline - paints.last);
        g_print("input=%d input_gap_us=%ld paints=%d paint_gap_us=%ld paint_priority=%d "
                "lanes_per_path=%d actor_jobs=%d dispatch_jobs=%d\n",
                clicks.count, (long)clicks.gap, paints.count, (long)paints.gap,
                paint_priority, PROBE_LANES, work[0], work[1]);
        g_print("always_ready_calls=%d concurrent_actor_jobs=%d concurrent_dispatch_jobs=%d\n",
                idle_calls, jobs_with_idle[0], jobs_with_idle[1]);
        if (idle_calls < 2 || MIN(jobs_with_idle[0], jobs_with_idle[1]) == 0 ||
            !clicks.count || !paints.count || paint_priority <= G_PRIORITY_DEFAULT ||
            clicks.gap > starvation_us || paints.gap > starvation_us ||
            MIN(work[0], work[1]) <= PROBE_LANES)
            result = 1;
    }
    g_print("effective=%s turns=%" G_GUINT64_FORMAT " yields=%" G_GUINT64_FORMAT
            " no_progress=%d fifo=%d active_wall_us=%ld active_cpu_ms=%.2f\n",
            shell_effective_pump(), shell_pump_wakes(), shell_pump_yields(), no_progress, fifo,
            (long)(g_get_monotonic_time() - start), 1000.0 * (clock() - active_cpu) / CLOCKS_PER_SEC);
    for (int i = 0; i < 2; ++i) {
        if (!gtk_widget_get_mapped(labels[i]) ||
            strcmp(gtk_label_get_text(GTK_LABEL(labels[i])), expected[i]) != 0)
            result = 1;
        qsort(latency_ns[i], PROBE_SAMPLES, sizeof(uint64_t), compare_latency);
        g_print("path=%s tid=%ld samples=%d p50_us=%.2f p95_us=%.2f max_us=%.2f\n",
                paths[i], threads[i], PROBE_SAMPLES, latency_ns[i][63] / 1000.0,
                latency_ns[i][121] / 1000.0, latency_ns[i][127] / 1000.0);
    }
    if (result == 0 && capture_dir) {
        GdkFrameClock *clock = gtk_widget_get_frame_clock(labels[0]);
        g_signal_connect(clock, "after-paint", G_CALLBACK(after_paint), NULL);
        gtk_widget_queue_draw(labels[0]);
    } else {
        g_application_quit(G_APPLICATION(app));
    }
    return G_SOURCE_REMOVE;
}

void shell_probe_mark(int slot, int sequence, uint64_t elapsed) {
    g_assert(shell_on_gtk_thread() && count[slot] < PROBE_SAMPLES);
    if (slot == 1) g_assert(sequence == count[slot]); // Serial producer to serial Dispatch queue.
    threads[slot] = syscall(SYS_gettid);
    latency_ns[slot][count[slot]++] = elapsed;
    if (count[slot] == PROBE_SAMPLES)
        gtk_label_set_text(GTK_LABEL(labels[slot]), expected[slot]);
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
    gtk_widget_set_sensitive(trigger, FALSE);
    input = gtk_button_new_with_label("Input");
    bar = gtk_drawing_area_new();
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(bar), 4);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(bar), draw, NULL, NULL);
    gtk_box_append(GTK_BOX(box), bar);
    gtk_box_append(GTK_BOX(box), trigger);
    gtk_box_append(GTK_BOX(box), input);
    g_signal_connect(trigger, "clicked", G_CALLBACK(clicked), NULL);
    g_signal_connect(input, "clicked", G_CALLBACK(input_clicked), NULL);
    gtk_window_present(GTK_WINDOW(window));
    g_timeout_add(250, baseline, NULL);
}

int shell_probe_run(bool busy, ProbeStart pressed, const char *capture) {
    under_load = busy;
    submit = pressed;
    capture_dir = capture;
    app = gtk_application_new("org.vellum.LoopProbe", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activated), NULL);
    int status = g_application_run(G_APPLICATION(app), 0, NULL);
    g_object_unref(app);
    return status ? status : result;
}
