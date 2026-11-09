#!/usr/bin/env python3
"""Summarize a HID report descriptor (hex string file) per report ID and direction.

Usage: python3 -I parse_hid_descriptor.py device/s61_hid_report_descriptor.hex
"""
import sys
from collections import defaultdict

MAIN = {0x8: "Input", 0x9: "Output", 0xB: "Feature", 0xA: "Collection", 0xC: "EndCollection"}


def main():
    raw = bytes.fromhex(open(sys.argv[1]).read().strip())
    g = {"page": 0, "lmin": 0, "lmax": 0, "size": 0, "count": 0, "rid": 0}
    usages, umin = [], None
    reports = defaultdict(list)  # (kind, rid) -> list of fields
    depth, i = 0, 0
    while i < len(raw):
        b = raw[i]
        size = (0, 1, 2, 4)[b & 3]
        typ, tag = (b >> 2) & 3, b >> 4
        data = raw[i + 1:i + 1 + size]
        val = int.from_bytes(data, "little") if size else 0
        sval = int.from_bytes(data, "little", signed=True) if size else 0
        i += 1 + size
        if typ == 0:  # main
            kind = MAIN.get(tag, f"main{tag:x}")
            if kind == "Collection":
                depth += 1
            elif kind == "EndCollection":
                depth -= 1
            else:
                flags = "const" if val & 1 else ("var" if val & 2 else "array")
                reports[(kind, g["rid"])].append(
                    dict(page=g["page"], usages=list(usages), umin=umin, size=g["size"],
                         count=g["count"], lmin=g["lmin"], lmax=g["lmax"], flags=flags))
            usages, umin = [], None
        elif typ == 1:  # global
            if tag == 0: g["page"] = val
            elif tag == 1: g["lmin"] = sval
            elif tag == 2: g["lmax"] = sval if g["lmin"] < 0 else val
            elif tag == 7: g["size"] = val
            elif tag == 8: g["rid"] = val
            elif tag == 9: g["count"] = val
        elif typ == 2:  # local
            if tag == 0: usages.append(val)
            elif tag == 1: umin = val

    for (kind, rid), fields in sorted(reports.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        bits = sum(f["size"] * f["count"] for f in fields)
        print(f"\n{kind:7s} report 0x{rid:02x}: {bits} bits = {bits // 8} bytes payload (+1 report-ID byte)")
        off = 0
        for f in fields:
            us = f["usages"]
            ushow = (f"usages {', '.join(f'0x{u:02x}' for u in us[:12])}{' …' if len(us) > 12 else ''}" if us
                     else (f"usage_min 0x{f['umin']:x}" if f["umin"] is not None else "no usage"))
            print(f"   bit {off:4d}: {f['count']:3d} x {f['size']:2d}-bit  range {f['lmin']}..{f['lmax']:<6d} "
                  f"page 0x{f['page']:04x} {f['flags']:5s} {ushow}")
            off += f["size"] * f["count"]


if __name__ == "__main__":
    main()
