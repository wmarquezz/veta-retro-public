# PS2 logical-disc reader contracts

Run on macOS with Xcode command-line tools:

```sh
python3 apple/native/BuildSupport/tests/ps2-disc-reader/run.py --ios-link
python3 apple/native/BuildSupport/tests/ps2-disc-reader/run.py --sanitizer address
python3 apple/native/BuildSupport/tests/ps2-disc-reader/run.py --sanitizer thread
```

Only synthetic bytes are generated, in a temporary directory removed on completion. There are no ROMs, BIOS files, private paths, downloads, application builds or device operations. Python's raw zlib encoder produces independent fixtures for the Swift/system-zlib decoder.

Coverage: ISO and mixed compressed/stored CSO v1; logical2048-byte sectors; block sizes2048 through65536; alignment shifts0,1,2,16; final partial compressed/stored blocks; full and overlapping/unaligned random ranges; EOF and integer limits; malformed header/index/DEFLATE; wrong decoded length; truncation and mutation after opening, including cached data; final symlink/nonregular rejection; concurrent reads;128KiB cache ceiling.

Accepted subset: CSO version1,24-byte header, reserved bytes0, block sizes powers of two2–64KiB, shifts0–16, logical size a positive multiple of2048, physical and logical size≤8GiB. The complete index must be monotonic, bounded and consistent with alignment/stored lengths. Inputs per compressed block are bounded; raw DEFLATE must end with exactly the declared decoded block size (partial final block uses the remaining logical bytes). Older encoders with header_size0, larger blocks, CISOv2 and ZISO are intentionally unsupported. An invalid `.cso` never silently becomes ISO.

`read` accepts0..8MiB and returns exact logical bytes. Reader is read-only and Sendable with locked cache/reads. It rejects changes to the open inode's size/mtime/ctime. The caller must validate allowed library paths; only the final path component's symlink is rejected here. These contracts do not establish emulator performance or game compatibility.
