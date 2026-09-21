#include "mupdf/fitz.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename);
fz_document *fz_open_document_from_bytes_z(fz_context *ctx, const char *magic, const unsigned char *data, size_t size);
int fz_count_pages_z(fz_context *ctx, fz_document *doc);
fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number);
void fz_run_page_z(fz_context *ctx, fz_page *page, fz_device *dev, fz_matrix ctm, fz_cookie *cookie);
fz_pixmap *fz_new_pixmap_with_bbox_z(fz_context *ctx, fz_colorspace *cs, fz_irect bbox, fz_colorspace *seps, int alpha);
fz_device *fz_new_draw_device_z(fz_context *ctx, fz_matrix ctm, fz_pixmap *pix);

/* Schreibender Teil: HTML/CSS über die Story-Engine in ein PDF layouten.
   Alle Funktionen kapseln fz_try/fz_catch; int-Rückgaben sind 0 = ok, -1 = Fehler. */
fz_buffer *fz_new_buffer_from_copied_data_z(fz_context *ctx, const unsigned char *data, size_t size);
fz_story *fz_new_story_z(fz_context *ctx, fz_buffer *buf, const char *user_css, float em, fz_archive *dir);
int fz_place_story_z(fz_context *ctx, fz_story *story, fz_rect where, fz_rect *filled, int *more);
int fz_draw_story_z(fz_context *ctx, fz_story *story, fz_device *dev, fz_matrix ctm);
fz_document_writer *fz_new_document_writer_z(fz_context *ctx, const char *path, const char *format, const char *options);
fz_device *fz_begin_page_z(fz_context *ctx, fz_document_writer *wri, fz_rect mediabox);
int fz_end_page_z(fz_context *ctx, fz_document_writer *wri);
int fz_close_document_writer_z(fz_context *ctx, fz_document_writer *wri);
int fz_fill_rect_z(fz_context *ctx, fz_device *dev, fz_rect rect, fz_colorspace *cs, const float *color, float alpha);
