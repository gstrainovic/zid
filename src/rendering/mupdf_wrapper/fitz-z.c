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

/* --- Text für die Suche ---------------------------------------------------- */

typedef struct {
  int *codes;
  fz_rect *boxes;
  int len, cap;
} zid_text;

static void zid_text_push(fz_context *ctx, zid_text *t, int code, fz_rect box) {
  if (t->len == t->cap) {
    int cap = t->cap ? t->cap * 2 : 1024;
    t->codes = fz_realloc(ctx, t->codes, (size_t)cap * sizeof(int));
    t->boxes = fz_realloc(ctx, t->boxes, (size_t)cap * sizeof(fz_rect));
    t->cap = cap;
  }
  t->codes[t->len] = code;
  t->boxes[t->len] = box;
  t->len++;
}

/* Strukturblöcke (Tagged PDF) enthalten weitere Blöcke: rekursiv absteigen. */
static void zid_text_blocks(fz_context *ctx, zid_text *t, fz_stext_block *block) {
  const fz_rect none = {0, 0, 0, 0};
  for (; block; block = block->next) {
    if (block->type == FZ_STEXT_BLOCK_TEXT) {
      for (fz_stext_line *line = block->u.t.first_line; line; line = line->next) {
        for (fz_stext_char *ch = line->first_char; ch; ch = ch->next)
          zid_text_push(ctx, t, ch->c, fz_rect_from_quad(ch->quad));
        zid_text_push(ctx, t, ' ', none);
      }
      zid_text_push(ctx, t, '\n', none);
    } else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
      zid_text_blocks(ctx, t, block->u.s.down->first_block);
    }
  }
}

int fz_page_text_z(fz_context *ctx, fz_document *doc, int page_number, int **codes_out, fz_rect **boxes_out) {
  zid_text t = {0};
  fz_page *page = NULL;
  fz_stext_page *text = NULL;
  int rc = -1;
  fz_var(page);
  fz_var(text);
  fz_try(ctx) {
    page = fz_load_page(ctx, doc, page_number);
    text = fz_new_stext_page_from_page(ctx, page, NULL);
    zid_text_blocks(ctx, &t, text->first_block);
    rc = t.len;
  }
  fz_always(ctx) {
    fz_drop_stext_page(ctx, text);
    fz_drop_page(ctx, page);
  }
  fz_catch(ctx) {
    fz_free(ctx, t.codes);
    fz_free(ctx, t.boxes);
    t.codes = NULL;
    t.boxes = NULL;
  }
  *codes_out = t.codes;
  *boxes_out = t.boxes;
  return rc;
}
