#!/usr/bin/env python3
"""Copy explicit development runtime overrides after Xcode's cached embed phase.

Only DolphinCore and N64NextCore are owned here. Verify the exact selected code
before and after signing; never alter the source framework or a frozen product.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid


ALLOWED = {"DolphinCore", "N64NextCore"}


def identity(path):
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from("<II", data) != (0xfeedfacf, 0x100000c):
        raise ValueError(f"Expected thin arm64 Mach-O: {path}")
    count, command_bytes = struct.unpack_from("<II", data, 16)
    end, offset = 32 + command_bytes, 32
    if end > len(data):
        raise ValueError("Truncated Mach-O commands")
    identifiers, sections = [], {}
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > end:
            raise ValueError("Invalid Mach-O command length")
        if command == 0x1b:
            if size < 24:
                raise ValueError("Truncated UUID")
            identifiers.append(str(uuid.UUID(bytes=data[offset + 8:offset + 24])).upper())
        if command == 0x19:
            if size < 72:
                raise ValueError("Truncated segment")
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + section_count * 80 > size:
                raise ValueError("Truncated sections")
            for index in range(section_count):
                item = offset + 72 + index * 80
                name = data[item:item + 16].split(b"\0")[0].decode("ascii")
                segment = data[item + 16:item + 32].split(b"\0")[0].decode("ascii")
                address, length, position = struct.unpack_from("<QQI", data, item + 32)
                flags = struct.unpack_from("<I", data, item + 64)[0]
                if flags & 255 in (1, 12, 18):  # zero-fill sections have no file bytes
                    continue
                if length and (position == 0 or position + length > len(data)):
                    raise ValueError("Invalid section range")
                key = segment + "," + name
                if key in sections:
                    raise ValueError("Duplicate section")
                sections[key] = dict(address=address, size=length, flags=flags,
                                     sha256=hashlib.sha256(data[position:position + length]).hexdigest())
        offset += size
    if offset != end or len(identifiers) != 1 or "__TEXT,__text" not in sections:
        raise ValueError("Missing UUID/text or invalid command region")
    dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    return dict(uuid=identifiers[0], sections=sections,
                dependencies=[line.strip() for line in dependencies],
                sha256=hashlib.sha256(data).hexdigest())


def verify(expected, actual):
    for key in ("uuid", "sections", "dependencies"):
        if expected[key] != actual[key]:
            raise ValueError(f"Runtime identity mismatch: {key}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", action="append", required=True, help="Name=/absolute/Name.framework")
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    if os.environ.get("PLATFORM_NAME") != "iphoneos":
        raise ValueError("Device runtime overrides require PLATFORM_NAME=iphoneos")
    build_root = Path(os.environ["TARGET_BUILD_DIR"]).resolve(strict=True)
    relative = Path(os.environ["FRAMEWORKS_FOLDER_PATH"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Framework destination must be inside TARGET_BUILD_DIR")
    destination = (build_root / relative).resolve()
    if not destination.is_relative_to(build_root) or destination == build_root:
        raise ValueError("Unsafe framework destination")
    signing = os.environ.get("CODE_SIGNING_ALLOWED") != "NO"
    signer = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
    if signing and not signer:
        raise ValueError("Missing EXPANDED_CODE_SIGN_IDENTITY; refusing an unsigned replacement")
    # Validate every requested source before replacing any destination.
    sources, seen = [], set()
    for specification in args.core:
        name, supplied = specification.split("=", 1)
        if name not in ALLOWED or name in seen:
            raise ValueError("Unsupported or duplicate runtime override: " + name)
        seen.add(name)
        source = Path(supplied).resolve(strict=True)
        if not source.is_dir() or source.name != name + ".framework":
            raise ValueError("Unexpected source framework: " + str(source))
        target = destination / source.name
        if source == target.resolve() or source.is_relative_to(destination):
            raise ValueError("Source must be outside the app framework destination")
        sources.append((name, source, target, identity(source / name)))
    destination.mkdir(parents=True, exist_ok=True)
    records = []
    for name, source, target, expected in sources:
        with tempfile.TemporaryDirectory(prefix=".veta-runtime-", dir=destination) as temporary:
            staging = Path(temporary) / source.name
            # Dereference links into independent copies before codesign can write.
            shutil.copytree(source, staging)
            verify(expected, identity(staging / name))
            if signing:
                subprocess.run(["codesign", "--force", "--sign", signer, "--timestamp=none",
                                "--preserve-metadata=identifier,flags", str(staging)], check=True)
                subprocess.run(["codesign", "--verify", "--strict", str(staging)], check=True)
            verified = identity(staging / name)
            verify(expected, verified)
            # The source is immutable even when the destination receives a new signature.
            if identity(source / name)["sha256"] != expected["sha256"]:
                raise ValueError("Source framework changed during embedding")
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.exists():
                shutil.rmtree(target)
            staging.rename(target)
        verify(expected, identity(target / name))
        records.append(dict(name=name, source=str(source), target=str(target),
                            expected=expected, embedded=verified, signed=signing))
        print("VETA runtime verified:", name, expected["uuid"], flush=True)
    receipt = args.receipt or Path(os.environ["DERIVED_FILE_DIR"]) / "verified-runtime-frameworks.json"
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps(dict(passed=True, cores=records), indent=2) + "\n")


if __name__ == "__main__":
    main()
