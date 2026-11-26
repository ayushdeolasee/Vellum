#pragma once
#include <stdbool.h>

struct ReaderWindow;
typedef struct ReaderChatPanel ReaderChatPanel;
ReaderChatPanel *reader_chat_panel(struct ReaderWindow *window);
bool reader_chat_visible(ReaderChatPanel *panel);
const char *reader_chat_draft(ReaderChatPanel *panel);
void reader_chat_set_draft(ReaderChatPanel *panel, const char *text);
void reader_chat_set_transcript(ReaderChatPanel *panel, const char *text);
void reader_chat_append(ReaderChatPanel *panel, const char *text);
void reader_chat_state(ReaderChatPanel *panel, const char *message, bool ready, bool streaming);
void reader_chat_retry_visible(ReaderChatPanel *panel, bool visible);
