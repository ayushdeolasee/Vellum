#include "CPdfiumJob.h"
#include <fpdfview.h>
#include <fpdf_edit.h>
#include <fpdf_text.h>
#include <math.h>
#include <stdlib.h>

static bool initialized;

void pdf_worker_shutdown(void) {
    if (initialized) {
        FPDF_DestroyLibrary();
        initialized = false;
    }
}

static PdfStatus render(FPDF_PAGE page, double scale, PdfJobResult *out) {
    // Round and check in floating point before converting to int or allocating.
    double width = round(out->width_pt * scale);
    double height = round(out->height_pt * scale);
    if (!isfinite(width) || !isfinite(height) || width < 1 || height < 1 ||
        width > 16384 || height > 16384 || width * height > 16 * 1024 * 1024)
        return PDF_BAD_DIMENSIONS;

    int w = (int)width, h = (int)height, stride = w * 4;
    size_t size = (size_t)stride * h;
    uint8_t *pixels = malloc(size);
    if (!pixels)
        return PDF_ENGINE_ERROR;
    // PDFium borrows our tightly packed allocation. It stays owned by the
    // result after the bitmap handle is destroyed.
    FPDF_BITMAP bitmap = FPDFBitmap_CreateEx(w, h, FPDFBitmap_BGRx, pixels, stride);
    if (!bitmap || FPDFBitmap_GetStride(bitmap) != stride ||
        !FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0xffffffff)) {
        if (bitmap)
            FPDFBitmap_Destroy(bitmap);
        free(pixels);
        return PDF_ENGINE_ERROR;
    }
    // Intrinsic rotation and crop are already applied by the page renderer.
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, w, h, 0, FPDF_ANNOT);
    FPDFBitmap_Destroy(bitmap);
    for (size_t i = 3; i < size; i += 4)
        pixels[i] = 0xff;
    out->pixels = pixels;
    out->width = w;
    out->height = h;
    out->stride = stride;
    return PDF_OK;
}

static PdfStatus extract(FPDF_PAGE page, PdfJobResult *out) {
    FPDF_TEXTPAGE text = FPDFText_LoadPage(page);
    if (!text)
        return PDF_ENGINE_ERROR;
    int count = FPDFText_CountChars(text);
    PdfStatus status = PDF_ENGINE_ERROR;
    if (count > 250000) {
        status = PDF_LIMIT;
    } else if (count >= 0) {
        PdfCharacter *chars = count ? calloc((size_t)count, sizeof(*chars)) : NULL;
        if (count && !chars)
            goto close;
        for (int i = 0; i < count; ++i) {
            PdfCharacter *c = &chars[i];
            int generated = FPDFText_IsGenerated(text, i);
            if (generated < 0 || !FPDFText_GetCharBox(text, i, &c->left, &c->right,
                                                       &c->bottom, &c->top) ||
                !isfinite(c->left) || !isfinite(c->right) ||
                !isfinite(c->bottom) || !isfinite(c->top)) {
                free(chars);
                goto close;
            }
            c->generated = generated != 0;
            c->unicode = FPDFText_GetUnicode(text, i);
        }
        out->characters = chars;
        out->character_count = count;
        status = PDF_OK;
    }
close:
    FPDFText_ClosePage(text);
    return status;
}

PdfStatus pdf_run_job(PdfOperation op, const void *bytes, size_t length,
                      const char *password, int page_index, double scale,
                      PdfJobResult *out) {
    *out = (PdfJobResult){0};
    if (!bytes || !length)
        return PDF_BAD_DOCUMENT;
    if (length > PDF_MAX_INPUT_BYTES)
        return PDF_LIMIT;
    if (!initialized) {
        FPDF_LIBRARY_CONFIG config = {0};
        config.version = 2;
        FPDF_InitLibraryWithConfig(&config);
        initialized = true;
    }
    FPDF_DOCUMENT doc = FPDF_LoadMemDocument64(bytes, length, password);
    if (!doc) {
        switch (FPDF_GetLastError()) {
        case FPDF_ERR_PASSWORD: return PDF_PASSWORD_REQUIRED;
        case FPDF_ERR_SECURITY: return PDF_SECURITY_ERROR;
        case FPDF_ERR_FORMAT: return PDF_BAD_DOCUMENT;
        default: return PDF_ENGINE_ERROR;
        }
    }
    PdfStatus status = PDF_BAD_PAGE;
    FPDF_PAGE page = NULL;
    out->pages = FPDF_GetPageCount(doc);
    if (out->pages > 100000) {
        status = PDF_LIMIT;
        goto close;
    }
    if (page_index < 0 || page_index >= out->pages)
        goto close;
    page = FPDF_LoadPage(doc, page_index);
    if (!page)
        goto close;
    out->width_pt = FPDF_GetPageWidthF(page);
    out->height_pt = FPDF_GetPageHeightF(page);
    int turns = FPDFPage_GetRotation(page);
    if (!isfinite(out->width_pt) || !isfinite(out->height_pt) ||
        out->width_pt <= 0 || out->height_pt <= 0 || turns < 0 || turns > 3) {
        status = PDF_BAD_DIMENSIONS;
        goto close;
    }
    out->rotation = turns * 90;
    switch (op) {
    case PDF_INFO: status = PDF_OK; break;
    case PDF_BITMAP: status = render(page, scale, out); break;
    case PDF_TEXT: status = extract(page, out); break;
    }
close:
    if (page)
        FPDF_ClosePage(page);
    FPDF_CloseDocument(doc);
    return status;
}
