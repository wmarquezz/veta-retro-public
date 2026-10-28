# Replacement cores 170

The iOS app replaces Snes9x with bsnes-mercury (performance profile), and Genesis Plus GX with jgenesis's Mega Drive / Master System / Game Gear backends. Both upstream repositories declare GPLv3-family licenses permitting commercial use subject to their conditions. This does not clear the complete VETA distribution, its other copyleft combinations, third-party games/artwork, or App Store terms.

Pins are in `build.py`. `sega/Cargo.lock` pins the Rust dependency graph. No executable download, native JIT, VPN, or external activation is used by these two adapters. Unused 32X firmware and bsnes profile ROM assets are excluded. The embedded SPC700 IPL is replaced with StackBlender's GPL-3.0-or-later implementation, pinned in `spc700-free/UPSTREAM.json`; its assembler, license and documentation are included. This is not a legal clearance of all VETA assets.

## Build

The packaged iPhone slices and generated application targets require iOS 17.4 or later.

Install the Rust targets `aarch64-apple-ios` and `aarch64-apple-ios-sim` and use Xcode with these SDKs. From the repository root:

```
python3 apple/native/BuildSupport/commercial170/build.py --sdk macosx
python3 apple/native/BuildSupport/commercial170/build.py --sdk iphoneos
python3 apple/native/BuildSupport/commercial170/build.py --sdk iphonesimulator
python3 apple/native/BuildSupport/commercial170/integration.py
python3 apple/native/BuildSupport/commercial170/notices.py
```

Public and integrated project generators call `integration.apply` to remove both old dependencies and add the new XCFrameworks. The helper also handles frozen development projects that refer to old binaries by absolute path. Existing runtime165 Dolphin/N64 source selection remains independent and must still pass its own recipe verification.

`notices.py` collects original notices, a dependency-license inventory, and a local source archive including these adapters, pinned upstream trees and Cargo dependency sources. This archive is **not** a complete corresponding-source offer for the whole VETA application and is not automatically uploaded. Maintain the full source/attribution obligations before distribution.

## Adapter changes

- bsnes: preserve AAPCS64 d8–d15 across coroutine switches; initialize the complete context. Performance profile with HLE special-chip option avoids requiring DSP dumps for supported HLE chips. This is not universal cartridge compatibility.
- jgenesis: expose real SRAM/EEPROM as Libretro memory, rather than a delayed shadow buffer; use stable IEEE arithmetic instead of experimental relaxed float methods. Genesis and SMS/GG clocks, 48 kHz audio, image stride, two controller ports, fixed-size bounded save-state envelopes and reset/unload are bridged locally.
- 32X and Sega CD are not exposed by this adapter. The unused 32X dependency has zero placeholders instead of boot ROM arrays; its original firmware is excluded from the distributable source archive. Standalone Genesis is the only Genesis hardware mode constructed.
- Existing profile keys are retained and translated to the new region options. Two-player capability does not mean two physical phones were tested in this change.
- New core identities and `engines/<coreID>` directories prevent old snapshots/RAM from being loaded or overwritten with incompatible formats. Old files remain untouched, but cannot be loaded directly by these replacements. No automatic state or battery conversion is claimed.

## Evidence

`test_core.py` exercises an isolated ARM64 Mac core with a caller-owned ROM: animated video, nonzero audio, both input callbacks, deterministic snapshot replay, and SRAM reload where present. It writes screenshots and checks the ROM remained unchanged. Menu scripts are scenario-specific; a silent password/menu screen is not proof of a core audio failure.

`Commercial170QA.swift` is a development-only explicit launch route. It uses the ordinary player with isolated save directories and records iPhone frames/audio/input/save/restore. It is not entered during a normal launch, and does not certify all gameplay, TV, physical multiplayer, sustained thermals or every cartridge.

Local private validation receipts are outside the repository in `../veta170-validation`. Commercial game files, device pairing material and private backups must remain outside source packages/Git.
