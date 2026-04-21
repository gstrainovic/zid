RPC & Automatisierung (.py)
   * scripts/rpc_client.py: Basis-Client für Kommunikation mit vulkan-ed über Sockets.
   * scripts/rpc_open.py: Nutzt RPC um Dateien in laufender Instanz zu öffnen.
   * scripts/simulate_typing.py: Sendet Tasteneingaben via RPC (gut für Demos/Tests).

  Screenshots (.sh & .ps1)
   ## Screenshots & Visual Debugging

### vscreenshot.py (AI Agent Visual Debugging)
```
python3 scripts/vscreenshot.py "Frage an Gemini"
python3 scripts/vscreenshot.py --interactive
```
RPC-basiert für headless vulkan-ed. Erstellt Screenshot, konvertiert PPM→PNG via ImageMagick, und fragt Gemini. Commands: `s <frage>` (Screenshot+Analyse), `r <method> [args]` (RPC call), `q` (Quit).

### Screenshots (.sh & .ps1)
* scripts/gui-screenshot.sh: Erstellt Screenshot vom GUI (Linux).

  Benchmarks & Sync (.sh & .zig)
   * scripts/benchmark-rpc.zig: Misst Performance der RPC Schnittstelle.
   * scripts/sync.sh: Synchronisiert Libs/Assets (wahrscheinlich für Dev-Setup).
   * scripts/review.sh: Hilfsscript für Code-Reviews (nutzt oft diff).

  Utility
   * scripts/fix_zig_cache.py: Repariert korrupte Zig Build Caches (bekanntes Problem bei manchen
     Versionen).
