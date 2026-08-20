# TODO

- [x] **Mehrdatei-Härtetest: Qwen3-4B (Testsieger) und Llama-3.2-3B
  (Tempo-Kontrast)** — am 20.08.2026 erledigt, **beide gescheitert**:
  Qwen3 kapituliert sauber (ändert nichts, erklärt die Tests für falsch),
  Llama überschreibt destruktiv die Produktionsdatei mit Testcode.
  Details und Lehre in `CODING-AGENTEN.md`, „Härtegrad 2". Weitere
  Engine-/Geräte-Kombinationen unnötig: temperature=0 macht das Verhalten
  geräteunabhängig, die Grenze ist die Modellklasse.

- [x] **xLAM durch den Werkzeugwahl-Test jagen** — 20.08. erledigt:
  **8/10, keine Empfehlung.** Schnellstes Modell des Projekts (45 tok/s auf
  der P1000), aber schwächere Werkzeugwahl als die Generalisten und grobe
  Ausfälle bei Rechnen/Anweisungen. Details im Nachtrag von
  `results/linux-i7-8850H-gpu-und-neue-modelle.md`.
- [ ] **Qwen3.5-4B und Qwen3.5-2B testen** (liegen in `~/.lmstudio/models/`,
  neuer als der Benchmark-Sieger) — bevor LM Studio (23 GB, mit ~11 GB
  Duplikaten) aufgeräumt wird.
- [x] **Ollama-Modelle und HF-Cache aufgeräumt** — 20.08. erledigt: 17
  Ollama-Modelle plus HF-Hub gelöscht, Platte von 91 % auf **79 % (53 GB
  frei)**. Inventar mit allen Namen und Inspirations-Notizen:
  `~/projects/agents/modell-inventar-2026-08-20.md`. Nicht angerührt (war
  nicht im Umfang): `~/.lmstudio/models` mit 23 GB — grösster
  verbliebener Posten, enthält aber die Qwen3.5-Testkandidaten (siehe
  unten).
- [x] **März-Dokumente zusammengeführt** — 20.08. erledigt:
  `~/projects/agents/lokale-llm-provider-maerz-2026.md` konsolidiert alle
  drei; Originale und `pi-start` in `~/projects/agents/archiv/`, das
  Streuverzeichnis `~/agents/` ist aufgelöst.
