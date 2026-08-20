# Lokale Modelle als Coding-Agenten

Dieses Dokument verbindet zwei Experimente: das Provider-Setup für den
Pi-Agenten vom März 2026 (Notizen in `~/projects/agents/`) und die Messungen
dieses Repos. Das eine lieferte die Agenten-Seite, das andere beantwortet,
welches Modell auf welchem Gerät die Arbeit tragen kann.

## Was der März gelernt hat (und was davon bleibt)

Damals wurde der Pi-Agent an vier Provider angebunden. Der Stand von damals,
abgeglichen mit dem, was heute noch auf der Maschine liegt:

| Provider (März) | Befund damals | Stand heute |
|---|---|---|
| Groq (Cloud) | Tool-Calling perfekt, ~500 tok/s, kostenlos | funktioniert, aber Cloud — nicht Gegenstand dieses Repos |
| KoboldCpp | ~10–15 tok/s, 7B im CPU/GPU-Split | installiert (`~/.local/koboldcpp/`), durch `llama-server` ersetzt |
| LM Studio | nie installiert | — |
| Ollama | Tool-Calling defekt (Bugs #9632, #12557) | Modelle noch da (`qwen2.5-coder` 3B/7B), durch `llama-server` ersetzt |

Die zwei Lehren, die bleiben:

1. **Tool-Calling ist das Nadelöhr**, nicht der Durchsatz. Genau das misst
   `bench/agent_eval.py` — die Werkzeugquoten dieses Repos sind das
   Auswahlkriterium für Agentenmodelle.
2. **Ein einziger OpenAI-kompatibler Endpunkt genügt.** Der Pi-Agent (und
   jeder andere Agent mit konfigurierbarer `baseUrl`) braucht keinen
   speziellen Provider — `llama-server` aus diesem Projekt ist einer.

## Die Modellwahl folgt aus den Messungen

Für Coding-Agenten auf diesem Laptop (i7-8850H + Quadro P1000), Engine
`b10524` aus `results/linux-i7-8850H-gpu-und-neue-modelle.md`:

| Empfehlung | Modell | Gerät | tg64 | Werkzeug |
|---|---|---|---|---|
| **Erste Wahl** | Qwen3-4B-2507 Q4_K_M | P1000 | 19.3 | **10/10** |
| Schnellste | Llama-3.2-3B Q4_K_M | P1000 | 24.1 | 9/10 |
| Ohne GPU | BitNet-b1.58-2B-4T | CPU (gepinnte Engine) | 22.4 | 9/10 |
| Nicht empfohlen | Gemma-3-4B | — | 19.3 | 8/10, greift still zum falschen Werkzeug |

Phi-4-mini hat zwar auch 10/10, patzte aber inhaltlich (ZURICH-Stichprobe) —
zweite Wahl hinter Qwen3. Die 7B-Coder-Modelle aus dem März
(qwen2.5-coder:7b) passen nicht komplett in die 4 GB VRAM; der damalige
CPU/GPU-Split brachte ~10–15 tok/s, also weniger als Qwen3-4B ganz auf der
GPU — bei einer inzwischen zwei Generationen älteren Modellfamilie.

## Server starten

```bash
./setup/serve-coding-agent.sh            # Qwen3-4B auf der P1000, Port 8080
./setup/serve-coding-agent.sh llama gpu  # schnellste Variante
./setup/serve-coding-agent.sh qwen3 cpu  # ohne GPU (9.9 tok/s)
```

Das Skript prüft Engine und Modell, startet `llama-server` mit den
vermessenen Einstellungen (`--jinja`, `-ngl 99` bzw. CPU-Threads aus den
Benches) und wartet, bis der Endpunkt antwortet.

## Pi-Agent anbinden

In `~/.pi/agent/models.json` (oder projektlokal `.pi/models.json`) einen
Provider ergänzen; danach `/reload` im Pi-Agenten:

```json
{
  "providers": {
    "llamacpp-lokal": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "unbenutzt",
      "models": [
        {
          "id": "qwen3-4b-lokal",
          "name": "Qwen3-4B (llama-server, P1000)",
          "reasoning": false,
          "input": ["text"],
          "contextWindow": 8192,
          "maxTokens": 4096,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "toolSupport": { "local": true, "remote": true, "builtIn": false, "parallel": false }
        }
      ]
    }
  }
}
```

```bash
pi --provider llamacpp-lokal --model qwen3-4b-lokal --tools bash "Wie viel RAM habe ich?"
```

`llama-server` übersetzt mit `--jinja` die OpenAI-Tool-Calls in Qwen3s
natives Tool-Template — das ist derselbe Mechanismus, den `agent_eval.py`
indirekt mitgeprüft hat, nur dass der Agent die Werkzeuge stellt.

## Erwartungshaltung

19 tok/s Generierung heisst: ein typischer Agentenschritt (Antwort mit
Tool-Call, ~100–300 Token) dauert 5–15 s, plus Prompt-Verarbeitung bei
wachsender Historie (96 tok/s auf der P1000). Für kurze, klar umrissene
Aufgaben brauchbar; für lange Refactorings wird die Prompt-Verarbeitung der
Engpass, weil der Agentenkontext mit jedem Schritt wächst. Das ist die
messbare Grenze lokaler Coding-Agenten auf dieser Hardwareklasse — nicht die
Werkzeugwahl, die kann Qwen3-4B fehlerfrei.
