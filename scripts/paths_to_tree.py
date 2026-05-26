#!/usr/bin/env python3
"""Build a box-drawing tree from a flat path list (one absolute path per line)."""

from __future__ import annotations

import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

TEE = "├── "
LAST = "└── "
PIPE = "│   "
SPACE = "    "


def rel_paths(paths: list[str], root: str) -> list[str]:
    root = root.rstrip("/")
    out = []
    for p in paths:
        p = p.strip()
        if not p:
            continue
        if p == root:
            out.append("")
            continue
        if p.startswith(root + "/"):
            out.append(p[len(root) + 1 :])
        else:
            out.append(p)
    return out


def insert(tree: dict, parts: list[str]) -> None:
    node = tree
    for part in parts:
        if part not in node:
            node[part] = {}
        node = node[part]


def render(tree: dict, prefix: str = "", is_last: bool = True, lines: list[str] | None = None) -> list[str]:
    if lines is None:
        lines = []
    keys = sorted(tree.keys(), key=lambda k: (0 if tree[k] else 1, k.lower()))
    for i, key in enumerate(keys):
        last = i == len(keys) - 1
        conn = LAST if last else TEE
        child = tree[key]
        label = f"{key}/" if child else key
        lines.append(prefix + conn + label)
        if child:
            child_prefix = prefix + (SPACE if last else PIPE)
            render(child, child_prefix, last, lines)
    return lines


def inventory(paths: list[str], root: str) -> list[str]:
    lines = ["", "=" * 70, "INVENTORY (every path on mount — no filtering)", "=" * 70, ""]
    rels = rel_paths(paths, root)
    lines.append(f"Total paths: {len(rels)}")
    lines.append("")

    # minecraftWorlds
    lines.append("--- All minecraftWorlds directories ---")
    for p in sorted(set(r for r in rels if r.endswith("minecraftWorlds") or "/minecraftWorlds" in r)):
        lines.append(f"  {p or '(root)'}/")
    lines.append("")

    lines.append("--- World folder entries (direct child of .../minecraftWorlds/) ---")
    world_dirs = set()
    for r in rels:
        if "/minecraftWorlds/" not in r:
            continue
        tail = r.split("/minecraftWorlds/", 1)[1]
        if not tail:
            continue
        world_name = tail.split("/")[0]
        base = r.split("/minecraftWorlds/", 1)[0] + "/minecraftWorlds"
        world_dirs.add((base, world_name))
    for base, name in sorted(world_dirs):
        has_level = any(
            x == f"{base}/{name}/level.dat" or x.endswith(f"/minecraftWorlds/{name}/level.dat")
            for x in rels
        )
        file_count = sum(
            1
            for x in rels
            if x.startswith(f"{base}/{name}/") and "/" in x[len(f"{base}/{name}/") :]
            or x == f"{base}/{name}/level.dat"
            or (x.startswith(f"{base}/{name}/") and not x.endswith("/"))
        )
        # simpler: count files under world
        prefix = f"{base}/{name}/"
        files = [x for x in rels if x.startswith(prefix) and x != prefix.rstrip("/")]
        level = f"{base}/{name}/level.dat" in rels or any(x.endswith("/level.dat") and f"/{name}/" in x for x in rels)
        lines.append(f"  [{base}]")
        lines.append(f"    └── {name}/  files_under={len(files)}  level.dat={'YES' if level else 'NO'}")
    lines.append("")

    lines.append("--- Every level.dat ---")
    for r in sorted(rels):
        if r.endswith("level.dat"):
            lines.append(f"  {r}")
    if not any(r.endswith("level.dat") for r in rels):
        lines.append("  (none)")
    lines.append("")

    lines.append("--- Every world_icon.jpeg ---")
    found = [r for r in rels if "world_icon" in r]
    for r in sorted(found):
        lines.append(f"  {r}")
    if not found:
        lines.append("  (none)")
    lines.append("")

    lines.append("--- Flat path list (relative to FTP root) ---")
    for r in sorted(rels):
        lines.append(f"  {r if r else '.'}")
    return lines


def main() -> int:
    if len(sys.argv) < 3:
        print("Usage: paths_to_tree.py <find_list.txt> <output_tree.txt> [ftp_root]", file=sys.stderr)
        return 1

    find_file = Path(sys.argv[1])
    out_file = Path(sys.argv[2])
    paths = [ln.strip() for ln in find_file.read_text(encoding="utf-8").splitlines() if ln.strip()]
    if not paths:
        print("Empty input", file=sys.stderr)
        return 1

    root = sys.argv[3] if len(sys.argv) > 3 else paths[0]
    rels = rel_paths(paths, root)

    tree: dict = {}
    for r in rels:
        if r:
            insert(tree, r.split("/"))

    header = [
        "MinecraftStorageFix — COMPLETE VFS map (every file and folder on FTP mount)",
        f"Source: {find_file.name} ({len(paths)} paths from `find`)",
        f"FTP root: {root}",
        f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}",
        "",
        "TREE (relative to FTP root):",
        "",
    ]
    body = render(tree)
    inv = inventory(paths, root)
    out_file.write_text("\n".join(header + body + inv), encoding="utf-8")
    print(f"Wrote {out_file} ({len(paths)} paths)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
