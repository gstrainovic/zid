# AGENTS.md

## Git Regeln

- **KEINE git-destructive Befehle ohne explizite Erlaubnis**: Kein `git push --force`, `git reset`, `git checkout`, `git restore`, `git clean` ohne vorher zu fragen.

## Build Commands

```bash
zig build run              # Run vulkan-ed
zig build run -- --headless  # Headless mode (screenshots via RPC port 9999)
zig build -Doptimize=ReleaseSafe  # Release build
```

## Headless Screenshots

- Pfad: `./tmp/vulkan-screenshot.ppm`
- RPC: `echo '{"jsonrpc":"2.0","method":"screenshot","id":1}' | nc --send-only localhost 9999`