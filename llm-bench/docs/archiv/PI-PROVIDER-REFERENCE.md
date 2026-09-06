# Pi-Agent Provider - Quick Reference

## 🚀 Schnellstart

### Groq Cloud (Empfohlen - Tool-Calling ✅)
```bash
# API Key setzen (einmalig)
export GROQ_API_KEY=gsk_xxxxx

# Pi-Agent mit Tool-Calling
pi --provider groq --model qwen-2.5-coder-32b --tools bash "Wie viel RAM habe ich?"
```

**Vorteile:**
- ✅ Tool-Calling funktioniert perfekt
- ✅ Extrem schnell (~500 tokens/s)
- ✅ Kostenlos (30 Req/min, 200/Tag)
- ❌ Internet erforderlich

---

### KoboldCpp (Lokal, CPU+GPU Hybrid)
```bash
# KoboldCpp starten
~/.local/koboldcpp/start.sh

# In neuem Terminal: Pi-Agent verbinden
pi --provider koboldcpp --model qwen2.5-coder-7b --tools bash "Wie viel RAM habe ich?"
```

**Vorteile:**
- ✅ Lokal, keine Internet-Verbindung
- ✅ Nutzt deine Quadro P1000 (4GB VRAM)
- ✅ Tool-Calling möglich
- ❌ Langsamer (~8-15 tokens/s)
- ❌ 4GB RAM für Modell erforderlich

---

### LM Studio (Lokal, GUI)
```bash
# 1. LM Studio starten (https://lmstudio.ai)
# 2. Modell laden: Qwen2.5-Coder-7B-Instruct-GGUF
# 3. Local Server starten (Port 1234)

# Pi-Agent verbinden
pi --provider lmstudio --model qwen2.5-coder-7b --tools bash "Wie viel RAM habe ich?"
```

**Vorteile:**
- ✅ Einfache GUI
- ✅ Tool-Calling unterstützt
- ✅ GPU-Offload einstellbar
- ❌ Closed Source

---

### Ollama (Lokal, kein Tool-Calling)
```bash
# Ohne Tools - Modell gibt Befehl im Chat aus
pi --provider ollama --model qwen2.5-coder:3b "Gib mir den Befehl für free -h"

# Ergebnis mit !! ausführen
!! free -h
```

**Vorteile:**
- ✅ Einfachste Installation
- ✅ Schnellste lokale Option
- ❌ Tool-Calling funktioniert NICHT (Ollama-Bug)

---

## 📊 Vergleich

| Provider | Tool-Calling | Speed | Hardware | Kosten |
|----------|--------------|-------|----------|--------|
| **Groq** | ✅ Perfekt | ~500 t/s | Cloud | Kostenlos |
| **KoboldCpp** | ✅ Funktioniert | ~10 t/s | CPU+GPU | Kostenlos |
| **LM Studio** | ✅ Funktioniert | ~15 t/s | CPU+GPU | Kostenlos |
| **Ollama** | ❌ Defekt | ~50 t/s | CPU | Kostenlos |

---

## 🔧 Provider wechseln

### Interaktiv mit Ctrl+L
```bash
pi
# Dann: Ctrl+L drücken, Provider auswählen
```

### Per CLI-Flag
```bash
pi --provider groq --model qwen-2.5-coder-32b
pi --provider koboldcpp --model qwen2.5-coder-7b
pi --provider lmstudio --model qwen2.5-coder-7b
pi --provider ollama --model qwen2.5-coder:3b
```

### Dauerhaft in settings.json
```json
{
  "defaultProvider": "groq",
  "defaultModel": "qwen-2.5-coder-32b"
}
```

---

## 🛠️ Troubleshooting

### Groq "Unauthorized"
```bash
# API Key prüfen
echo $GROQ_API_KEY

# Key neu setzen
export GROQ_API_KEY=gsk_xxxxx
```

### KoboldCpp "Connection refused"
```bash
# Prüfen ob KoboldCpp läuft
curl http://localhost:5001/api/v1/model

# KoboldCpp neu starten
~/.local/koboldcpp/start.sh
```

### LM Studio "Model not found"
```bash
# In LM Studio: Modell laden!
# Dann Server starten (Port 1234)
# Modell-ID in Pi-Agent muss übereinstimmen
```

### Ollama Tool-Calling defekt
```bash
# Ist ein Ollama-Bug, kein Pi-Problem!
# Workaround: Ohne --tools verwenden
pi --provider ollama --model qwen2.5-coder:3b "Gib mir bash Befehl für X"
```

---

## 📝 models.json Standorte

| Datei | Zweck |
|-------|-------|
| `~/.pi/agent/models.json` | Global (alle Projekte) |
| `.pi/models.json` | Projekt-lokal |

Nach Änderungen: `/reload` in Pi-Agent ausführen!

---

## 🔗 Links

- **Groq Console:** https://console.groq.com/keys
- **KoboldCpp:** https://github.com/LostRuins/koboldcpp
- **LM Studio:** https://lmstudio.ai
- **Qwen2.5-Coder GGUF:** https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF
- **Ollama Library:** https://ollama.com/library

---

## 💡 Tipps für Quadro P1000 (4GB VRAM)

### Optimale Einstellungen für KoboldCpp:
```bash
./koboldcpp \
    --model qwen2.5-coder-7b.Q4_K_M.gguf \
    --gpulayers 20 \
    --contextsize 8192 \
    --threads 8 \
    --usecublas
```

**Erklärung:**
- `--gpulayers 20`: ~2.5GB VRAM Nutzung
- `--contextsize 8192`: Ausreichend für Coding
- `--threads 8`: CPU-Threads für Rest des Modells
- `--usecublas`: NVIDIA CUDA-Beschleunigung

### Modell-Empfehlungen:
| Modell | Größe | VRAM | RAM | Speed |
|--------|-------|------|-----|-------|
| Qwen2.5-Coder-3B Q4 | 2.3GB | 2GB | 1GB | ~20 t/s |
| Qwen2.5-Coder-7B Q4 | 4.7GB | 2.5GB | 2.5GB | ~10 t/s |
| Qwen2.5-Coder-14B Q4 | 9.0GB | 0GB | 9GB | ~4 t/s |

Für deine Hardware: **7B Q4_K_M** ist der Sweet-Spot!
