#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ScratchpadPanel ScratchpadPanel;
typedef struct _GtkWidget GtkWidget;
typedef struct _GdkTexture GdkTexture;

typedef enum {
    SCRATCHPAD_SHOW, SCRATCHPAD_CHANGE, SCRATCHPAD_SAVE, SCRATCHPAD_ATTACH
} ScratchpadEvent;
typedef void (*ScratchpadCallback)(ScratchpadEvent, const char *text, void *context);

ScratchpadPanel *scratchpad_panel_new(void);
GtkWidget *scratchpad_panel_widget(ScratchpadPanel *panel);
GtkWidget *scratchpad_panel_toggle(ScratchpadPanel *panel);
void scratchpad_panel_connect(ScratchpadPanel *panel, ScratchpadCallback callback, void *context);
void scratchpad_panel_disconnect(ScratchpadPanel *panel);
bool scratchpad_panel_visible(ScratchpadPanel *panel);
void scratchpad_panel_show(ScratchpadPanel *panel);
void scratchpad_panel_set_note(ScratchpadPanel *panel, const char *markdown);
void scratchpad_panel_set_state(ScratchpadPanel *panel, const char *message,
                                bool available, bool editable, bool can_save);
void scratchpad_panel_set_import_directory(ScratchpadPanel *panel, const char *path);
void scratchpad_panel_clear_images(ScratchpadPanel *panel);
GdkTexture *scratchpad_image_decode(const char *format, const uint8_t *bytes, size_t length);
void scratchpad_image_release(GdkTexture *texture);
void scratchpad_panel_add_image(ScratchpadPanel *panel, GdkTexture *texture);
