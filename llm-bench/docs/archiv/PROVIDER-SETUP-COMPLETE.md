# 🚀 Pi-Agent Provider - Komplette Einrichtung

## ✅ Eingerichtete Provider

| Provider | Typ | Tool-Calling | Status |
|----------|-----|--------------|--------|
| **Groq** | Cloud | ✅ Funktioniert | 🟢 Bereit |
| **KoboldCpp** | Lokal (CPU+GPU) | ⚠️ Getestet | 🟢 Bereit |
| **LM Studio** | Lokal (GUI) | ✅ Unterstützt | 🟡 Installation nötig |
| **Ollama** | Lokal | ❌ Defekt | 🔴 Kein Tool-Calling |

---

## 🔵 Groq Cloud (Empfohlen)

### ✅ Status
- **API Key:** Eingerichtet
- **Modelle:** qwen/qwen3-32b, llama-3.3-70b-versatile, llama-3.1-8b-instant
- **Tool-Calling:** Funktioniert perfekt ✅
- **Speed:** ~400-500 tokens/s
- **Kosten:** Kostenlos (30 Req/min, 200/Tag)

### Verwendung
```bash
# Direkt mit Tool-Calling
pi --provider groq --model qwen/qwen3-32b --tools bash "RAM: free -h"

# Interaktiv
pi --provider groq --model qwen/qwen3-32b --tools bash
```

### API Key
Der Key ist gespeichert in:
- `~/.bashrc`
- `~/.profile`
- `~/.zshrc`
- `~/.env`
- `~/.pi/agent/models.json`

---

## 🟡 KoboldCpp (Lokal, Offline)

### ✅ Status
- **Installation:** Abgeschlossen
- **Modell:** Qwen2.5-Coder-7B Q4_K_M (4.7GB) ✅
- **GPU Offload:** 20 Layer (Quadro P1000 4GB)
- **Server:** Läuft auf Port 5001
- **Speed:** ~10-15 tokens/s

### Starten
```bash
# Server starten
~/.local/koboldcpp/start.sh &

# Mit Pi-Agent verbinden
pi --provider koboldcpp --model qwen2.5-coder-7b --tools bash
```

### Pfade
- **Binary:** `~/.local/koboldcpp/koboldcpp`
- **Modell:** `~/.local/koboldcpp/models/qwen2.5-coder-7b.Q4_K_M.gguf`
- **Start-Skript:** `~/.local/koboldcpp/start.sh`

### Stoppen
```bash
pkill koboldcpp
```

---

## 🟢 LM Studio (Lokal, GUI)

### ⚠️ Status
- **Installation:** Manuell nötig
- **Modell:** Kann KoboldCpp-Modell verwenden
- **Tool-Calling:** Unterstützt ✅

### Installation
Siehe: `~/LMSTUDIO-INSTALL.md`

**Kurzanleitung:**
1. Download: https://lmstudio.ai/download
2. Installieren: `sudo apt install ./lmstudio-stable_latest.deb`
3. Starten: `lmstudio`
4. Modell laden: Qwen2.5-Coder-7B-Instruct-Q4_K_M
5. Local Server starten (Port 1234)
6. Verbinden: `pi --provider lmstudio --model qwen2.5-coder-7b --tools bash`

### Modell verlinken
```bash
mkdir -p ~/.cache/lmstudio/models/Qwen
ln -sf ~/.local/koboldcpp/models/qwen2.5-coder-7b.Q4_K_M.gguf \
    ~/.cache/lmstudio/models/Qwen/qwen2.5-coder-7b-instruct-q4_k_m.gguf
```

---

## 🔴 Ollama (Lokal)

### ⚠️ Status
- **Installation:** Vorhanden
- **Modell:** qwen2.5-coder:3b
- **Tool-Calling:** ❌ Defekt (Ollama-Bug #9632, #12557)

### Workaround (ohne Tools)
```bash
# Modell gibt Befehl im Chat aus
pi --provider ollama --model qwen2.5-coder:3b "Gib mir bash Befehl für free -h"

# Dann manuell ausführen mit !!
!! free -h
```

---

## 📊 Vergleich

| Kriterium | Groq | KoboldCpp | LM Studio | Ollama |
|-----------|------|-----------|-----------|--------|
| **Tool-Calling** | ✅ Perfekt | ⚠️ Begrenzt | ✅ Gut | ❌ Defekt |
| **Speed** | ~500 t/s | ~10 t/s | ~15 t/s | ~50 t/s |
| **Internet** | ✅ Erforderlich | ❌ Nicht nötig | ❌ Nicht nötig | ❌ Nicht nötig |
| **Hardware** | Cloud | CPU+GPU | CPU+GPU | CPU |
| **Kosten** | Kostenlos | Kostenlos | Kostenlos | Kostenlos |
| **Setup** | ✅ Einfach | ✅ Mittel | ⚠️ Mittel | ✅ Einfach |

---

## 🎯 Empfehlungen

### Für Entwicklung (Empfohlen)
```bash
pi --provider groq --model qwen/qwen3-32b --tools bash
```
- ✅ Tool-Calling funktioniert
- ✅ Sehr schnell
- ✅ Bestes Modell (32B)

### Für Offline-Nutzung
```bash
# KoboldCpp starten
~/.local/koboldcpp/start.sh &

# Pi-Agent verbinden
pi --provider koboldcpp --model qwen2.5-coder-7b --tools bash
```
- ✅ Keine Internet-Verbindung nötig
- ✅ Daten bleiben lokal
- ⚠️ Langsamer (~10 t/s)

### Für GUI-Fans
```bash
# 1. LM Studio installieren (siehe LMSTUDIO-INSTALL.md)
# 2. Server starten (Port 1234)
# 3. Pi-Agent verbinden
pi --provider lmstudio --model qwen2.5-coder-7b --tools bash
```
- ✅ Einfache Bedienung
- ✅ Visuelles Feedback
- ⚠️ Installation nötig

---

## 🔧 Quick Commands

### Provider wechseln
```bash
# Interaktiv mit Ctrl+L
pi
# Dann: Ctrl+L drücken, Provider auswählen

# Per CLI
pi --provider groq --model qwen/qwen3-32b
pi --provider koboldcpp --model qwen2.5-coder-7b
pi --provider lmstudio --model qwen2.5-coder-7b
pi --provider ollama --model qwen2.5-coder:3b
```

### Server Status prüfen
```bash
# Groq
curl -s "https://api.groq.com/openai/v1/models" -H "Authorization: Bearer $GROQ_API_KEY" | jq

# KoboldCpp
curl -s http://localhost:5001/api/v1/model | jq

# LM Studio
curl -s http://localhost:1234/v1/models | jq

# Ollama
ollama list
```

### Logs einsehen
```bash
# KoboldCpp
tail -f /tmp/koboldcpp.log

# Pi-Agent (in tmux)
tmux attach -t pi-test
```

---

## 📁 Wichtige Dateien

| Datei | Zweck |
|-------|-------|
| `~/.pi/agent/models.json` | Provider-Konfiguration |
| `~/.pi/agent/auth.json` | API Keys (wird von Pi-Agent ignoriert!) |
| `~/.bashrc` | Umgebungsvariablen (GROQ_API_KEY) |
| `~/.local/koboldcpp/` | KoboldCpp Installation |
| `~/LMSTUDIO-INSTALL.md` | LM Studio Anleitung |
| `~/setup-pi-providers.sh` | Setup-Skript |
| `~/PI-PROVIDER-REFERENCE.md` | Detaillierte Referenz |

---

## 🐛 Troubleshooting

### Groq "401 Invalid API Key"
```bash
# Key in models.json prüfen
cat ~/.pi/agent/models.json | grep -A2 '"groq"'

# Key in .bashrc neu setzen
source ~/.bashrc
echo $GROQ_API_KEY
```

### KoboldCpp "Connection refused"
```bash
# Server starten
~/.local/koboldcpp/start.sh &

# Status prüfen
curl http://localhost:5001/api/v1/model
```

### LM Studio "Model not found"
```bash
# In LM Studio: Modell laden!
# Server auf Port 1234 starten
# Modell-ID in Pi-Agent muss übereinstimmen
```

### Ollama Tool-Calling defekt
```bash
# Ist ein Ollama-Bug, kein Pi-Problem!
# Workaround: Ohne --tools verwenden
pi --provider ollama --model qwen2.5-coder:3b "Gib mir bash Befehl für X"
```

---

## 🔗 Links

- **Groq Console:** https://console.groq.com/keys
- **KoboldCpp:** https://github.com/LostRuins/koboldcpp
- **LM Studio:** https://lmstudio.ai
- **Qwen2.5-Coder GGUF:** https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF
- **Ollama Library:** https://ollama.com/library
- **Pi-Agent Docs:** https://pi.dev/docs

---

## 💡 Tipps für Quadro P1000 (4GB VRAM)

### Optimale KoboldCpp Einstellungen:
```bash
./koboldcpp \
    --model models/qwen2.5-coder-7b.Q4_K_M.gguf \
    --gpulayers 20 \
    --contextsize 8192 \
    --port 5001 \
    --threads 8 \
    --smartcontext \
    --usecublas
```

**Erklärung:**
- `--gpulayers 20`: ~2.5GB VRAM Nutzung
- `--contextsize 8192`: Ausreichend für Coding
- `--threads 8`: CPU-Threads für Rest des Modells
- `--usecublas`: NVIDIA CUDA-Beschleunigung

---

**Letzte Aktualisierung:** 14. März 2026
