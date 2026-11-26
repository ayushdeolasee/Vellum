#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef void (*ShellCallback)(void);
typedef enum { SHELL_AUTO, SHELL_TIMER, SHELL_MISSING, SHELL_EVENTFD } ShellPump;

// Returns the selected pump, or -1 if the requested pump is unavailable.
int shell_install_pump(ShellPump mode, ShellCallback turn);
void shell_remove_pump(void);
bool shell_on_gtk_thread(void);
uint64_t shell_pump_wakes(void);

int shell_probe_run(bool busy, ShellCallback pressed, const char *capture_dir);
void shell_probe_mark(int slot, uint64_t latency_ns);

#include "library_io.h"
