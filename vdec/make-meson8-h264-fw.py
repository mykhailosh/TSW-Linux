#!/usr/bin/env python3
"""Build meson/vdec/meson8_h264.bin from the Amlogic Meson8 H.264 microcode headers.

The headers come from the vendor 3.10 kernel (hardkernel/linux, branch odroidc-3.10.y,
drivers/amlogic/amports/m8/ucode/h264/). They are GPL C arrays of 32-bit words.

Output layout, as the mainline meson vdec driver expects it:
  0x0000  main code, 0x1000 words (16 KiB), loaded into the AMRISC IMEM
  0x4000  swap area, 20 KiB, copied to a DMA buffer whose address goes to AV_SCRATCH_G:
          header, data, mmco, list, slice, 0x400 words each
          (the vendor vh264.c MC_OFFSET_HEADER..MC_OFFSET_SLICE order)
Words are written little-endian.

Usage:
  make-meson8-h264-fw.py --fetch OUT.bin          download the headers and build
  make-meson8-h264-fw.py --src DIR OUT.bin        use headers already in DIR
"""

import argparse
import hashlib
import os
import re
import struct
import sys
import urllib.request

BASE = ("https://raw.githubusercontent.com/hardkernel/linux/odroidc-3.10.y/"
        "drivers/amlogic/amports/m8/ucode/h264/")

MAIN = ("h264c_linux.h", 0x1000)
SWAP = [  # order of the 20 KiB swap area
    ("h264header_linux.h", 0x400),
    ("h264data_linux.h", 0x400),
    ("h264mmc_linux.h", 0x400),
    ("h264list_linux.h", 0x400),
    ("h264slice_linux.h", 0x400),
]


def parse_words(text, name):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    m = re.search(r"MicroCode\s*\[\s*\]\s*[^=]*=\s*\{(.*?)\}", text, flags=re.S)
    if not m:
        sys.exit(f"{name}: no MicroCode array found")
    words = [int(v, 16) for v in re.findall(r"0x[0-9a-fA-F]+", m.group(1))]
    return words


def take(words, count, name):
    if len(words) < count:
        sys.exit(f"{name}: {len(words)} words, expected {count}")
    extra = words[count:]
    if any(extra):
        sys.exit(f"{name}: {len(extra)} extra words are not zero")
    if extra:
        print(f"{name}: {len(words)} words, dropping {len(extra)} trailing zero word(s)")
    for w in words[:count]:
        if w > 0xffffffff:
            sys.exit(f"{name}: word 0x{w:x} does not fit 32 bits")
    return words[:count]


def read_header(args, fname):
    if args.fetch:
        with urllib.request.urlopen(BASE + fname, timeout=60) as r:
            return r.read().decode("ascii", "replace")
    with open(os.path.join(args.src, fname), encoding="ascii", errors="replace") as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--fetch", action="store_true", help="download the headers from GitHub")
    g.add_argument("--src", help="directory with the vendor headers")
    ap.add_argument("out", help="output file, e.g. meson8_h264.bin")
    args = ap.parse_args()

    blob = b""
    parts = {}
    for fname, count in [MAIN] + SWAP:
        words = take(parse_words(read_header(args, fname), fname), count, fname)
        parts[fname] = words
        blob += struct.pack(f"<{count}I", *words)

    # The vendor debug loader builds the IMEM image as main[0:0x800] + data + list.
    # Report whether the built-in main code already has them at 0x800, for reference.
    main_w = parts[MAIN[0]]
    same_data = main_w[0x800:0xc00] == parts["h264data_linux.h"]
    same_list = main_w[0xc00:0x1000] == parts["h264list_linux.h"]
    print(f"main[0x800:0xc00] == data: {same_data}, main[0xc00:0x1000] == list: {same_list}")

    if len(blob) != 0x4000 + 20 * 1024:
        sys.exit(f"internal error: size {len(blob)}")
    with open(args.out, "wb") as f:
        f.write(blob)
    print(f"{args.out}: {len(blob)} bytes, sha256 {hashlib.sha256(blob).hexdigest()}")


if __name__ == "__main__":
    main()
