# Handoff to Gemini Flash

## Aktueller Stand (Erledigt von Gemini Pro)
Die Architektur-Recherche und die technische Backend-Integration für den lokalen KI-Agenten wurden abgeschlossen.
*   **Strategie:** Wir integrieren **Gemma 4 E4B (GGUF 4-bit)** als lokalen Agenten, um das harte 4GB VRAM Limit zu respektieren und dennoch native Agenten-Fähigkeiten (Function Calling) zu haben. (Details in `ai.md`).
*   **Backend-Code:** Der Zig 0.15 Backend-Code wurde in `src/ai/agent.zig` geschrieben. Der `LlamaAgent` Struct startet einen lokalen `llama-server` als Subprozess (mit `-ngl 99` für die GPU) und stellt einen Thread-sicheren HTTP-Client (`sendChatCompletion`) bereit, um OpenAI-kompatible JSON-Requests zu senden. Der Code kompiliert fehlerfrei.

## Deine Aufgaben (Gemini Flash)
Du bist an der Reihe, das Frontend (UI) und die Lebenszyklus-Verwaltung in den Editor einzubauen.

1.  **Agenten-Instanz in `src/main.zig` oder `src/ui/mod.zig` integrieren:**
    *   Initialisiere `LlamaAgent` beim Start des Editors.
    *   Sorge dafür, dass `.deinit()` beim Schließen des Editors sauber aufgerufen wird, damit der Subprozess (`llama-server`) stirbt.
2.  **UI-Integration (Clay):**
    *   Baue ein Chat-Fenster oder ein Command-Input-Feld in das Editor-UI ein (vermutlich in `src/ui/mod.zig` oder einer neuen Komponente).
    *   Fange User-Input ab und sende ihn (in einem separaten Thread, damit das UI nicht einfriert!) via `llama.sendChatCompletion()` an das Modell.
    *   Zeige die Antwort im UI an.
3.  **Iteration:** Nutze deine Geschwindigkeit, um das Layout anzupassen (Farben, Padding, Scrollbars), bis sich der Chat natürlich in den Editor einfügt.

Wenn das UI steht und Text austauscht, können wir im nächsten Schritt dem System-Prompt die echten Editor-"Tools" (z.B. `replace_text`) als JSON beibringen!