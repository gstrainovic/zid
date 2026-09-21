#include "fitz-z.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename) {
  fz_document *doc = NULL;
  fz_try(ctx) { doc = fz_open_document(ctx, filename); }
  fz_catch(ctx) {}
  return doc;
}

/* Dokument aus einer Kopie im Speicher öffnen. Das Dokument hält Stream und Puffer
   selbst; die Datei bleibt dadurch nicht offen. Unter Windows könnte ein anderes
   Programm eine offene Datei sonst nicht per Rename ersetzen (Zugriff verweigert).
   `magic` ist der Dateiname, mupdf wählt daran den Handler. */
fz_document *fz_open_document_from_bytes_z(fz_context *ctx, const char *magic, const unsigned char *data, size_t size) {
  fz_document *doc = NULL;
  fz_buffer *buf = NULL;
  fz_stream *stm = NULL;
  fz_var(buf);
  fz_var(stm);
  fz_try(ctx) {
    buf = fz_new_buffer_from_copied_data(ctx, data, size);
    stm = fz_open_buffer(ctx, buf);
    doc = fz_open_document_with_stream(ctx, magic, stm);
  }
  fz_always(ctx) {
    fz_drop_stream(ctx, stm);
    fz_drop_buffer(ctx, buf);
  }
  fz_catch(ctx) { doc = NULL; }
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

/* --- Schreibender Teil ---------------------------------------------------
   fz_try/fz_catch braucht setjmp; Zig kann das nicht, deshalb liegt jeder
   Aufruf hier gekapselt. int-Rückgaben: 0 = ok, -1 = Fehler. */

fz_buffer *fz_new_buffer_from_copied_data_z(fz_context *ctx, const unsigned char *data, size_t size) {
  fz_buffer *buf = NULL;
  fz_try(ctx) { buf = fz_new_buffer_from_copied_data(ctx, data, size); }
  fz_catch(ctx) {}
  return buf;
}

fz_story *fz_new_story_z(fz_context *ctx, fz_buffer *buf, const char *user_css, float em, fz_archive *dir) {
  fz_story *story = NULL;
  fz_try(ctx) { story = fz_new_story(ctx, buf, user_css, em, dir); }
  fz_catch(ctx) {}
  return story;
}

int fz_place_story_z(fz_context *ctx, fz_story *story, fz_rect where, fz_rect *filled, int *more) {
  int rc = -1;
  fz_try(ctx) {
    *more = fz_place_story(ctx, story, where, filled);
    rc = 0;
  }
  fz_catch(ctx) {}
  return rc;
}

int fz_draw_story_z(fz_context *ctx, fz_story *story, fz_device *dev, fz_matrix ctm) {
  int rc = -1;
  fz_try(ctx) {
    fz_draw_story(ctx, story, dev, ctm);
    rc = 0;
  }
  fz_catch(ctx) {}
  return rc;
}

fz_document_writer *fz_new_document_writer_z(fz_context *ctx, const char *path, const char *format, const char *options) {
  fz_document_writer *wri = NULL;
  fz_try(ctx) { wri = fz_new_document_writer(ctx, path, format, options); }
  fz_catch(ctx) {}
  return wri;
}

fz_device *fz_begin_page_z(fz_context *ctx, fz_document_writer *wri, fz_rect mediabox) {
  fz_device *dev = NULL;
  fz_try(ctx) { dev = fz_begin_page(ctx, wri, mediabox); }
  fz_catch(ctx) {}
  return dev;
}

int fz_end_page_z(fz_context *ctx, fz_document_writer *wri) {
  int rc = -1;
  fz_try(ctx) {
    fz_end_page(ctx, wri);
    rc = 0;
  }
  fz_catch(ctx) {}
  return rc;
}

int fz_close_document_writer_z(fz_context *ctx, fz_document_writer *wri) {
  int rc = -1;
  fz_try(ctx) {
    fz_close_document_writer(ctx, wri);
    rc = 0;
  }
  fz_catch(ctx) {}
  return rc;
}

int fz_fill_rect_z(fz_context *ctx, fz_device *dev, fz_rect rect, fz_colorspace *cs, const float *color, float alpha) {
  int rc = -1;
  fz_try(ctx) {
    fz_path *path = fz_new_path(ctx);
    fz_moveto(ctx, path, rect.x0, rect.y0);
    fz_lineto(ctx, path, rect.x1, rect.y0);
    fz_lineto(ctx, path, rect.x1, rect.y1);
    fz_lineto(ctx, path, rect.x0, rect.y1);
    fz_closepath(ctx, path);
    fz_fill_path(ctx, dev, path, 0, fz_identity, cs, color, alpha, fz_default_color_params);
    fz_drop_path(ctx, path);
    rc = 0;
  }
  fz_catch(ctx) {}
  return rc;
}
