#include "mupdf/fitz.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename);
int fz_count_pages_z(fz_context *ctx, fz_document *doc);
fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number);
void fz_run_page_z(fz_context *ctx, fz_page *page, fz_device *dev, fz_matrix ctm, fz_cookie *cookie);
fz_pixmap *fz_new_pixmap_with_bbox_z(fz_context *ctx, fz_colorspace *cs, fz_irect bbox, fz_colorspace *seps, int alpha);
fz_device *fz_new_draw_device_z(fz_context *ctx, fz_matrix ctm, fz_pixmap *pix);
