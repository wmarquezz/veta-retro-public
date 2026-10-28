#!/usr/bin/env python3
"""Synthetic-only reader contracts; outputs stay in a temporary directory."""
from pathlib import Path
import argparse, subprocess, tempfile, sys
HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / 'Sources' / 'PS2DiscReader.swift'
parser = argparse.ArgumentParser()
parser.add_argument('--sanitizer', choices=['none', 'address', 'thread'], default='none')
parser.add_argument('--ios-link', action='store_true')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='veta-ps2-reader-') as directory:
    work = Path(directory)
    subprocess.run([sys.executable, str(HERE/'fixtures.py'), str(work/'fixtures')], check=True)
    flags = [] if args.sanitizer == 'none' else ['-sanitize='+args.sanitizer]
    subprocess.run(['xcrun', 'swiftc', '-Onone', '-swift-version', '5', *flags,
                    '-parse-as-library', str(SOURCE), str(HERE/'Test.swift'), '-o', str(work/'tests')], check=True)
    subprocess.run([str(work/'tests'), str(work/'fixtures')], check=True)
    if args.ios_link:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'swiftc', '-emit-library', '-swift-version', '5',
                        '-target', 'arm64-apple-ios16.4', '-sdk', sdk, str(SOURCE),
                        '-o', str(work/'PS2DiscReader.dylib')], check=True)
        print('PASS iOS16.4 arm64 component link with system zlib')
