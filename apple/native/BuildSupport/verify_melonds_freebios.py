#!/usr/bin/env python3
"""Rebuild the open ARM7 replacement BIOS and verify the checked-in bytes.

Requires Xcode clang and Homebrew arm-none-eabi-binutils. No Nintendo BIOS is
read, downloaded, or generated. Run against the pinned, patched melonDS tree.
"""
import argparse
import hashlib
import re
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
args = parser.parse_args()
source = args.source.resolve()
with tempfile.TemporaryDirectory(prefix="veta-freebios-") as temporary:
    base = Path(temporary) / "bios"
    commands = [
        ["xcrun", "clang", "-E", "-P", "-x", "assembler-with-cpp",
         "-DPLATFORM_NTR", "-DTARGET_ARM7", str(source / "freebios/src/bios_common.s"),
         "-o", str(base.with_suffix(".s"))],
        ["arm-none-eabi-as", "-mcpu=arm7tdmi", str(base.with_suffix(".s")),
         "-o", str(base.with_suffix(".o"))],
        ["arm-none-eabi-ld", "-Ttext=0", "-e", "0", str(base.with_suffix(".o")),
         "-o", str(base.with_suffix(".elf"))],
        ["arm-none-eabi-objcopy", "-O", "binary", str(base.with_suffix(".elf")),
         str(base.with_suffix(".bin"))],
    ]
    for command in commands:
        subprocess.run(command, check=True)
    header = (source / "src/FreeBIOS_Data.h").read_text()
    array = header.split("bios_ntr_arm7[] = {", 1)[1].split("};", 1)[0]
    expected = bytes(int(value, 16) for value in re.findall(r"0x([0-9a-f]{2})", array))
    actual = base.with_suffix(".bin").read_bytes()
    assert actual == expected, "Generated FreeBIOS bytes differ from source"
    assert len(actual) <= 0x4000, "Replacement exceeds ARM7 BIOS address space"
    symbols = subprocess.check_output(["arm-none-eabi-nm", "-n", str(base.with_suffix(".elf"))], text=True)
    checked = 0
    for line in symbols.splitlines():
        parts = line.split()
        if len(parts) == 3 and (parts[2].startswith("swi_") or parts[2] in ("interrupt_handler", "boot_handler")):
            assert 0x1204 <= int(parts[0], 16) < 0x4000, line
            checked += 1
    assert checked >= 25, "Missing replacement BIOS routines"
    print(f"FreeBIOS source/bytes match; {checked} routine labels above BIOSPROT; "
          f"{len(actual)} bytes; sha256={hashlib.sha256(actual).hexdigest()}")
