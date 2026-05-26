#!/usr/bin/env python3
"""Scan a directory and print a box-drawing tree. Writes to folder_structure.txt."""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

# Box-drawing characters
TEE = "├── "
LAST = "└── "
PIPE = "│   "
SPACE = "    "

DEFAULT_SKIP_NAMES = {
    ".DS_Store",
    ".Trash",
    ".Trashes",
    ".fseventsd",
    ".Spotlight-V100",
    ".TemporaryItems",
}


def should_skip(name: str, skip_hidden: bool, skip_names: set[str]) -> bool:
    if name in skip_names:
        return True
    if skip_hidden and name.startswith("."):
        return True
    return False


def list_entries(path: Path, skip_hidden: bool, skip_names: set[str]) -> list[Path]:
    try:
        entries = list(path.iterdir())
    except OSError as e:
        return []  # caller handles via error marker

    visible = []
    errors = []
    for entry in entries:
        if should_skip(entry.name, skip_hidden, skip_names):
            continue
        visible.append(entry)

    def sort_key(p: Path) -> tuple:
        try:
            is_dir = p.is_dir()
        except OSError:
            is_dir = False
        return (0 if is_dir else 1, p.name.lower())

    visible.sort(key=sort_key)
    return visible


def format_size(path: Path) -> str:
    try:
        if path.is_dir():
            return "<dir>"
        size = path.stat().st_size
        if size < 1024:
            return f"{size} B"
        if size < 1024 * 1024:
            return f"{size / 1024:.1f} KB"
        return f"{size / (1024 * 1024):.1f} MB"
    except OSError:
        return "?"


def build_tree(
    root: Path,
    prefix: str = "",
    is_last: bool = True,
    max_depth: int | None = None,
    depth: int = 0,
    skip_hidden: bool = True,
    skip_names: set[str] | None = None,
    lines: list[str] | None = None,
    stats: dict | None = None,
) -> list[str]:
    if lines is None:
        lines = []
    if stats is None:
        stats = {"dirs": 0, "files": 0, "errors": 0}

    skip_names = skip_names or DEFAULT_SKIP_NAMES

    connector = LAST if is_last else TEE
    name = root.name if depth > 0 else str(root)
    if depth == 0:
        label = f"{name}/  [{format_size(root)}]"
    else:
        label = f"{name}/  [{format_size(root)}]" if root.is_dir() else f"{name}  [{format_size(root)}]"

    try:
        if root.is_dir():
            stats["dirs"] += 1
        else:
            stats["files"] += 1
    except OSError:
        stats["errors"] += 1
        label += "  (stat error)"

    lines.append(prefix + connector + label)

    if max_depth is not None and depth >= max_depth:
        if root.is_dir():
            child_prefix = prefix + (SPACE if is_last else PIPE)
            lines.append(child_prefix + "└── …  (max depth reached)")
        return lines

    try:
        if not root.is_dir():
            return lines
    except OSError as e:
        child_prefix = prefix + (SPACE if is_last else PIPE)
        lines.append(child_prefix + f"└── [error: {e}]")
        stats["errors"] += 1
        return lines

    entries = list_entries(root, skip_hidden, skip_names)
    child_prefix = prefix + (SPACE if is_last else PIPE)

    for i, entry in enumerate(entries):
        last_child = i == len(entries) - 1
        try:
            build_tree(
                entry,
                prefix=child_prefix,
                is_last=last_child,
                max_depth=max_depth,
                depth=depth + 1,
                skip_hidden=skip_hidden,
                skip_names=skip_names,
                lines=lines,
                stats=stats,
            )
        except OSError as e:
            conn = LAST if last_child else TEE
            lines.append(child_prefix + conn + f"{entry.name}  [error: {e}]")
            stats["errors"] += 1

    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan directory into a box-drawing tree.")
    parser.add_argument(
        "root",
        nargs="?",
        default="/Users/dxcool223/Library/CloudStorage/MountainDuck-192.168.4.35–FTP",
        help="Root path to scan",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=None,
        help="Output file (default: workspace folder_structure.txt)",
    )
    parser.add_argument(
        "--max-depth",
        type=int,
        default=None,
        help="Limit recursion depth (default: unlimited)",
    )
    parser.add_argument(
        "--include-hidden",
        action="store_true",
        help="Include dotfiles (still skips .Trash etc.)",
    )
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.exists():
        print(f"Error: path does not exist: {root}", file=sys.stderr)
        return 1

    workspace = Path(__file__).resolve().parent.parent
    out_path = Path(args.output) if args.output else workspace / "folder_structure.txt"

    stats = {"dirs": 0, "files": 0, "errors": 0}
    header = [
        "MinecraftStorageFix — VFS folder tree",
        f"Root: {root}",
        f"Scanned: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}",
        f"Max depth: {args.max_depth if args.max_depth is not None else 'unlimited'}",
        "",
    ]

    tree_lines = build_tree(
        root,
        max_depth=args.max_depth,
        skip_hidden=not args.include_hidden,
        stats=stats,
    )

    footer = [
        "",
        "─" * 60,
        f"Summary: {stats['dirs']} directories, {stats['files']} files, {stats['errors']} errors",
    ]

    body = "\n".join(header + tree_lines + footer)
    out_path.write_text(body, encoding="utf-8")
    print(body)
    print(f"\nWrote: {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
