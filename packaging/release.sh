#!/usr/bin/env bash
# Neue Version veröffentlichen, ein Befehl:
#
#   packaging/release.sh 0.1.2 "Search and replace across the project (Ctrl+Shift+F)."
#
# Setzt die Version überall (build.zig.zon, AppStream, RPM-Spec, README), committet,
# taggt v<version> und pusht. Den Rest macht .github/workflows/release.yml: Tarball,
# .deb, .rpm, Snap und Windows-Zip bauen, Release anlegen, COPR und Snap Store
# anstossen. Scoop zieht über den Excavator im Bucket nach (alle 4 h).
#
# Mehrere Punkte im Text: mit " | " trennen, jeder wird ein eigener Absatz.
# --dry-run ändert nur die Dateien, ohne Commit, Tag und Push.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

dry=no
if [ "${1:-}" = "--dry-run" ]; then dry=yes; shift; fi
new="${1:-}"
notes="${2:-}"
if ! [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ -z "$notes" ]; then
    echo "Aufruf: packaging/release.sh [--dry-run] <x.y.z> \"Was ist neu (englisch, für AppStream)\"" >&2
    exit 2
fi

old="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)"
[ "$old" != "$new" ] || { echo "Version $new ist schon gesetzt." >&2; exit 1; }
# Vergleich in Python statt `sort -V`: unter Windows darf Git-Bash sort.exe nicht starten
if ! python3 -c 'import sys; v = lambda s: tuple(map(int, s.split("."))); sys.exit(v(sys.argv[2]) <= v(sys.argv[1]))' "$old" "$new"; then
    echo "$new ist nicht neuer als $old." >&2
    exit 1
fi

if [ "$dry" = no ]; then
    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$branch" = main ] || { echo "Nur von main aus (jetzt: $branch)." >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "Arbeitsbaum nicht sauber." >&2; exit 1; }
    git fetch -q origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || {
        echo "main weicht von origin/main ab, erst pullen bzw. pushen." >&2
        exit 1
    }
    if git rev-parse -q --verify "refs/tags/v$new" >/dev/null; then
        echo "Tag v$new gibt es schon." >&2
        exit 1
    fi
fi

OLD="$old" NEW="$new" NOTES="$notes" AUTHOR="$(git config user.name) <$(git config user.email)>" python3 - <<'PY'
import datetime, os, re
from xml.sax.saxutils import escape

old, new, author = os.environ["OLD"], os.environ["NEW"], os.environ["AUTHOR"]
notes = [n.strip() for n in os.environ["NOTES"].split("|") if n.strip()]
today = datetime.date.today()


def edit(path, fn):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    changed = fn(text)
    if changed == text:
        raise SystemExit(f"{path}: nichts geändert, Muster passt nicht")
    with open(path, "w", encoding="utf-8") as f:
        f.write(changed)


def sub1(pattern, repl, text):
    out, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n != 1:
        raise SystemExit(f"Muster nicht gefunden: {pattern}")
    return out


# build.zig.zon: Quelle der Version im Binary (zid --version)
edit("build.zig.zon", lambda t: sub1(rf'\.version = "{re.escape(old)}"', f'.version = "{new}"', t))

# AppStream: neuer <release>-Eintrag oben
paras = "".join(f"        <p>{escape(n)}</p>\n" for n in notes)
release = f'    <release version="{new}" date="{today.isoformat()}">\n      <description>\n{paras}      </description>\n    </release>\n'
edit("packaging/io.github.gstrainovic.zid.metainfo.xml", lambda t: sub1(r"^  <releases>\n", lambda m: m.group(0) + release, t))

# RPM-Spec: Version, Release zurück auf 1, Changelog-Eintrag oben
# Englische Namen unabhängig von der Locale, wie rpm sie im %changelog verlangt
days =["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
stamp = f"{days[today.weekday()]} {months[today.month - 1]} {today.day:02d} {today.year}"
entry = f"* {stamp} {author} - {new}-1\n" + "".join(f"- {n}\n" for n in notes) + "\n"


def spec(t):
    t = sub1(rf"^(Version:\s*){re.escape(old)}$", lambda m: m.group(1) + new, t)
    t = sub1(r"^(Release:\s*)\d+(%\{\?dist\})$", lambda m: m.group(1) + "1" + m.group(2), t)
    return sub1(r"^%changelog\n", lambda m: m.group(0) + entry, t)


edit("packaging/rpm/zid.spec", spec)

# README: Dateinamen und Beispiele
edit("README.md", lambda t: t.replace(f"zid-{old}-", f"zid-{new}-").replace(f"zid_{old}-", f"zid_{new}-").replace(f"v{old}", f"v{new}").replace(f"zid {old}", f"zid {new}"))
PY

if [ "$dry" = yes ]; then
    echo "== Nur Dateien geändert (--dry-run), kein Commit, kein Tag, kein Push."
    exit 0
fi

msg="release: zid $new"$'\n'
IFS='|' read -ra parts <<<"$notes"
for p in "${parts[@]}"; do msg+=$'\n'"- $(echo "$p" | sed 's/^ *//; s/ *$//')"; done
git add -A build.zig.zon packaging README.md
git commit -q -m "$msg"
git tag -a "v$new" -m "zid $new"
git push -q origin main "v$new"

echo "== v$new gepusht. Fortschritt:"
echo "   gh run watch \$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
