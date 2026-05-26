#!/usr/bin/env python3
"""
patch_game_binary.py — ARM64 binary patches for Minecraft tvOS 1.1.5 (minecraftappletv).

Prologue signatures extracted via IDA Pro MCP (file offset = VA - 0x100000000 for
unslid __TEXT). Patches overwrite the function entry with immediate return:

  sub_1006634DC  → MOV X0, #1 ; RET   (catalog owned / global unlock)
  sub_100369B34  → MOV X0, #0 ; RET   (skin padlock UI eraser)

Usage:
  python3 scripts/patch_game_binary.py /path/to/minecraftappletv [--dry-run]
  python3 scripts/patch_game_binary.py /path/to/minecraftappletv -o /path/to/patched
"""

from __future__ import annotations

import argparse
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

# IDA MCP get_bytes @ 2026-05-23 (tvOS 1.1.5 minecraftappletv)
IMAGE_BASE = 0x100000000

# ARM64 little-endian instruction words (user-specified payloads)
PATCH_OWNED_TRUE = bytes.fromhex("200080D2C0035FD6")  # MOV X0, #1 ; RET
PATCH_LOCK_FALSE = bytes.fromhex("000080D2C0035FD6")  # MOV X0, #0 ; RET


@dataclass(frozen=True)
class BinaryPatch:
    name: str
    ida_va: int
    description: str
    signature: bytes
    patch: bytes

    @property
    def file_offset(self) -> int:
        return self.ida_va - IMAGE_BASE


PATCHES: tuple[BinaryPatch, ...] = (
    BinaryPatch(
        name="sub_1006634DC_catalog_owned",
        ida_va=0x1006634DC,
        description="IsOwned / catalog ownership gate — force true",
        signature=bytes.fromhex(
            "FD7BBFA9FD03009108A04239A8010034"
        ),
        patch=PATCH_OWNED_TRUE,
    ),
    BinaryPatch(
        name="sub_100369B34_skin_padlock_ui",
        ida_va=0x100369B34,
        description="Skin/pack padlock UI evaluator — force false",
        signature=bytes.fromhex(
            "FFC302D1F85F07A9F65708A9F44F09A9"
        ),
        patch=PATCH_LOCK_FALSE,
    ),
)


def find_unique(haystack: bytes, needle: bytes) -> int:
    start = 0
    hits: list[int] = []
    while True:
        idx = haystack.find(needle, start)
        if idx < 0:
            break
        hits.append(idx)
        start = idx + 1
    if not hits:
        raise ValueError(f"signature not found ({len(needle)} bytes)")
    if len(hits) > 1:
        raise ValueError(f"signature ambiguous: {len(hits)} matches at {hits[:5]}")
    return hits[0]


def apply_patches(data: bytearray, use_offset: bool) -> list[str]:
    log: list[str] = []
    for spec in PATCHES:
        if use_offset:
            off = spec.file_offset
            if off < 0 or off + len(spec.patch) > len(data):
                raise ValueError(f"{spec.name}: file offset 0x{off:X} out of range")
            if data[off : off + len(spec.signature)] != spec.signature:
                at = data[off : off + len(spec.signature)].hex().upper()
                want = spec.signature.hex().upper()
                raise ValueError(
                    f"{spec.name}: bytes @ 0x{off:X} mismatch\n  got  {at}\n  want {want}"
                )
            log.append(f"PATCH @ file+0x{off:X} ({spec.ida_va:#x}) {spec.name}")
        else:
            off = find_unique(data, spec.signature)
            if data[off : off + len(spec.signature)] != spec.signature:
                raise ValueError(f"{spec.name}: search hit failed verify")
            log.append(f"PATCH @ file+0x{off:X} (search) {spec.name}")

        data[off : off + len(spec.patch)] = spec.patch
        log.append(f"  → {spec.description}")
        log.append(f"  → {spec.patch.hex(' ').upper()}")
    return log


def main() -> int:
    parser = argparse.ArgumentParser(description="Patch minecraftappletv ownership UI gates")
    parser.add_argument("input", type=Path, help="Path to decrypted minecraftappletv binary")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output path (default: overwrite input after .bak backup)",
    )
    parser.add_argument(
        "--search",
        action="store_true",
        help="Locate by prologue signature scan instead of fixed VA offset",
    )
    parser.add_argument("--dry-run", action="store_true", help="Validate only; do not write")
    args = parser.parse_args()

    src = args.input.expanduser().resolve()
    if not src.is_file():
        print(f"error: not a file: {src}", file=sys.stderr)
        return 1

    blob = bytearray(src.read_bytes())
    try:
        lines = apply_patches(blob, use_offset=not args.search)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    for line in lines:
        print(line)

    if args.dry_run:
        print("dry-run OK — no file written")
        return 0

    dst = args.output.expanduser().resolve() if args.output else src
    if dst == src:
        bak = src.with_suffix(src.suffix + ".bak")
        if not bak.exists():
            shutil.copy2(src, bak)
            print(f"backup: {bak}")
        dst.write_bytes(blob)
        print(f"wrote: {dst}")
    else:
        shutil.copy2(src, dst)
        dst.write_bytes(blob)
        print(f"wrote: {dst}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
