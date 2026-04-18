# Headless Mode

Startet vulkan-ed ohne Fenster. Nützlich für Screenshots in CI oder Tests.

## Starten

```bash
./zig-out/bin/vulkan-ed --headless
```

RPC-Server läuft auf Port 9999 (rohes JSON über TCP, kein HTTP).

## Screenshot als PNG generieren

```bash
# 1. Screenshot auslösen → schreibt /tmp/vulkan-screenshot.ppm
echo '{"jsonrpc":"2.0","method":"screenshot","id":1}' | nc --send-only localhost 9999

# 2. PPM → PNG konvertieren
ffmpeg -f rawvideo -pixel_format rgb24 -video_size 1200x800 \
  -i /tmp/vulkan-screenshot.ppm screenshot.png -y
```

## Beenden

```bash
echo '{"jsonrpc":"2.0","method":"shutdown","id":2}' | nc --send-only localhost 9999
```

## Hinweise

- `--headless` impliziert `--e2e` (RPC-Server wird automatisch gestartet)
- Viewport ist fest 1200×800
- PPM-Format: RGB24 rawvideo, keine Kopfzeile für ffmpeg nötig (rawvideo überspringt sie)
- Zwischen Start und erstem Screenshot mind. 5 Sekunden warten (Vulkan-Init + Font-Rasterung)
