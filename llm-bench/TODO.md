# TODO

**Stand 20.08.2026, spätabends: alle Punkte erledigt.** Das Gesamtfazit
des Projekts steht in `FAZIT.md`.

- [x] **LM Studio aufgeräumt** — 20.08. erledigt: `~/.lmstudio/models`
  (23 GB, mit ~11 GB Duplikaten) gelöscht, nachdem die
  Qwen3.5-Testkandidaten gemessen und nach
  `models/` (zid-Repo) gesichert waren; toter
  KoboldCpp-Symlink mit entfernt. Platte: **77 %, 56 GB frei** (am Morgen
  waren es 88 % / 31 GB).

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
- [x] **Qwen3.5-4B und Qwen3.5-2B getestet** — 20.08. erledigt, **kein
  Upgrade**: 4B hält 10/10, ist aber langsamer als Qwen3-4B-2507 und
  denkt kostenpflichtig; 2B fällt mit 6/10 durch. Testsieger bleibt
  Qwen3-4B-2507. Nachtrag 2 in
  `results/linux-i7-8850H-gpu-und-neue-modelle.md`; beide GGUFs nach
  `models/` (zid-Repo) gesichert.
- [x] **Ollama-Modelle und HF-Cache aufgeräumt** — 20.08. erledigt: 17
  Ollama-Modelle plus HF-Hub gelöscht, Platte von 91 % auf **79 % (53 GB
  frei)**. Inventar mit allen Namen und Inspirations-Notizen:
  `docs/modell-inventar-2026-08-20.md`. Nicht angerührt (war
  nicht im Umfang): `~/.lmstudio/models` mit 23 GB — grösster
  verbliebener Posten, enthält aber die Qwen3.5-Testkandidaten (siehe
  unten).
- [x] **März-Dokumente zusammengeführt** — 20.08. erledigt:
  `docs/lokale-llm-provider-maerz-2026.md` konsolidiert alle
  drei; Originale und `pi-start` in `docs/archiv/`, das
  Streuverzeichnis `~/agents/` ist aufgelöst.
