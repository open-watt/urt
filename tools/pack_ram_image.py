#!/usr/bin/env python3

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zlib


SYMBOLS = (
    "_image_start",
    "_image_limit",
    "_ram_image_load",
    "_ram_image_start",
    "_ram_image_end",
    "_ram_image_deflated",
)


def read_symbols(nm, elf):
    result = subprocess.run(
        [nm, "--defined-only", "-P", elf],
        check=True,
        capture_output=True,
        text=True,
    )
    values = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0] in SYMBOLS:
            values[fields[0]] = int(fields[2], 16)
    missing = set(SYMBOLS) - values.keys()
    if missing:
        raise ValueError("missing linker symbols: " + ", ".join(sorted(missing)))
    return values


def pack(image, symbols, image_format):
    image_start = symbols["_image_start"]
    image_limit = symbols["_image_limit"]
    ram_load = symbols["_ram_image_load"]
    ram_length = symbols["_ram_image_end"] - symbols["_ram_image_start"]
    ram_offset = ram_load - image_start
    flag_offset = symbols["_ram_image_deflated"] - image_start

    if image_limit <= image_start:
        raise ValueError("invalid image bounds")
    if ram_length < 0 or ram_offset < 0:
        raise ValueError("invalid RAM image bounds")
    if ram_offset + ram_length != len(image):
        raise ValueError("RAM image is not the final loaded region")
    if flag_offset < 0 or flag_offset >= ram_offset:
        raise ValueError("RAM image format byte is outside the immutable image")

    raw = bytes(image[ram_offset:])
    if image_format == "deflate":
        encoder = zlib.compressobj(9, zlib.DEFLATED, -15)
        encoded = encoder.compress(raw) + encoder.flush()
        if zlib.decompress(encoded, -15) != raw:
            raise ValueError("RAM image compression verification failed")
        image[ram_offset:] = encoded
        image[flag_offset] = 1
    else:
        image[flag_offset] = 0

    limit = image_limit - image_start
    if len(image) > limit:
        raise ValueError(f"packed image exceeds limit by {len(image) - limit} bytes")
    return len(raw), len(image) - ram_offset


def replace(path, data):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            output.write(data)
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nm", required=True)
    parser.add_argument("--format", choices=("raw", "deflate"), required=True)
    parser.add_argument("elf")
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()

    symbols = read_symbols(args.nm, args.elf)
    image = bytearray(args.binary.read_bytes())
    raw_length, stored_length = pack(image, symbols, args.format)
    replace(args.binary, image)
    print(f"RAM image: {raw_length} -> {stored_length} bytes ({args.format})")


if __name__ == "__main__":
    main()
