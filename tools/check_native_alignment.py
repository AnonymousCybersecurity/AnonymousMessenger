#!/usr/bin/env python3
"""Check 64-bit native ELF alignment in APK, AAB and AAR artifacts without extracting them."""

import argparse
import struct
import sys
import zipfile
from pathlib import Path

PAGE_SIZE = 16384
ABIS = {"arm64-v8a": 183, "x86_64": 62}


def check_elf(data, abi):
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("expected a little-endian 64-bit ELF library")
    if struct.unpack_from("<H", data, 18)[0] != ABIS[abi]:
        raise ValueError("ELF architecture does not match its ABI directory")
    header_offset = struct.unpack_from("<Q", data, 32)[0]
    header_size, header_count = struct.unpack_from("<HH", data, 54)
    if header_size < 56 or header_offset + header_size * header_count > len(data):
        raise ValueError("invalid ELF program headers")
    load_count = 0
    for index in range(header_count):
        header = header_offset + index * header_size
        if struct.unpack_from("<I", data, header)[0] != 1:  # PT_LOAD
            continue
        load_count += 1
        offset, address = struct.unpack_from("<QQ", data, header + 8)
        alignment = struct.unpack_from("<Q", data, header + 48)[0]
        if alignment < PAGE_SIZE or alignment % PAGE_SIZE or (address - offset) % PAGE_SIZE:
            raise ValueError(f"LOAD segment alignment is {alignment} bytes or its offset is incompatible")
    if not load_count:
        raise ValueError("ELF has no LOAD segments")


def check_artifact(path):
    failures = []
    checked = 0
    with zipfile.ZipFile(path) as archive, path.open("rb") as raw:
        for entry in archive.infolist():
            parts = entry.filename.split("/")
            if not entry.filename.endswith(".so") or len(parts) < 3 or parts[-2] not in ABIS:
                continue
            checked += 1
            try:
                check_elf(archive.read(entry), parts[-2])
                # Only stored APK libraries are loaded directly from the ZIP.
                if path.suffix.lower() == ".apk" and entry.compress_type == zipfile.ZIP_STORED:
                    raw.seek(entry.header_offset)
                    header = raw.read(30)
                    if len(header) != 30 or header[:4] != b"PK\x03\x04":
                        raise ValueError("invalid ZIP local header")
                    name_size, extra_size = struct.unpack_from("<HH", header, 26)
                    data_offset = entry.header_offset + 30 + name_size + extra_size
                    if data_offset % PAGE_SIZE:
                        raise ValueError("uncompressed APK library is not ZIP-aligned to 16 KB")
            except (ValueError, struct.error) as error:
                failures.append(f"{entry.filename}: {error}")
    if not checked:
        failures.append("no ARM64 or x86-64 native libraries found")
    for failure in failures:
        print(f"FAIL {path}: {failure}", file=sys.stderr)
    if not failures:
        print(f"PASS {path}: {checked} native libraries support 16 KB alignment")
    return not failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path, nargs="+")
    args = parser.parse_args()
    success = True
    for path in args.artifacts:
        try:
            success = check_artifact(path) and success
        except (OSError, zipfile.BadZipFile) as error:
            print(f"FAIL {path}: {error}", file=sys.stderr)
            success = False
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
