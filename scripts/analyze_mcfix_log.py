#!/usr/bin/env python3
"""Full-console export analysis — no keyword-only scanning."""

from __future__ import annotations

import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


def parse_line(ln: str):
    parts = ln.split("\t")
    if len(parts) >= 4:
        return parts[0], parts[1], parts[2], "\t".join(parts[3:])
    return "", "", "", ln


def ts_sec(ts: str) -> float:
    m = re.match(r"(\d+):(\d+):(\d+)\.(\d+)", ts)
    if not m:
        return 0.0
    h, mi, s, us = map(int, m.groups())
    return h * 3600 + mi * 60 + s + us / 1e6


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "new_logs.txt")
    lines = path.read_text(errors="replace").splitlines()
    print(f"file: {path}  lines={len(lines)}  bytes={path.stat().st_size}")

    by_minute: dict[str, list] = defaultdict(list)
    corpse = []
    prevboot = []
    mcfix = []
    non_mcfix_after_crash = []

    for i, ln in enumerate(lines, 1):
        lvl, ts, proc, msg = parse_line(ln)
        if ts:
            by_minute[ts[:5]].append((i, ts, proc, msg, lvl))
        if re.search(r"corpse|ReportCrash|jetsam|memorystatus|fatal 309", ln, re.I):
            corpse.append((i, ln))
        if "PREVBOOT" in msg or "PREVBOOT" in ln:
            prevboot.append((i, ln))
        if re.search(r"\[MCFIX", msg):
            mcfix.append((i, ts, lvl, msg[:160]))

    print("\n--- sessions (lines per HH:MM) ---")
    for k in sorted(by_minute.keys()):
        n = len(by_minute[k])
        mc = sum(1 for x in by_minute[k] if "minecraft" in (x[2] or "").lower())
        print(f"  {k}  total={n}  minecraft={mc}")

    print(f"\n--- MCFIX lines: {len(mcfix)} ---")
    print(f"--- PREVBOOT lines: {len(prevboot)} ---")
    print(f"--- kernel/crash hints in export: {len(corpse)} ---")
    for i, ln in corpse[:20]:
        print(f"  L{i}: {ln[:240]}")

    # Latest session = max timestamp prefix among minecraft lines
    minecraft = [(i, ts, lvl, msg) for i, ts, lvl, msg in mcfix if ts]
    if not minecraft:
        print("\nNo MCFIX minecraft lines found.")
        return 1

    latest_min = max(ts[:5] for _, ts, _, _ in minecraft)
    sess = [(i, ts, lvl, m) for i, ts, lvl, m in minecraft if ts.startswith(latest_min)]
    print(f"\n--- latest MCFIX session ({latest_min}) lines={len(sess)} ---")
    if sess:
        t0, t1 = ts_sec(sess[0][1]), ts_sec(sess[-1][1])
        print(f"span: {sess[0][1]} -> {sess[-1][1]}  ({t1 - t0:.3f}s)")
        print("last 12:")
        for i, ts, lvl, m in sess[-12:]:
            print(f"  L{i} {lvl:7s} {ts}  {m}")

    # fault vs default in latest session
    faults = sum(1 for _, _, lvl, _ in sess if lvl == "fault")
    print(f"\nlatest session log levels: fault={faults} (fault breadcrumbs were os_log_fault, not crashes)")

    print("\n--- markers in latest session ---")
    markers = [
        "crashtrace",
        "mirror wrote catalog_info",
        "no boot catalog_info",
        "marketplace boot passthrough",
        "posix opendir",
        "readdir #3 EOF",
        "FATAL",
        "Phase B complete",
    ]
    for mk in markers:
        hits = [x for x in sess if mk.lower() in x[3].lower()]
        print(f"  {mk}: {len(hits)}")
        if hits:
            print(f"    last L{hits[-1][0]} {hits[-1][3][:120]}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
