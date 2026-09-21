#!/usr/bin/env bash
# Installiert zid aus diesem Archiv. Ohne Argument nach ~/.local, sonst nach $1.
# Deinstallieren: ./install.sh --uninstall [prefix]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uninstall=no
if [ "${1:-}" = "--uninstall" ]; then
    uninstall=yes
    shift
fi
prefix="${1:-$HOME/.local}"

app_id="io.github.gstrainovic.zid"
files=(
    "bin/zid"
    "libexec/zid/rg"
    "libexec/zid/ripgrep-LICENSE-MIT"
    "share/applications/$app_id.desktop"
    "share/icons/hicolor/scalable/apps/$app_id.svg"
    "share/metainfo/$app_id.metainfo.xml"
)

refresh_caches() {
    # Fehlt eines der Werkzeuge, ist das kein Fehler: der Eintrag erscheint dann
    # spätestens nach der nächsten Anmeldung.
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 &&
        gtk-update-icon-cache -qtf "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true
}

if [ "$uninstall" = yes ]; then
    for f in "${files[@]}"; do
        rm -f "$prefix/$f"
    done
    rmdir "$prefix/libexec/zid" 2>/dev/null || true
    refresh_caches
    echo "zid aus $prefix entfernt."
    exit 0
fi

for f in "${files[@]}"; do
    mode=644
    case "$f" in bin/* | */rg) mode=755 ;; esac
    install -Dm "$mode" "$here/$f" "$prefix/$f"
done
refresh_caches

echo "zid nach $prefix installiert."
if ! command -v zid >/dev/null 2>&1; then
    echo "Hinweis: $prefix/bin liegt nicht im PATH. Ergänze in ~/.bashrc:"
    echo "    export PATH=\"$prefix/bin:\$PATH\""
fi
