#!/usr/bin/env bash
# pacman-Quelle aktualisieren: legt Arch-Pakete in einen Checkout von gstrainovic/pacman-zid
# (GitHub Pages), signiert sie und baut die Datenbank neu.
#
#   packaging/pacman/publish.sh <checkout> <paket.pkg.tar.zst>...
#
# Braucht repo-add (pacman) und genau einen geheimen Schlüssel im gpg-Schlüsselbund.
# Aufgerufen von .github/workflows/pacman.yml; committen und pushen tut der Workflow.
set -euo pipefail

site="$1"
shift
keep=3 # so viele Versionen bleiben liegen, ältere fliegen raus (Pages-Grenze 1 GB)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

repo="$site/x86_64"
mkdir -p "$repo"
cp "$@" "$repo/"
cd "$repo"
# shellcheck disable=SC2012 # Dateinamen ohne Leerzeichen, sort -V braucht die Liste
ls zid-*-x86_64.pkg.tar.zst | sort -V | head -n -"$keep" | xargs -r rm -f

# pacman verlangt signierte Pakete (SigLevel Required); jede Signatur neu, auch die alten
rm -f ./*.sig zid.db* zid.files*
for p in zid-*-x86_64.pkg.tar.zst; do
    gpg --batch --yes --detach-sign --no-armor -o "$p.sig" "$p"
done
repo-add --sign zid.db.tar.gz zid-*-x86_64.pkg.tar.zst
# repo-add legt zid.db als Symlink an; Pages liefert Symlinks nicht aus
for l in zid.db zid.db.sig zid.files zid.files.sig; do
    cp --remove-destination "$(readlink "$l")" "$l"
done

cd "$site"
gpg --batch --yes --armor --export -o zid.asc
cp "$here/index.html" index.html
touch .nojekyll

echo "== pacman-Quelle:"
ls -1 x86_64
