#include "pdf_annotations.h"
#include <gtk/gtk.h>
#include <math.h>

struct PdfAnnotations {
    GtkWidget *picture, *canvas, *query, *content, *picker, *status;
    GtkWidget *highlight, *note, *update, *remove;
    GtkStringList *items;
    GArray *rects;
    PdfAnnotationCallback callback;
    void *context;
    gboolean started, confirming;
    double x, y;
};

static void emit(PdfAnnotations *p, PdfAnnotationAction action) {
    if (p->callback) p->callback(action, 0, 0, 0, 0, p->context);
}

static void clicked(GtkButton *button, PdfAnnotations *p) {
    PdfAnnotationAction action = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "pdf-action"));
    if (action == PDF_DELETE && !p->confirming) {
        p->confirming = TRUE;
        gtk_button_set_label(button, "Confirm delete");
        pdf_annotations_message(p, "Remove from the current page? Earlier revisions in this PDF retain the annotation.");
        return;
    }
    emit(p, action);
}

static GtkWidget *button(GtkWidget *row, const char *label, PdfAnnotationAction action, PdfAnnotations *p) {
    GtkWidget *b = gtk_button_new_with_label(label);
    g_object_set_data(G_OBJECT(b), "pdf-action", GINT_TO_POINTER(action));
    g_signal_connect(b, "clicked", G_CALLBACK(clicked), p);
    gtk_box_append(GTK_BOX(row), b);
    return b;
}

static GtkWidget *field(GtkWidget *row, const char *name) {
    GtkWidget *entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), name);
    gtk_accessible_update_property(GTK_ACCESSIBLE(entry), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
    gtk_widget_set_hexpand(entry, TRUE);
    gtk_box_append(GTK_BOX(row), entry);
    return entry;
}

static void picked(GObject *picker, GParamSpec *pspec, PdfAnnotations *p) { emit(p, PDF_PICK); }
static void find(GtkEntry *entry, PdfAnnotations *p) { emit(p, PDF_FIND); }

// GtkPicture uses CONTAIN and centers its paintable in the allocation. The
// canvas fills the same overlay and follows it through every window resize.
static gboolean fitted(PdfAnnotations *p, graphene_rect_t *r) {
    GdkPaintable *image = gtk_picture_get_paintable(GTK_PICTURE(p->picture));
    if (!image) return FALSE;
    int iw = gdk_paintable_get_intrinsic_width(image), ih = gdk_paintable_get_intrinsic_height(image);
    int w = gtk_widget_get_width(p->canvas), h = gtk_widget_get_height(p->canvas);
    if (iw <= 0 || ih <= 0 || w <= 0 || h <= 0) return FALSE;
    double scale = MIN((double)w / iw, (double)h / ih);
    graphene_rect_init(r, (w - iw * scale) / 2, (h - ih * scale) / 2, iw * scale, ih * scale);
    return TRUE;
}

static void draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    PdfAnnotations *p = data;
    graphene_rect_t page;
    if (!fitted(p, &page)) return;
    cairo_set_source_rgba(cr, 0.12, 0.43, 0.88, 0.35);
    for (guint i = 0; i < p->rects->len; i++) {
        graphene_rect_t r = g_array_index(p->rects, graphene_rect_t, i);
        cairo_rectangle(cr, page.origin.x + r.origin.x * page.size.width,
                        page.origin.y + r.origin.y * page.size.height,
                        MAX(3, r.size.width * page.size.width), MAX(3, r.size.height * page.size.height));
    }
    cairo_fill(cr);
}

static void start(GtkGestureDrag *drag, double x, double y, PdfAnnotations *p) {
    graphene_rect_t r;
    p->started = fitted(p, &r) && x >= r.origin.x && y >= r.origin.y &&
        x <= r.origin.x + r.size.width && y <= r.origin.y + r.size.height;
    p->x = x;
    p->y = y;
}

static void gesture(GtkGestureDrag *drag, double dx, double dy, PdfAnnotations *p, gboolean finished) {
    graphene_rect_t r;
    if (!p->started || !p->callback || !fitted(p, &r)) return;
    gboolean point = fabs(dx) < 3 && fabs(dy) < 3;
    if (point && !finished) return;
    double x = (p->x - r.origin.x) / r.size.width, y = (p->y - r.origin.y) / r.size.height;
    p->callback(point ? PDF_POINT : PDF_DRAG, x, y, CLAMP(x + dx/r.size.width, 0, 1),
                CLAMP(y + dy/r.size.height, 0, 1), p->context);
}
static void moved(GtkGestureDrag *drag, double dx, double dy, PdfAnnotations *p) {
    gesture(drag, dx, dy, p, FALSE);
}
static void ended(GtkGestureDrag *drag, double dx, double dy, PdfAnnotations *p) {
    gesture(drag, dx, dy, p, TRUE);
    p->started = FALSE;
}

static void free_panel(gpointer data) {
    PdfAnnotations *p = data;
    g_array_unref(p->rects);
    g_free(p);
}

GtkWidget *pdf_annotations_new(GtkWidget *picture, PdfAnnotations **out) {
    PdfAnnotations *p = *out = g_new0(PdfAnnotations, 1);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    g_object_set_data_full(G_OBJECT(box), "pdf-panel", p, free_panel);
    p->rects = g_array_new(FALSE, FALSE, sizeof(graphene_rect_t));
    p->picture = picture;
    GtkWidget *overlay = gtk_overlay_new();
    gtk_widget_set_vexpand(overlay, TRUE);
    gtk_box_append(GTK_BOX(box), overlay);
    gtk_overlay_set_child(GTK_OVERLAY(overlay), picture);
    p->canvas = gtk_drawing_area_new();
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(p->canvas), draw, p, NULL);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), p->canvas);
    gtk_widget_set_cursor_from_name(p->canvas, "text");
    GtkGesture *drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(start), p);
    g_signal_connect(drag, "drag-update", G_CALLBACK(moved), p);
    g_signal_connect(drag, "drag-end", G_CALLBACK(ended), p);
    gtk_widget_add_controller(p->canvas, GTK_EVENT_CONTROLLER(drag));

    GtkWidget *expander = gtk_expander_new("Annotations");
    gtk_accessible_update_property(GTK_ACCESSIBLE(expander), GTK_ACCESSIBLE_PROPERTY_LABEL, "Annotations", -1);
    gtk_box_append(GTK_BOX(box), expander);
    GtkWidget *tools = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_expander_set_child(GTK_EXPANDER(expander), tools);
    GtkWidget *create = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_append(GTK_BOX(tools), create);
    p->query = field(create, "Find text on page");
    g_signal_connect(p->query, "activate", G_CALLBACK(find), p);
    button(create, "Select text", PDF_FIND, p);
    p->highlight = button(create, "Add highlight", PDF_HIGHLIGHT, p);
    p->note = button(create, "Add note", PDF_NOTE, p);

    GtkWidget *edit = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_box_append(GTK_BOX(tools), edit);
    p->items = gtk_string_list_new(NULL);
    p->picker = gtk_drop_down_new(G_LIST_MODEL(p->items), NULL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(p->picker), GTK_ACCESSIBLE_PROPERTY_LABEL, "Page annotations", -1);
    g_signal_connect(p->picker, "notify::selected", G_CALLBACK(picked), p);
    gtk_box_append(GTK_BOX(edit), p->picker);
    p->content = field(edit, "Annotation comment");
    p->update = button(edit, "Save comment", PDF_UPDATE, p);
    p->remove = button(edit, "Delete", PDF_DELETE, p);
    gtk_widget_set_tooltip_text(p->remove, "Earlier PDF revisions retain edited or deleted comments.");
    gtk_widget_set_tooltip_text(p->update, "Earlier PDF revisions retain the previous comment.");
    p->status = gtk_label_new(NULL);
    gtk_label_set_selectable(GTK_LABEL(p->status), TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(p->status), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(tools), p->status);
    return box;
}

void pdf_annotations_bind(PdfAnnotations *p, PdfAnnotationCallback cb, void *ctx) {
    p->callback = cb;
    p->context = ctx;
}
void pdf_annotations_reset(PdfAnnotations *p) {
    p->callback = NULL;
    p->started = FALSE;
    const char *initial[] = { "Page annotations", NULL };
    gtk_string_list_splice(p->items, 0, g_list_model_get_n_items(G_LIST_MODEL(p->items)), initial);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(p->picker), 0);
    gtk_editable_set_text(GTK_EDITABLE(p->query), "");
    pdf_annotations_set_content(p, "");
    pdf_annotations_clear_rects(p);
    pdf_annotations_controls(p, FALSE, FALSE, FALSE);
    pdf_annotations_message(p, "Loading annotations…");
}
void pdf_annotations_add(PdfAnnotations *p, const char *name) { gtk_string_list_append(p->items, name); }
int pdf_annotations_picked(PdfAnnotations *p) { return (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(p->picker)) - 1; }
void pdf_annotations_pick(PdfAnnotations *p, int index) { gtk_drop_down_set_selected(GTK_DROP_DOWN(p->picker), index + 1); }
const char *pdf_annotations_query(PdfAnnotations *p) { return gtk_editable_get_text(GTK_EDITABLE(p->query)); }
const char *pdf_annotations_content(PdfAnnotations *p) { return gtk_editable_get_text(GTK_EDITABLE(p->content)); }
void pdf_annotations_set_content(PdfAnnotations *p, const char *s) { gtk_editable_set_text(GTK_EDITABLE(p->content), s); }
void pdf_annotations_controls(PdfAnnotations *p, bool highlight, bool note, bool edit) {
    p->confirming = FALSE;
    gtk_button_set_label(GTK_BUTTON(p->remove), "Delete");
    gtk_widget_set_sensitive(p->highlight, highlight);
    gtk_widget_set_sensitive(p->note, note);
    gtk_widget_set_sensitive(p->update, edit);
    gtk_widget_set_sensitive(p->remove, edit);
    gtk_editable_set_editable(GTK_EDITABLE(p->content), note || edit);
}
void pdf_annotations_message(PdfAnnotations *p, const char *s) {
    gtk_label_set_text(GTK_LABEL(p->status), s);
    gtk_widget_set_tooltip_text(p->status, s);
}
void pdf_annotations_clear_rects(PdfAnnotations *p) {
    g_array_set_size(p->rects, 0);
    gtk_widget_queue_draw(p->canvas);
}
void pdf_annotations_rect(PdfAnnotations *p, double x, double y, double w, double h) {
    graphene_rect_t r;
    graphene_rect_init(&r, x, y, w, h);
    g_array_append_val(p->rects, r);
    gtk_widget_queue_draw(p->canvas);
}
