# AGENTS.md

## Git Regeln

- **KEINE git-destructive Befehle ohne explizite Erlaubnis**: Kein `git push --force`, `git reset`, `git checkout`, `git restore`, `git clean` ohne vorher zu fragen.

## Build Commands

```bash
zig build run              # Run vulkan-ed
zig build run -- --headless  # Headless mode (screenshots via RPC port 9999)
zig build run -- --interactive  # Interactive mode (stdin/stdout command interface)
zig build -Doptimize=ReleaseSafe  # Release build
```

## Headless / Interactive Mode

### Interactive Mode (stdin/stdout)
```bash
# Start interactive mode
zig build run -- --interactive

# Commands (line-based):
open <path>           # Open file in new tab
close-tab <n>        # Close tab by index
switch-tab <n>        # Switch to tab by index
click <x> <y>         # Mouse click at coordinates
key <name> [ctrl]     # Send key (enter, backspace, k, etc.)
type <text>           # Type text
screenshot            # Screenshot -> ./tmp/vulkan-screenshot.ppm
split <h|v>           # Split horizontal/vertical
get-state            # Get app state as JSON
shutdown              # Exit

# Example:
echo -e "open ./README.md\nget-state\nshutdown" | zig build run -- --interactive
```

### Headless Screenshots
- Pfad: `./tmp/vulkan-screenshot.ppm`
- RPC: `echo '{"jsonrpc":"2.0","method":"screenshot","id":1}' | nc --send-only localhost 9999`