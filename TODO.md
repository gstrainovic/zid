# TODO

- [x] **Mehrdatei-Härtetest: Qwen3-4B (Testsieger) und Llama-3.2-3B
  (Tempo-Kontrast)** — am 20.08.2026 erledigt, **beide gescheitert**:
  Qwen3 kapituliert sauber (ändert nichts, erklärt die Tests für falsch),
  Llama überschreibt destruktiv die Produktionsdatei mit Testcode.
  Details und Lehre in `CODING-AGENTEN.md`, „Härtegrad 2". Weitere
  Engine-/Geräte-Kombinationen unnötig: temperature=0 macht das Verhalten
  geräteunabhängig, die Grenze ist die Modellklasse.

- [ ] **xLAM durch den Werkzeugwahl-Test jagen.** `xlam-2-1b` liegt im
  Ollama-Bestand — ein auf Tool-Calling spezialisiertes 1B-Modell
  (Salesforce xLAM), genau die Lücke im Testfeld. GGUF beschaffen (Hugging
  Face oder aus dem Ollama-Blob), dann `agent_eval.py` + `probe.py` auf
  Engine b10524, CPU und P1000.
- [ ] **Ollama-Modelle (~42 GB) und HF-Cache aufräumen** — Platte ist 88 %
  voll, und `llama-server` hat Ollama hier ersetzt. Reihenfolge: **erst
  Liste erstellen** (Modelle, Grössen, was als Inspiration fürs
  llama.cpp-Setup taugt — Kandidaten: `phi4-mini-16k` als 16k-Kontext-Idee,
  `qwen3-vl:2b/4b` für Vision, `xlam-2-1b` siehe oben), **dann löschen**.
  HF-Cache enthält zudem die frühen 1.58-Bit-Experimente
  (`1bitLLM/bitnet_b1_58-*`, `brunopio/Llama3-8B-1.58`).
- [ ] **Die drei verstreuten März-Dokumente zusammenführen:**
  `~/agents/readme.md` (ausführlichstes, mit Qwen3-4B-Pi-Test),
  `~/projects/agents/PI-PROVIDER-REFERENCE.md` und
  `PROVIDER-SETUP-COMPLETE.md` → ein Dokument, der Rest wird archiviert.
  Zielort: `~/projects/agents/`.
