# KI-Modelle für 4GB VRAM GPUs (Update 2026 - Gemma 4 Fokus)

Du hast völlig recht, da war ich in meiner vorherigen Antwort nicht präzise genug, als ich Gemma 3 und 4 in einen Topf geworfen habe. **Gemma 4 ist der klare Nachfolger und deutlich überlegen.**

Hier ist die detaillierte Erklärung, warum **Gemma 4** aktuell die absolute Spitzenempfehlung für deinen Editor mit 4GB VRAM ist:

## Warum Gemma 4 (E2B / E4B) besser ist als Gemma 3
Google hat im Frühjahr 2026 die Gemma 4-Familie veröffentlicht, die speziell für lokale, "agentische" (selbstständig handelnde) Workflows und Edge-Geräte gebaut wurde.

1. **Per-Layer Embeddings (PLE):** Die kleinen Gemma 4 Modelle (E2B und E4B, wobei das "E" für *Effective* steht) nutzen eine neue Architektur. Sie haben einen gigantischen Wissensschatz (durch ein riesiges Embedding-Vokabular), müssen aber während der Berechnung (Inferenz) viel weniger Parameter aktiv halten.
2. **Native Agenten-Fähigkeiten:** Gemma 4 wurde von Grund auf darauf trainiert, Werkzeuge aufzurufen (Function Calling) und JSON auszugeben. Wenn du in deinem Editor eine KI willst, die nicht nur Code schreibt, sondern auch Editor-Befehle ausführt (z.B. "öffne Datei X", "suche nach Y"), ist Gemma 4 unschlagbar.
3. **Multimodal (inklusive Audio):** Gemma 4 E4B kann nicht nur Bilder und Text verarbeiten, sondern versteht nativ Audio. Du könntest deinem Editor also theoretisch eine Voice-Coding-Funktion verpassen.

## Das perfekte Gemma 4 Modell für deine 4GB VRAM
Wie besprochen, fällt das große "Gemma 4 26B" (ca. 17 GB VRAM) für dich flach. Aber die kleinen Versionen sind perfekt:

### **Der Champion: Gemma 4 E4B (GGUF 4-bit)**
- **VRAM-Bedarf:** ca. **2.5 GB bis 2.8 GB** (als Q4_K_M GGUF)
- **Kontext:** 128K Token Context Window
- **Warum es ideal ist:** Es lastet deine 4GB VRAM optimal aus. Es lässt ca. 1.2 GB für deinen Editor (`vulkan-ed` über wgpu), das Betriebssystem und den Kontextspeicher (KV Cache) der KI übrig. Du bekommst die Intelligenz eines viel größeren Modells bei rasanter Geschwindigkeit direkt auf der GPU.

### **Die Ultra-Fast Alternative: Gemma 4 E2B (GGUF 4-bit)**
- **VRAM-Bedarf:** ca. **1.5 GB**
- **Warum es ideal ist:** Wenn du extrem aggressive Autocomplete-Vorschläge beim Tippen (in Echtzeit) haben willst, ist das E2B Modell noch einen Tick schneller und lässt massig VRAM für andere Anwendungen frei.

---

# Architektur-Plan: Gemma 4 Agent in vulkan-ed

Das Ziel ist es, **Gemma 4 E4B (GGUF 4-bit)** als intelligenten, selbstständig handelnden Agenten direkt in den Zig-Editor (`vulkan-ed`) zu integrieren. Da wir ein hartes Limit von **4GB VRAM** haben, nutzen wir die GPU (Vulkan) für maximale Geschwindigkeit.

## 1. Die benötigten Komponenten
*   **Das Modell:** `gemma-4-e4b-instruct-Q4_K_M.gguf` (ca. 2.5 GB bis 2.8 GB). Dieses Modell bietet native Agenten-Fähigkeiten (Function Calling) und passt perfekt in den VRAM.
*   **Die Inference-Engine:** `llama.cpp` (kompiliert mit Vulkan-Support). Das ist der absolute Goldstandard für GGUF-Modelle.
*   **Der Editor (vulkan-ed):** Unser in Zig geschriebener Editor, der bereits Vulkan/wgpu für das Rendering nutzt.

## 2. Die Schnittstelle: Editor <-> llama.cpp
Wie kommuniziert der Zig-Editor mit dem KI-Modell? Hier gibt es zwei Wege:

### Option A: Native C-Bindings (Empfohlen für maximale Performance)
Zig ist fantastisch darin, C-Code direkt einzubinden. Wir kompilieren `llama.cpp` als statische Bibliothek (`.a` oder `.lib`) direkt über unsere `build.zig` mit.
*   **Wie es funktioniert:** `@cImport({ @cInclude("llama.h"); });`
*   **Vorteile:** Null Overhead. Der Speicher (RAM/VRAM) wird direkt geteilt. Extrem geringe Latenz für Echtzeit-Autocomplete (Fill-in-the-Middle).

### Option B: Local HTTP-Server (Der einfachste Start)
`llama.cpp` bringt ein Tool namens `llama-server` mit. Dieses startet einen lokalen Webserver, der die exakte API von OpenAI (z.B. `/v1/chat/completions`) nachbaut.
*   **Wie es funktioniert:** Der Editor startet den `llama-server` als Hintergrundprozess. Zig kommuniziert dann über simple HTTP-Requests (z.B. mit `std.http.Client`) mit dem Modell.
*   **Vorteile:** Super simpel zu implementieren. Abstürze der KI reißen den Editor nicht mit (Speicherschutz). Ideal für Agenten-Workflows, da die OpenAI-API Tool-Calling nativ unterstützt.

**Empfehlung:** Starte mit **Option B (`llama-server` im Hintergrund)**. Wenn der Agent funktioniert, wechsle auf **Option A (Native C-Bindings)**.

## 3. Architektur des Agenten im Editor
### A. Der KI-Thread
Die Textgenerierung darf niemals den Main-Thread (wo Clay das UI zeichnet) blockieren. Die KI läuft in einem eigenen `std.Thread`. Ergebnisse werden über eine Thread-sichere Queue an den UI-Thread geschickt.

### B. Function Calling (Die Werkzeuge des Agenten)
Damit Gemma 4 als Agent agieren kann, muss der Editor dem Modell eine Liste an "Tools" im JSON-Format übergeben.
*   `read_file(path)`: Der Agent liest eine Datei in seinen Kontext.
*   `replace_text(path, old, new)`: Der Agent ändert Code im Editor.
*   `run_tests()`: Der Agent triggert den Zig-Compiler und liest den Output.

### C. VRAM Management (Der 4GB Limit-Trick)
*   Lade das Modell mit dem Flag `--n-gpu-layers 99` um **alle** Schichten in den VRAM zu zwingen.
*   Begrenze den **Kontext-Cache (KV Cache)** auf z.B. `8192` oder `16384` Token.

---

# Entwicklungs-Strategie: Welches Gemini-Modell für die Umsetzung?

Wenn du mich (die Gemini CLI) oder die API nutzt, um **diesen Code für den Editor in Zig zu schreiben**, stellt sich die Frage: Welches Gemini-Modell ist am besten geeignet?

### 1. Gemini 1.5 Pro (oder Gemini 2.0 Pro) - **Für die Architektur & Komplexe Features**
*   **Wann nutzen:** Wenn wir die C-Bindings (`llama.h`) in die `build.zig` integrieren, komplexe Threading-Probleme in Zig lösen oder den Agenten-Loop (Function Calling JSON Parser) bauen.
*   **Warum:** Das Pro-Modell hat das tiefste Verständnis für komplexe Codebasen, kann hunderte Dateien im Kontext halten und macht bei schwerem C/Zig-Interop die wenigsten Fehler. Es "denkt" weiter voraus.

### 2. Gemini 1.5 Flash (oder 2.0 Flash) - **Für UI & Iteratives Arbeiten**
*   **Wann nutzen:** Wenn wir das Clay-UI für das Chat-Fenster bauen, einfache HTTP-Requests in Zig implementieren oder schnelle Bugfixes machen.
*   **Warum:** Flash ist rasend schnell. Es ist perfekt, um iterativ UI-Elemente zu verschieben ("Mach den Button grüner", "Scrollbar fehlt") ohne lange Wartezeiten.

### 3. Gemini Flash-Lite (8B) - **Nicht für diese Aufgabe empfohlen**
*   **Wann nutzen:** Für simple Textaufgaben oder sehr isolierte, kleine Skripte.
*   **Warum:** Für tiefes Zig-Wissen (was eine relativ seltene Sprache im Vergleich zu Python/JS ist) und C-Interop mit `llama.cpp` reicht die "Intelligenz" des Lite-Modells oft nicht aus. Es würde zu viele Kompilierfehler produzieren.

**Mein Vorschlag für unsere Zusammenarbeit:**
Lass uns für den schweren Teil der Integration (Subprozess starten, HTTP-Client in Zig schreiben, JSON parsen) **Gemini Pro** nutzen. Für die reinen UI-Anpassungen im Editor können wir auf **Flash** wechseln, um Tempo zu machen.