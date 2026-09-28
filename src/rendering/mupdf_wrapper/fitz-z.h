#include "mupdf/fitz.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename);
fz_document *fz_open_document_from_bytes_z(fz_context *ctx, const char *magic, const unsigned char *data, size_t size);
int fz_count_pages_z(fz_context *ctx, fz_document *doc);
fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number);
void fz_run_page_z(fz_context *ctx, fz_page *page, fz_device *dev, fz_matrix ctm, fz_cookie *cookie);
fz_pixmap *fz_new_pixmap_with_bbox_z(fz_context *ctx, fz_colorspace *cs, fz_irect bbox, fz_colorspace *seps, int alpha);
fz_device *fz_new_draw_device_z(fz_context *ctx, fz_matrix ctm, fz_pixmap *pix);

/* Text einer Seite für die Suche: je Zeichen Codepunkt und Box in Seitenkoordinaten (pt).
   Zeilenende als ' ', Blockende als '\n', beide mit leerer Box. Die Felder legt mupdf an
   (fz_malloc), freigeben mit fz_free. Rückgabe: Anzahl Zeichen, -1 bei Fehler. */
int fz_page_text_z(fz_context *ctx, fz_document *doc, int page_number, int **codes_out, fz_rect **boxes_out);
