#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef void (*ShellCallback)(void);
typedef enum { SHELL_AUTO, SHELL_TIMER, SHELL_MISSING, SHELL_EVENTFD } ShellPump;

// Services Dispatch main-queue and MainActor jobs on GTK's startup pthread.
// Independent Foundation timers and other RunLoop sources need their own driver.
int shell_install_pump(ShellPump mode, ShellCallback turn);
void shell_remove_pump(void);
bool shell_on_gtk_thread(void);
const char *shell_effective_pump(void);
uint64_t shell_pump_wakes(void);
uint64_t shell_pump_yields(void);

enum { PROBE_SAMPLES = 128, PROBE_LANES = 16, PROBE_FIFO = 64 };
typedef void (*ProbeStart)(bool busy);
int shell_probe_run(bool busy, ProbeStart pressed, const char *capture_dir);
void shell_probe_mark(int slot, int sequence, uint64_t latency_ns);
void shell_probe_fifo(int sequence);
bool shell_probe_load_step(int slot);
void shell_probe_turn_finished(void);

#include "library_io.h"

#include "scratchpad_panel.h"
#include "reader_window.h"
#include "web_reader.h"
