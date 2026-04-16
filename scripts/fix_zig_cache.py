#!/usr/bin/env python3
"""
Prefill Zig package cache with symlink-free extractions.

Windows-Nutzer ohne Admin/Developer-Mode koennen keine Symlinks anlegen.
Tree-sitter Grammar-Tarballs enthalten Symlinks zum Teilen von Query-Dateien.
Dieses Skript extrahiert solche Tarballs und ersetzt Symlinks durch Kopien.

Usage:
    python scripts/fix_zig_cache.py add <cache-folder-name> <tarball-url>
    python scripts/fix_zig_cache.py scan <path-to-build.zig.zon>

Cache-Folder: siehe Zig-Fehler, Format "<name>-<version>-<hash>".
"""
from __future__ import annotations

import io
import os
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path


def cache_root() -> Path:
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        raise SystemExit("LOCALAPPDATA env var not set - are you on Windows?")
    root = Path(local) / "zig" / "p"
    root.mkdir(parents=True, exist_ok=True)
    return root


def lp(p: Path) -> str:
    """Windows long-path workaround: prefix absolute NT paths with \\\\?\\.

    Bypasses MAX_PATH=260 limit without requiring LongPathsEnabled registry.
    """
    if os.name != "nt":
        return str(p)
    s = str(p.resolve())
    if s.startswith("\\\\?\\"):
        return s
    # UNC paths need \\?\UNC\server\... instead of \\?\\\server\...
    if s.startswith("\\\\"):
        return "\\\\?\\UNC\\" + s.lstrip("\\")
    return "\\\\?\\" + s


def download(url: str) -> bytes:
    print(f"  download {url}")
    with urllib.request.urlopen(url) as r:
        return r.read()


def extract_resolving_symlinks(tar_bytes: bytes, dest: Path) -> int:
    """Extract tarball to dest. Replace symlinks with copies of target file content.

    Returns count of symlinks resolved.
    """
    os.makedirs(lp(dest), exist_ok=True)
    resolved = 0

    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:*") as tf:
        members = tf.getmembers()

        # Strip single top-level component if uniform (common for source tarballs)
        top_levels = {m.name.split("/", 1)[0] for m in members if m.name}
        strip_prefix = None
        if len(top_levels) == 1:
            prefix = next(iter(top_levels)) + "/"
            if all(m.name == prefix[:-1] or m.name.startswith(prefix) for m in members):
                strip_prefix = prefix

        def rel_name(name: str) -> str:
            if strip_prefix and name.startswith(strip_prefix):
                return name[len(strip_prefix):]
            if strip_prefix and name == strip_prefix[:-1]:
                return ""
            return name

        # Pass 1: regular files and dirs
        symlinks: list[tarfile.TarInfo] = []
        for m in members:
            rn = rel_name(m.name)
            if not rn:
                continue
            target = dest / rn
            if m.issym() or m.islnk():
                symlinks.append(m)
                continue
            if m.isdir():
                os.makedirs(lp(target), exist_ok=True)
            elif m.isfile():
                os.makedirs(lp(target.parent), exist_ok=True)
                src = tf.extractfile(m)
                if src is None:
                    continue
                with open(lp(target), "wb") as out:
                    shutil.copyfileobj(src, out)

        # Pass 2: resolve symlinks + hardlinks by copying their real target content
        for m in symlinks:
            rn = rel_name(m.name)
            if not rn:
                continue
            link_file = dest / rn

            # Compute the target path: symlinks are typically relative to the
            # directory containing the link.
            link_target = m.linkname
            if m.issym():
                resolved_path = (link_file.parent / link_target).resolve()
            else:  # hardlink
                # Hardlink target is given relative to the archive root.
                hl_rel = rel_name(link_target) if strip_prefix and link_target.startswith(strip_prefix) else link_target
                resolved_path = (dest / hl_rel).resolve()

            # Security: must stay within dest
            try:
                resolved_path.relative_to(dest.resolve())
            except ValueError:
                print(f"  WARN: symlink escapes dest, skipping: {rn} -> {link_target}")
                continue

            os.makedirs(lp(link_file.parent), exist_ok=True)

            resolved_lp = lp(resolved_path)
            link_lp = lp(link_file)

            if os.path.isdir(resolved_lp):
                if os.path.exists(link_lp):
                    shutil.rmtree(link_lp)
                # Manual copytree that tolerates long paths
                for root, dirs, files in os.walk(resolved_lp):
                    rel = os.path.relpath(root, resolved_lp)
                    dst_root = os.path.join(link_lp, rel) if rel != "." else link_lp
                    os.makedirs(dst_root, exist_ok=True)
                    for f in files:
                        shutil.copy2(os.path.join(root, f), os.path.join(dst_root, f))
            elif os.path.isfile(resolved_lp):
                if os.path.exists(link_lp):
                    os.remove(link_lp)
                shutil.copy2(resolved_lp, link_lp)
            else:
                print(f"  WARN: symlink target missing: {rn} -> {link_target}")
                continue
            resolved += 1

    return resolved


def cmd_add(folder_name: str, url: str) -> None:
    target = cache_root() / folder_name
    if target.exists():
        print(f"[skip] already exists: {target}")
        return

    print(f"[fetch] {folder_name}")
    data = download(url)

    # Extract to a temp dir first, then atomic rename (so a failed extraction
    # does not leave a half-populated "valid" cache folder).
    tmpdir = Path(tempfile.mkdtemp(dir=cache_root()))
    try:
        staging = tmpdir / folder_name
        n = extract_resolving_symlinks(data, staging)
        print(f"  resolved {n} symlink(s)")
        os.rename(lp(staging), lp(target))
    finally:
        if tmpdir.exists():
            # rmtree with onerror handler that widens deletion rights
            def _force_rm(func, path, _exc):
                try:
                    os.chmod(path, 0o700)
                    func(path)
                except OSError:
                    pass
            shutil.rmtree(lp(tmpdir), onerror=_force_rm)

    print(f"[done]  {target}")


ZON_DEP_RE = re.compile(
    r'\.(?P<name>\w+)\s*=\s*\.\{\s*'
    r'\.url\s*=\s*"(?P<url>[^"]+)"\s*,\s*'
    r'\.hash\s*=\s*"(?P<hash>[^"]+)"',
    re.DOTALL,
)


def cmd_scan(zon_path: str) -> None:
    text = Path(zon_path).read_text(encoding="utf-8")
    hits = list(ZON_DEP_RE.finditer(text))
    if not hits:
        print("No .url/.hash pairs found")
        return
    print(f"Found {len(hits)} dependency entries:")
    for m in hits:
        print(f"  name={m['name']}")
        print(f"    url={m['url']}")
        print(f"    hash={m['hash']}")


def main(argv: list[str]) -> int:
    import subprocess
    print("Building vulkan-ed...")
    subprocess.run(["zig", "build"])

    if len(argv) < 2:
        print(__doc__)
        return 1

    cmd = argv[1]
    if cmd == "add" and len(argv) == 4:
        cmd_add(argv[2], argv[3])
    elif cmd == "scan" and len(argv) == 3:
        cmd_scan(argv[2])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
