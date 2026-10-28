# Native runtime165 source recipe

This optional recipe rebuilds the tested-source Dolphin **zva** and N64 **state-y** from public pinned upstream repositories plus the committed patches. It does not copy a validation directory, download games/BIOS, install an app, activate JIT, change radios, or claim a new binary has passed device tests. `legacy` remains the default and retains the previous build/source locations.

## Rebuild

From the repository root:

```sh
python3 apple/native/BuildSupport/build_advanced.py --recipe runtime165 --sdk iphoneos --only dolphin-retro mupen-next
```

Sources are separate at `apple/native/.build/runtime165/engine-sources/{dolphin-retro,mupen-next}`. CMake output is under the existing per-engine DerivedData cache, in `runtime165/device`. Canonical framework products and receipts are written to:

- `apple/native/.build/runtime165/iphoneos/DolphinCore.framework`
- `apple/native/.build/runtime165/iphoneos/N64NextCore.framework`
- Adjacent `DolphinCore-recipe.json` and `N64NextCore-recipe.json`.

The frameworks retain install names `@rpath/Name.framework/Name`, arm64/iOS16.4 configuration. Signing remains the app embedding step's responsibility. The source recipe is currently restricted to `--sdk iphoneos`; simulator builds remain available with `--recipe legacy`. No simulator acceptance is inherited.

An optional `--source-root /absolute/prepared/root` selects another source root. An existing nonempty directory without Git metadata is rejected. A new root is fetched at the exact commit and mapped submodules are initialized at their pinned revisions. No reset/clean is used. Unknown local source changes, partial application, submodule changes, missing notices or a mismatching revision are rejected.

Read-only preflight for existing checkouts:

```sh
python3 apple/native/BuildSupport/build_advanced.py --recipe runtime165 --sdk iphoneos --only dolphin-retro mupen-next --dry-run
```

This checks and reports pristine/prepared status and performs `git apply --check` for pristine sources. It neither fetches, applies, configures nor compiles. A missing checkout fails instead of downloading during dry-run.

## Provenance and patch scope

- Dolphin baseline: `libretro/dolphin` commit `3aac3f052f733f8df2f1616843a4d2e14002ed11`, including 37 recorded recursive submodules.
- Engine5 import: `Provenance-Emu/iCube` commit `e0fa51223d897beaf0aca1671095242232b3595b`, **not** a release-label approximation. Original copyright/SPDX lines remain in the consolidated patch.
- Dolphin patch consolidates the inherited VETA libretro/system/render adaptations, conservative engine5, specialized FP arithmetic, target cache, state/unload boundaries, index/uniform/vertex streaming and pointer-offset fix, then synchronous audio publication before frontend return. There are30 modified upstream files and one added file, `Common/Visibility.h`. The new header is part of the patch and post-apply hash list.
- Diagnostic profile and validator are not forced on. Rejected/unhelpful z1 PSQ-pair, z2 branch-fusion and integer candidates are not part of this chain. Guest clocks are not changed by this recipe.
- N64 baseline: `libretro/mupen64plus-libretro-nx` commit `15bada85906593376e8fd697f1b0b3af3a20f512`. Its three-file patch includes the previously delivered audio-register correction, truthful unserialize result/minimum size checks, and unlocking on invalid state magic. No state format, renderer or CPU backend is changed by the patch.
- The pinned N64 tree contains an unmapped `lightning/gnulib` gitlink and no `.gitmodules`. The reference has this directory empty; device source generation excludes paraLLEl RSP. The recipe verifies that exact unused gitlink instead of attempting an impossible submodule update.

`pins.json` records source/patch hashes, before/after hashes of every changed file, submodule revisions, exact existing build metadata, and the hash of `mupen-next.json` (which determines the generated CMake source list/defines). Dolphin explicitly enables LTO, matching the tested-source recipe; Release flags remain O3/NDEBUG. The current reference was built with Apple clang17.0.0.17000604, iPhoneOS26.2 and CMake4.4.0. Different tools/build paths may change UUID or code sections: source equality does not establish binary equality. Build receipts record compiler, flags, UUID, dependency list and binary hash, and explicitly mark device validation not run.

## Notices and normal app integration

```sh
python3 apple/native/BuildSupport/write_extra_credits.py --runtime165-source-root apple/native/.build/runtime165/engine-sources
```

The collector verifies both prepared sources, includes the complete upstream `LICENSES` directories (including GPL/MIT/BSD/CC0 names), original notices and pinned source URLs, and adds the iCube derivation URL. It preserves the other engines' existing notice collection. `--output /private/review/EngineLicenses.txt` allows review without replacing the app resource.

The integrated iPhone development generator defaults to `runtime165`. The general selector, other generators, App Store target and simulator recipes retain their existing defaults. An explicit selector is still supported:

```sh
env -u VETA_PERF165_DOLPHIN_FRAMEWORK -u VETA_PERF165_N64_FRAMEWORK \
  VETA_ENGINE_RECIPE=runtime165 python3 apple/integrated-jit/prepare_veta.py
```

This selects **both** canonical frameworks together, validates pin/patch/flags/SDK/hash/ABI/UUID/bundle ID from their adjacent receipts, and rejects simultaneous diagnostic overrides (even empty ones). Missing or stale products fail with the rebuild command; project preparation never downloads or compiles a core implicitly. The collector verifies prepared sources, atomically stages full notices into `Content/EngineLicenses.txt`, and writes `.build/runtime165/integration-selection.json` with the selected product/receipt and license hashes. Identical notice content is not rewritten.

The always-run post-build phase first checks that the products, receipts and license resource still match that prepared selection, then runs the existing `verify_embed_runtime.py` copy/sign/section verification. Changing a canonical product after project generation requires preparation again. This addresses both ambiguous source selection and Xcode's previously observed stale embed. The integrated iPhone default was promoted after root reported canonical Dolphin physical checks in MKDD 2P/4P, Melee combat and Wii Xump, and prior N64 validation. These are scoped game checks, not universal compatibility or 60 distinct images per second. Every new frozen app still requires its identity gate. Set `VETA_ENGINE_RECIPE=legacy` explicitly when using historical independent diagnostic overrides; old override variables without that explicit choice fail fast. Simulator and App Store targets remain unchanged; these canonical frameworks are iPhoneOS-only. Do not ship private validation paths or commercial artifacts. Keep the existing native state namespace stable unless separately validated.

`test_selection.py` checks the real canonical products and full notices, then uses independent temporary copies to reject missing products/receipts, incorrect pins, changed binaries, changed notices, post-preparation receipt drift, duplicate dependencies and conflicting old overrides. It also executes the real preparation script with project writes and XcodeGen intercepted, verifying exactly two replacements and the always-run verification chain without changing the active project or building an app. It also runs the integrated generator with an empty environment and real resolver, validates explicit legacy fallback, and rejects missing canonical products, stale override variables and an empty recipe before any project/resource write or build/download.

## Source checks without compiling

`test_recipe.py` accepts `--dolphin-git`, `--n64-git`, `--dolphin-reference`, `--n64-reference` and `--report`. It extracts pristine versions of the changed files from the pinned local Git histories, applies the real patches in disposable fixtures, compares every resulting byte to the given candidate sources, checks dry-run/reverse checks and rejects changed or missing files. It also validates the real Dolphin checkout/submodules and full notice collection. It does not edit either reference.

During integration, all31 Dolphin and3 N64 patched files matched the reference candidates. An additional isolated local N64 clone was prepared and all2,275 tracked regular files matched state-y. These are source reconstruction checks; canonical compilation results are recorded below and do not establish iPhone acceptance. The first test-run failed only importing the collector from the test helper's module path; that helper import was corrected and the complete run passed.

## Canonical build audit · 2026-10-27

Both device frameworks compiled successfully in the separate runtime165 cache with the pinned patch sets. Publishing now verifies the exact reference export names/types (Dolphin357; N644943), dependencies, arm64 architecture, iOS platform and minimum OS16.4 before copying the framework. Framework bundle identifiers are pinned to the references. Receipts retain `deviceTest: NOT_RUN`.

N64 reproduced reference UUID `DC5CB30F-CFB7-3C04-8E33-4BB5843E5530` and every file-backed Mach-O section. Signature bytes differ; the recipe does not sign the app. Dolphin produced UUID `6290A222-A96A-3AF2-B2A0-28724962C22A`, distinct from the physically tested zva product `4A519BF9-7767-3BFD-BE48-206097DDAF78`. Both have the same exported ABI and dependencies.

A full Dolphin source inventory (35,790 files, including submodules) matched the reference exactly. CMake scalar settings, flags files, all3,546 generated compile/preprocess/assembly commands and link commands matched after normalizing only the source/build directory prefixes. Compiler metadata also matched. Generated `scmrev.h` differs in abbreviated description and branch (`3aac3f052f`/`master` versus `3aac3f0`/`HEAD`); the full pinned revision matches. The new `__text` is1,184 bytes shorter and `__cstring`452 bytes shorter. Paths and generated metadata are observed differences, **not a proof that they explain every code difference**. The rebuilt Dolphin needs its own physical smoke gate before promotion; no cosmetic UUID rewriting is used.

The source defaults and initialization retain CIR profile and link/specialized validators OFF; there is no new diagnostic compile override. A runtime configuration could still opt into diagnostics, so the final app operator must verify runtime settings separately.

To preview notices without touching the app resource, run the collector with `--output apple/native/.build/runtime165/EngineLicenses.txt`. Preparation with `VETA_ENGINE_RECIPE=runtime165` now invokes the verified collector automatically; the app continues embedding `Content` as its existing folder resource. Selection tests use temporary outputs and intercept project generation, leaving the current app project and frozen products untouched.
