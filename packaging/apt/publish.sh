#!/usr/bin/env bash
# apt-Quelle aktualisieren: legt .deb-Pakete in einen Checkout von gstrainovic/apt-zid
# (GitHub Pages) und baut Index und Signatur neu.
#
#   packaging/apt/publish.sh <checkout> <paket.deb>...
#
# Braucht apt-ftparchive (apt-utils) und genau einen geheimen Schlüssel im gpg-Schlüsselbund.
# Aufgerufen von .github/workflows/apt.yml; committen und pushen tut der Workflow.
set -euo pipefail

site="$1"
shift
keep=3 # so viele Versionen bleiben im Pool, ältere fliegen raus (Pages-Grenze 1 GB)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pool="$site/pool/main/z/zid"
mkdir -p "$pool"
cp "$@" "$pool/"
# shellcheck disable=SC2012 # Dateinamen ohne Leerzeichen, sort -V braucht die Liste
ls "$pool"/zid_*_amd64.deb | sort -V | head -n -"$keep" | xargs -r rm -f

cd "$site"
rm -rf dists
dist=dists/stable
mkdir -p "$dist/main/binary-amd64"
apt-ftparchive packages pool >"$dist/main/binary-amd64/Packages"
gzip -9kn "$dist/main/binary-amd64/Packages"
# Release erst ausserhalb schreiben: apt-ftparchive läse sonst die halbe Datei mit ein
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=zid \
    -o APT::FTPArchive::Release::Label=zid \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    -o APT::FTPArchive::Release::Components=main \
    -o "APT::FTPArchive::Release::Description=zid editor" \
    release "$dist" >"${TMPDIR:-/tmp}/Release"
mv "${TMPDIR:-/tmp}/Release" "$dist/Release"
gpg --batch --yes --clearsign -o "$dist/InRelease" "$dist/Release"
gpg --batch --yes --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"

# Öffentlicher Schlüssel für signed-by, binär (zid.gpg) und als Text (zid.asc)
gpg --batch --yes --export -o zid.gpg
gpg --batch --yes --armor --export -o zid.asc
cp "$here/index.html" index.html
touch .nojekyll

echo "== apt-Quelle:"
grep -E '^(Package|Version):' "$dist/main/binary-amd64/Packages"
