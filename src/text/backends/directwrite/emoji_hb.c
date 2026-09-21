/* Emoji-Folgen formen unter Windows.
 *
 * zid rastert unter Windows mit DirectWrite und formt sonst Zeichen für Zeichen
 * (SimpleShaper). Zusammengesetzte Emoji (👩‍💻, 👍🏽, 1️⃣, 🇩🇪) entstehen aber erst durch
 * die GSUB-Ligaturen der Schrift. Dafür nimmt zid das HarfBuzz, das in MuPDFs
 * Drittbibliothek ohnehin gelinkt ist: die Symbole heissen dort fzhb_* (hb-rename.h,
 * über hb.h eingebunden), und der Speicher läuft über einen MuPDF-Kontext. Jeder
 * Aufruf muss deshalb zwischen fz_hb_lock und fz_hb_unlock stehen.
 */
#include <stdlib.h>
#include "mupdf/fitz.h"
#include "hb.h"

typedef struct {
	fz_context *ctx;
	hb_font_t *font;
	unsigned int upem;
} zid_hb;

typedef struct {
	unsigned int glyph;
	unsigned int cluster;
	int x_advance;
	int x_offset;
	int y_offset;
} zid_hb_glyph;

/* Schrift aus Datei laden; NULL, wenn es nicht geht. */
void *zid_hb_open(const char *path)
{
	fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
	zid_hb *h;
	hb_blob_t *blob;
	hb_face_t *face;

	if (!ctx)
		return NULL;
	h = calloc(1, sizeof(*h));
	if (!h) {
		fz_drop_context(ctx);
		return NULL;
	}
	h->ctx = ctx;

	fz_hb_lock(ctx);
	blob = hb_blob_create_from_file_or_fail(path);
	if (blob) {
		face = hb_face_create(blob, 0);
		hb_blob_destroy(blob);
		h->upem = hb_face_get_upem(face);
		h->font = hb_font_create(face);
		hb_face_destroy(face);
	}
	fz_hb_unlock(ctx);

	if (!h->font) {
		fz_drop_context(ctx);
		free(h);
		return NULL;
	}
	return h;
}

/* Einheiten je Em; Vorschübe und Versätze aus zid_hb_shape sind in diesen Einheiten. */
unsigned int zid_hb_upem(void *hv)
{
	return ((zid_hb *)hv)->upem;
}

/* UTF-8-Text formen; liefert die Zahl der Glyphen (höchstens max). `cluster` ist der
 * Byte-Offset im Text. */
int zid_hb_shape(void *hv, const char *text, int len, zid_hb_glyph *out, int max)
{
	zid_hb *h = hv;
	hb_buffer_t *buf;
	hb_glyph_info_t *info;
	hb_glyph_position_t *pos;
	unsigned int count = 0, i;
	int n = 0;

	fz_hb_lock(h->ctx);
	buf = hb_buffer_create();
	hb_buffer_add_utf8(buf, text, len, 0, len);
	hb_buffer_guess_segment_properties(buf);
	hb_shape(h->font, buf, NULL, 0);
	info = hb_buffer_get_glyph_infos(buf, &count);
	pos = hb_buffer_get_glyph_positions(buf, &count);
	for (i = 0; i < count && n < max; i++, n++) {
		out[n].glyph = info[i].codepoint;
		out[n].cluster = info[i].cluster;
		out[n].x_advance = pos[i].x_advance;
		out[n].x_offset = pos[i].x_offset;
		out[n].y_offset = pos[i].y_offset;
	}
	hb_buffer_destroy(buf);
	fz_hb_unlock(h->ctx);
	return n;
}

void zid_hb_close(void *hv)
{
	zid_hb *h = hv;
	if (!h)
		return;
	fz_hb_lock(h->ctx);
	hb_font_destroy(h->font);
	fz_hb_unlock(h->ctx);
	fz_drop_context(h->ctx);
	free(h);
}
