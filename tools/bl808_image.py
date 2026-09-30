#!/usr/bin/env python3
# BL808 single image: the M0 image with D0 appended as a payload M0 inflates at boot.
#
# payload (little-endian, 4-aligned):
#   u32 entry
#   u32 count
#   count * { u32 dest; u32 size }
#   count raw-deflate streams, back to back, each inflating to `size` bytes at `dest`

import argparse
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

PT_LOAD = 1
RUN_MERGE_GAP = 0x10000


def load_segments(elf):
    if elf[:4] != b"\x7fELF" or elf[4] != 2 or elf[5] != 1:
        raise ValueError("expected a little-endian ELF64")
    entry, phoff = struct.unpack_from("<QQ", elf, 0x18)
    phentsize, phnum = struct.unpack_from("<HH", elf, 0x36)
    segments = []
    for i in range(phnum):
        p_type, _, p_offset, p_vaddr, p_paddr, p_filesz, _ = struct.unpack_from("<IIQQQQQ", elf, phoff + i * phentsize)
        if p_type != PT_LOAD or p_filesz == 0:
            continue
        if p_paddr != p_vaddr:
            raise ValueError(f"segment at {p_vaddr:#x} has a separate load address {p_paddr:#x}")
        segments.append((p_vaddr, elf[p_offset:p_offset + p_filesz]))
    return entry, sorted(segments)


def coalesce(segments):
    runs = []
    for addr, data in segments:
        if runs:
            start, buf = runs[-1]
            gap = addr - (start + len(buf))
            if 0 <= gap <= RUN_MERGE_GAP:
                buf += bytes(gap) + data
                continue
            if gap < 0:
                raise ValueError(f"segment at {addr:#x} overlaps the previous one")
        runs.append((addr, bytearray(data)))
    return runs


def pack(elf_path):
    entry, segments = load_segments(Path(elf_path).read_bytes())
    runs = coalesce(segments)
    header = struct.pack("<II", entry, len(runs))
    streams = b""
    for addr, data in runs:
        if addr + len(data) > 0xFFFFFFFF:
            raise ValueError(f"run at {addr:#x} is beyond M0's 32-bit reach")
        encoder = zlib.compressobj(9, zlib.DEFLATED, -15)
        stream = encoder.compress(bytes(data)) + encoder.flush()
        if zlib.decompress(stream, -15) != data:
            raise ValueError("deflate verification failed")
        header += struct.pack("<II", addr, len(data))
        streams += stream
        print(f"D0 run {addr:#010x}: {len(data)} -> {len(stream)} bytes")
    return header + streams


def read_symbols(nm, elf, names):
    out = subprocess.run([nm, "--defined-only", "-P", elf], check=True, capture_output=True, text=True).stdout
    values = {}
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0] in names:
            values[fields[0]] = int(fields[2], 16)
    missing = set(names) - values.keys()
    if missing:
        raise ValueError("missing linker symbols: " + ", ".join(sorted(missing)))
    return values


def append(nm, m0_elf, m0_bin, payload):
    sym = read_symbols(nm, m0_elf, ("_image_start", "_d0_image", "_image_limit"))
    image = bytearray(Path(m0_bin).read_bytes())
    offset = sym["_d0_image"] - sym["_image_start"]
    if len(image) > offset:
        raise ValueError(f"M0 image runs {len(image) - offset} bytes past _d0_image")
    image += bytes(offset - len(image)) + payload
    limit = sym["_image_limit"] - sym["_image_start"]
    if len(image) > limit:
        raise ValueError(f"M0 + D0 image exceeds the bank by {len(image) - limit} bytes")
    print(f"M0 {offset} + D0 {len(payload)} = {len(image)} of {limit} bytes")
    return image


def replace(path, data):
    path = Path(path)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        output.write(data)
    os.replace(output.name, path)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("pack")
    p.add_argument("elf")
    p.add_argument("payload")
    a = sub.add_parser("append")
    a.add_argument("--nm", required=True)
    a.add_argument("elf")
    a.add_argument("binary")
    a.add_argument("payload")
    args = parser.parse_args()

    if args.command == "pack":
        replace(args.payload, pack(args.elf))
    else:
        replace(args.binary, append(args.nm, args.elf, args.binary, Path(args.payload).read_bytes()))


if __name__ == "__main__":
    main()
