#!/usr/bin/env python3
"""Extract Komplete Kontrol S-series MK1 firmware images from NI's KKS_Firmware_Updater.

Usage:
    python3 -I extract_kks_mk1_fw.py /path/to/KKS_Firmware_Updater.app OUT_DIR

Found in updater 1.2.0 (R147), x86_64 Mach-O: a table in __DATA,__data with one
record per keyboard model:

    u64 usb_pid | u64 ptr_A | u64 len_A | u64 ptr_B | u64 len_B     (terminated by pid 0)

ptr_* are virtual addresses inside __TEXT,__const.
  A = main image, 0x16c00-0x17900 bytes, 64-byte header with magic a7 8a a5 80.
      Not encrypted, judging by entropy (~6.9 bits/byte). CPU architecture not yet identified.
  B = plain ARM Cortex-M0/M0+ image (~17 KB) with the vector table at offset 0.

Only reads the updater. Nothing is executed or sent to the device.
"""
import hashlib
import os
import struct
import sys

MODELS = {0x1340: "S25MK1", 0x1350: "S49MK1", 0x1360: "S61MK1", 0x1410: "S88MK1"}
LC_SEGMENT_64 = 0x19


def macho_sections(buf):
    magic, _cpu, _sub, _ftype, ncmds, _sz, _flags, _res = struct.unpack_from("<IiiIIIII", buf, 0)
    if magic != 0xFEEDFACF:
        raise SystemExit("not a 64-bit little-endian Mach-O (fat binaries: run `lipo -thin x86_64` first)")
    off, secs = 32, []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", buf, off + 64)[0]
            s = off + 72
            for _ in range(nsects):
                sect = buf[s:s + 16].rstrip(b"\0").decode()
                seg = buf[s + 16:s + 32].rstrip(b"\0").decode()
                addr, size, foff = struct.unpack_from("<QQI", buf, s + 32)
                secs.append((seg, sect, addr, size, foff))
                s += 80
        off += cmdsize
    return secs


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    app, out = sys.argv[1], sys.argv[2]
    exe = os.path.join(app, "Contents", "MacOS", "KKS_Firmware_Updater") if app.endswith(".app") else app
    buf = open(exe, "rb").read()
    print(f"updater sha256 {hashlib.sha256(buf).hexdigest()}")
    secs = macho_sections(buf)
    tconst = next(s for s in secs if s[0] == "__TEXT" and s[1] == "__const")
    _, _, t_addr, t_size, t_off = tconst

    def va2off(va, n):
        if not (t_addr <= va and va + n <= t_addr + t_size):
            return None
        return t_off + (va - t_addr)

    os.makedirs(out, exist_ok=True)
    found = 0
    for seg, sect, addr, size, foff in secs:
        if seg != "__DATA":
            continue
        for i in range(0, size - 40, 8):
            pid, pa, la, pb, lb = struct.unpack_from("<5Q", buf, foff + i)
            if pid not in MODELS:
                continue
            oa, ob = va2off(pa, la), va2off(pb, lb)
            if oa is None or ob is None or not (0x1000 < la < 0x40000 and 0x1000 < lb < 0x40000):
                continue
            name = MODELS[pid]
            for tag, o, n in (("A", oa, la), ("B", ob, lb)):
                blob = buf[o:o + n]
                path = os.path.join(out, f"{name}_{tag}_pid{pid:04x}.bin")
                open(path, "wb").write(blob)
                print(f"{name} {tag}: {n:6d} bytes  head={blob[:8].hex(' ')}  sha256={hashlib.sha256(blob).hexdigest()[:16]}…  -> {path}")
            sp, rv = struct.unpack_from("<II", buf, ob)
            print(f"        B vector table: initial SP=0x{sp:08x} reset=0x{rv:08x}")
            found += 1
    if not found:
        raise SystemExit("no firmware table found; this updater build may use a different layout")


if __name__ == "__main__":
    main()
