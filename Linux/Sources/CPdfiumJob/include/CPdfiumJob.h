#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { PDF_MAX_INPUT_BYTES = 128 * 1024 * 1024 };

typedef enum { PDF_INFO, PDF_BITMAP, PDF_TEXT } PdfOperation;
typedef enum {
    PDF_OK, PDF_BAD_DOCUMENT, PDF_PASSWORD_REQUIRED, PDF_SECURITY_ERROR,
    PDF_BAD_PAGE, PDF_BAD_DIMENSIONS, PDF_LIMIT, PDF_ENGINE_ERROR
} PdfStatus;

typedef struct {
    uint32_t unicode;
    double left, bottom, right, top;
    bool generated;
} PdfCharacter;

typedef struct {
    int pages, rotation;             // Clockwise degrees; dimensions are already rotated.
    double width_pt, height_pt;
    double visible_left, visible_bottom; // Unrotated media/crop intersection in PDF user space.
    int width, height, stride;
    uint8_t *pixels;                 // Top-down opaque BGRA, malloc-owned.
    int character_count;
    PdfCharacter *characters;        // PDFium character order, malloc-owned.
} PdfJobResult;

// Call only on the process-wide PDFium worker. Input and password are borrowed
// through return. On success the caller owns the two nullable output buffers.
PdfStatus pdf_run_job(PdfOperation op, const void *bytes, size_t length,
                      const char *password, int page_index, double scale,
                      PdfJobResult *out);
void pdf_worker_shutdown(void);
