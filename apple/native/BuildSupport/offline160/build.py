#!/usr/bin/env python3
"""Build one prepared engine in a NEW output directory; never install to a device.

Requires the explicitly supplied, source-built dependency toolchains described
in README.md. Toolchains and dependencies are not silently installed globally.
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

from common import ROOT, PINS, check_inputs, check_revision, digest, run
from verify_sources import verify


def framework(raw, output, name, minimum, bundle_id, version, slirp=False):
    target = output / (name + '.framework')
    target.mkdir()
    binary = target / name
    shutil.copy2(raw, binary)
    binary.chmod(0o755)
    architecture = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
    platform = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
    if architecture != 'arm64' or 'platform IOS\n' not in platform or 'minos ' + minimum not in platform:
        raise ValueError('Expected an arm64 iOS device binary with the declared deployment target')
    command = ['xcrun', 'install_name_tool', '-id', f'@rpath/{name}.framework/{name}']
    if slirp:
        command += ['-change', '@rpath/libslirp.0.dylib', '@rpath/DukeXSlirp.framework/DukeXSlirp']
    run(command + [binary])
    info = {'CFBundleIdentifier': bundle_id, 'CFBundleName': name, 'CFBundleExecutable': name,
            'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '160',
            'CFBundleShortVersionString': version, 'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'MinimumOSVersion': minimum}
    (target / 'Info.plist').write_bytes(plistlib.dumps(info))
    run(['codesign', '--force', '--sign', '-', '--timestamp=none', target])
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if not dependency.startswith(('@rpath/', '/System/Library/', '/usr/lib/')):
            raise ValueError('Nonportable binary dependency: ' + dependency)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('engine', choices=PINS['engines'])
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4, choices=range(1, 5))
    parser.add_argument('--emsdk', type=Path, help='Private emsdk 4.0.1 checkout, installed and activated')
    parser.add_argument('--tools', type=Path, help='DukeX private Python venv with pinned meson/ninja')
    parser.add_argument('--vcpkg-prefix', type=Path, help='Pinned DukeX arm64-veta-ios prefix')
    parser.add_argument('--vulkan-headers', type=Path, help='Pinned Khronos Vulkan-Headers checkout')
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    meta = check_inputs(args.engine)
    marker = json.loads((source / '.veta-offline160.json').read_text())
    if marker != {'engine': args.engine, 'revision': meta['revision'], 'patches': meta['patches']}:
        parser.error('Source marker does not match this recipe; prepare a fresh checkout')
    verify(args.engine, source)
    if output.exists() or source == output or source in output.parents or output in source.parents:
        parser.error('Output must be a new directory separate from the source tree')
    if args.engine == 'play' and not args.emsdk:
        parser.error('Play requires --emsdk')
    if args.engine == 'dukex' and not all((args.tools, args.vcpkg_prefix, args.vulkan_headers)):
        parser.error('DukeX requires --tools, --vcpkg-prefix and --vulkan-headers')
    output.mkdir(parents=True)
    build = output / 'build'
    artifacts = output / 'artifacts'
    artifacts.mkdir()
    environment = os.environ.copy()
    environment.pop('SDKROOT', None)
    products = []
    if args.engine == 'flycast':
        flags = ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                 '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.4', '-DCMAKE_BUILD_TYPE=Release',
                 '-DIOS=ON', '-DLIBRETRO=ON', '-DUSE_GLES=OFF', '-DUSE_GLES2=OFF',
                 '-DUSE_VULKAN=OFF', '-DUSE_BREAKPAD=OFF', '-DUSE_LUA=OFF',
                 '-DUSE_HOST_LIBZIP=OFF', '-DUSE_OPENMP=OFF',
                 '-DCMAKE_C_FLAGS=-DIOS -DTARGET_NO_REC',
                 '-DCMAKE_CXX_FLAGS=-DIOS -DTARGET_NO_REC',
                 '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON']
        run(['cmake', '-S', source, '-B', build, *flags], env=environment)
        run(['cmake', '--build', build, '--target', 'flycast_libretro', '--parallel', args.jobs], env=environment)
        raw = build / 'flycast_libretro.dylib'
        symbols = subprocess.check_output(['nm', '-gU', str(raw)], text=True)
        for name in ('retro_init', 'retro_load_game', 'retro_run'):
            if ' _' + name not in symbols:
                raise ValueError('Missing Flycast API: ' + name)
        products.append(framework(raw, artifacts,
                                  'DreamcastInterpreterCore', '17.4',
                                  'com.veta.private.dreamcastinterpretercore', '1.0'))
    elif args.engine == 'play':
        sdk = args.emsdk.resolve()
        check_revision(sdk, meta['toolchain']['revision'])
        tools = sdk / 'upstream/emscripten'
        environment.update(EMSDK=str(sdk), EM_CONFIG=str(sdk / '.emscripten'), EMSDK_PYTHON=sys.executable)
        environment['PATH'] = str(tools) + os.pathsep + environment['PATH']
        version = subprocess.check_output([str(tools / 'emcc'), '--version'], env=environment, text=True)
        if '4.0.1' not in version.splitlines()[0]:
            raise ValueError('Emscripten 4.0.1 is required')
        run([tools / 'emcmake', 'cmake', '-S', source, '-B', build,
             '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_TESTS=OFF', '-DBUILD_PLAY=ON',
             '-DBUILD_PSFPLAYER=OFF', '-DUSE_QT=OFF', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5'], env=environment)
        run(['cmake', '--build', build, '--target', 'Play', '--parallel', args.jobs], env=environment)
        for name in ('Play.js', 'Play.wasm'):
            target = artifacts / name
            shutil.copy2(build / 'Source/ui_js' / name, target)
            products.append(target)
    else:
        if any(character.isspace() or character == ':' for character in str(source) + str(build)):
            parser.error('DukeX configure requires source/output paths without spaces or colons')
        headers = args.vulkan_headers.resolve()
        check_revision(headers, meta['dependencies']['vulkan_headers']['revision'])
        prefix = args.vcpkg_prefix.resolve()
        vcpkg = prefix.parent.parent
        dependency_meta = meta['dependencies']['vcpkg']
        check_revision(vcpkg, dependency_meta['revision'])
        run(['git', '-C', vcpkg, 'apply', '--reverse', '--check',
             (ROOT / dependency_meta['patch']).resolve()])
        versions = {}
        for block in (prefix.parent / 'vcpkg/status').read_text().split('\n\n'):
            fields = dict(line.split(': ', 1) for line in block.splitlines()
                          if ': ' in line and not line.startswith(' '))
            if fields.get('Architecture') == 'arm64-veta-ios' and 'Version' in fields:
                versions[fields['Package']] = fields['Version']
        for package in dependency_meta['installed_versions']:
            if versions.get(package['package']) != package['version']:
                raise ValueError('Unexpected iOS dependency version: ' + package['package'])
        environment['PATH'] = str(args.tools.resolve() / 'bin') + os.pathsep + environment['PATH']
        environment.update(CMAKE=shutil.which('cmake') or 'cmake', XEMU_VETA_IOS_CMAKE='1',
                           XEMU_IOS_BUILD_DIR=str(build), IOS_DEPLOYMENT_TARGET='17.0',
                           XEMU_IOS_VCPKG_PREFIX=str(prefix), MOLTENVK_ROOT=str(headers),
                           XEMU_IOS_NINJA_TARGETS='libxemu-ios-core.dylib',
                           XEMU_IOS_CONFIGURE_ARGS='--enable-tcg-interpreter')
        run(['bash', source / 'ios/scripts/build-core-ios.sh', '-j', args.jobs], cwd=source, env=environment)
        configuration = (build / 'config-host.h').read_text()
        if not any(line.strip() in ('#define CONFIG_TCG_INTERPRETER', '#define CONFIG_TCG_INTERPRETER 1')
                   for line in configuration.splitlines()):
            raise ValueError('Build did not select the TCG interpreter')
        raw = build / 'libxemu-ios-core.dylib'
        symbols = subprocess.check_output(['nm', '-gU', str(raw)], text=True)
        for name in ('xemu_veta_execution_mode', 'xemu_veta_bridge_abi', 'xemu_ios_main'):
            if ' _' + name not in symbols:
                raise ValueError('Missing DukeX API: ' + name)
        products.append(framework(raw, artifacts, 'DukeXInterpreterCore', '17.0',
                                  'com.veta.private.dukexinterpretercore', '1.0.2', slirp=True))
        products.append(framework(build / 'subprojects/slirp/libslirp.0.dylib', artifacts,
                                  'DukeXSlirp', '17.0', 'com.veta.private.dukexslirp', '1.0.2'))
    shutil.copytree(ROOT / 'licenses', artifacts / 'licenses')
    receipt = {'engine': args.engine, 'revision': meta['revision'], 'patches': meta['patches'],
               'products': [{'path': str(p.relative_to(output)), 'sha256': digest(p),
                             'bytes': p.stat().st_size} for p in products],
               'device_test': 'NOT_RUN', 'binary_identity_with_reference': 'NOT_CLAIMED'}
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
