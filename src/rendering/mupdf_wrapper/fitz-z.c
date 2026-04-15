#include "fitz-z.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename) {
  fz_document *doc = NULL;
  fz_try(ctx) { doc = fz_open_document(ctx, filename); }
  fz_catch(ctx) {}
  return doc;
}

int fz_count_pages_z(fz_context *ctx, fz_document *doc) {
  int count = 0;
  fz_try(ctx) { count = fz_count_pages(ctx, doc); }
  fz_catch(ctx) {}
  return count;
}

fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number) {
  fz_page *page = NULL;
  fz_try(ctx) { page = fz_load_page(ctx, doc, page_number); }
  fz_catch(ctx) {}
  return page;
}

void fz_run_page_z(fz_context *ctx, fz_page *page, fz_device *dev, fz_matrix ctm, fz_cookie *cookie) {
  fz_try(ctx) { fz_run_page(ctx, page, dev, ctm, cookie); }
  fz_catch(ctx) {}
}

fz_pixmap *fz_new_pixmap_with_bbox_z(fz_context *ctx, fz_colorspace *cs, fz_irect bbox, fz_colorspace *seps, int alpha) {
  fz_pixmap *pix = NULL;
  fz_try(ctx) { pix = fz_new_pixmap_with_bbox(ctx, cs, bbox, seps, alpha); }
  fz_catch(ctx) {}
  return pix;
}

fz_device *fz_new_draw_device_z(fz_context *ctx, fz_matrix ctm, fz_pixmap *pix) {
  fz_device *dev = NULL;
  fz_try(ctx) { dev = fz_new_draw_device(ctx, ctm, pix); }
  fz_catch(ctx) {}
  return dev;
}
