#pragma once
#include <stdbool.h>

typedef struct ReaderWindow ReaderWindow;
typedef struct PdfAnnotations PdfAnnotations;
typedef struct _GtkWidget GtkWidget;
typedef enum {
    PDF_DRAG, PDF_POINT, PDF_FIND, PDF_PICK, PDF_HIGHLIGHT, PDF_NOTE, PDF_UPDATE, PDF_DELETE, PDF_DISCARD
} PdfAnnotationAction;
// Pointer coordinates and overlay rectangles are fractions of the fitted bitmap.
typedef void (*PdfAnnotationCallback)(PdfAnnotationAction, double, double, double, double, void *);
PdfAnnotations *reader_pdf_annotations(ReaderWindow *);
GtkWidget *pdf_annotations_new(GtkWidget *picture, PdfAnnotations **out);
void pdf_annotations_bind(PdfAnnotations *, PdfAnnotationCallback, void *context);
void pdf_annotations_reset(PdfAnnotations *);
void pdf_annotations_show_discard(PdfAnnotations *, bool);
void pdf_annotations_add(PdfAnnotations *, const char *name);
int pdf_annotations_picked(PdfAnnotations *);
void pdf_annotations_pick(PdfAnnotations *, int index);
const char *pdf_annotations_query(PdfAnnotations *);
const char *pdf_annotations_content(PdfAnnotations *);
void pdf_annotations_set_content(PdfAnnotations *, const char *);
void pdf_annotations_controls(PdfAnnotations *, bool highlight, bool note, bool edit);
void pdf_annotations_message(PdfAnnotations *, const char *);
void pdf_annotations_clear_rects(PdfAnnotations *);
void pdf_annotations_rect(PdfAnnotations *, double x, double y, double width, double height);
