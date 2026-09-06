# Fazit — lokale Modelle auf kleiner Hardware, Stand 20.08.2026

Drei Messrunden (Windows i5-13500T, Linux i7-8850H CPU, Linux GPU + neue
Modelle), neun getestete Modelle, zwei Praxistests mit einem echten
Coding-Agenten. Alles Weitere in `results/`, `CODING-AGENTEN.md` und
`CLAUDE.md`; hier steht, was am Ende zählt.

## Der Testsieger

**Qwen3-4B-Instruct-2507 (Q4_K_M) auf der Quadro P1000 via Vulkan.**

Als einziges Modell fehlerfrei in allem, was messbar war: 10/10
Werkzeugwahl, alle sechs Stichproben korrekt (einschliesslich der
strikten Formatvorgabe, an der die Hälfte des Feldes scheitert), und im
Praxistest schliesst es als einziges den Fix-Zyklus — Bug finden, Fehlschlag
lesen, sich selbst korrigieren, ohne fremde Dateien zu zerstören. 19.3 tok/s
auf der GPU, 9.9 auf der CPU.

Die Plätze dahinter, je nach Einsatz:

| Einsatz | Modell | Warum |
|---|---|---|
| Maschine ohne (brauchbare) GPU | **BitNet-b1.58-2B-4T** | 22.4 tok/s rein auf der CPU — schneller als jedes 4B-Modell auf der P1000; 9/10 Werkzeugwahl. Braucht die gepinnte Engine und den Tokenizer-Override (`CLAUDE.md`). |
| Maximaler GPU-Durchsatz | Llama-3.2-3B | 24.1 tok/s, aber 9/10 — und im Härtetest destruktiv. |
| Nicht nehmen | Gemma-3-4B (8/10, stille Fehlgriffe), Qwen3.5-2B (6/10), xLAM-2-1B (8/10, rechnet grotesk falsch), OLMoE/colibri (4/10) | Details in `results/`. |
| Kein Upgrade | Qwen3.5-4B | hält 10/10, ist aber langsamer als Qwen3-4B-2507 und bezahlt jede Antwort mit Denk-Tokens. |

Zwei übertragbare Lehren aus dem Feld: **Unterhalb von ~3 B Parametern
trägt die Allgemeinfähigkeit nicht** — auch nicht bei
Spezialisierung auf Tool-Calling (xLAM) oder neuerer Generation
(Qwen3.5-2B). Und: **Werkzeugwahl-Quote und Agententauglichkeit sind
verwandt, aber nicht dasselbe** — die 9/10 gegen 10/10 wurden im
Praxistest zum Unterschied zwischen „zerstört eine Datei" und „kapituliert
sauber".

## Wie anwenden

```bash
# Endpunkt starten (Qwen3-4B auf der P1000, OpenAI-kompatibel, Port 8080)
cd ~/projects/bitnet-colibri-bench && ./setup/serve-coding-agent.sh

# Pi-Agent (Provider "llamacpp-lokal" ist in ~/.pi/agent/models.json eingerichtet)
pi --provider llamacpp-lokal --model qwen3-4b-lokal --tools bash

# VSCode: jede Erweiterung mit konfigurierbarem OpenAI-Endpunkt
# (z. B. Continue.dev) auf http://127.0.0.1:8080/v1 zeigen lassen
```

Regeln, die sich bewährt haben: Agenten-Experimente **nur in
Git-Repos** (`git restore` hat einen zerstörten Praxistest in einer
Sekunde geheilt); die Engine-Zuordnung aus `CLAUDE.md` einhalten (BitNet
nur auf der gepinnten Engine, die Neuen nur auf b10524); und
`bench/agent_eval.py` als Regressionstest benutzen, bevor ein neues
Modell den Agenten-Platz bekommt — der Test hat in einem Tag vier
Kandidaten aussortiert, die sich gut anhörten.

## Was damit möglich ist — und was nicht

**Möglich**, belegt durch Messung oder Praxistest:

- **Werkzeug-Agenten:** fehlerfreie Werkzeugwahl über den
  OpenAI-Tool-Call-Standard, damit alles von „wie viel Platz hat meine
  Platte" bis zu skriptbaren Arbeitsabläufen.
- **Klar umrissene Ein-Datei-Coding-Aufgaben mit Test-Feedback:** Bug
  suchen, fixen, Tests laufen lassen, iterieren. Ein typischer
  Agentenschritt dauert 5–15 s.
- **Unbegrenzt, offline, privat:** kein Kontingent, kein Internet nötig,
  kein Byte Code verlässt den Rechner — der eigentliche Vorzug gegenüber
  jeder kostenlosen Cloud-KI.

**Nicht möglich** in dieser Modellklasse, zweifach belegt:

- **Dateiübergreifendes Debugging.** Beide Praxistest-Kandidaten sind an
  zwei Fehlern über zwei Dateien gescheitert — nicht am Werkzeuggebrauch,
  sondern am Schlussfolgern und Rechnen über Dateigrenzen. Hier ist jede
  kostenlose Cloud-KI (Copilot Free, Gemini Code Assist) klar überlegen.
- **Lange Refactorings:** die Prompt-Verarbeitung (96 tok/s auf der
  P1000) wird zum Engpass, weil der Agentenkontext mit jedem Schritt
  wächst.

Die daraus folgende Arbeitsteilung: **lokal für Autocomplete, kleine
Fixes und alles Vertrauliche; Cloud, wenn die Aufgabe über Dateigrenzen
denkt.** Die Grenze dazwischen ist in diesem Repo nicht geschätzt,
sondern gemessen.
