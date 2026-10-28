#!/usr/bin/env python3
"""Read-only JIT prerequisites. Never enables JIT or modifies device/app data."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f'{arguments[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='Signed development .app')
    parser.add_argument('--device', help='Optional paired CoreDevice identifier; read-only inspection')
    parser.add_argument('--output', type=Path, help='Local JSON report; no pairing data or device identifiers')
    args = parser.parse_args()
    if not args.app.is_dir() or not (args.app / 'Info.plist').is_file():
        parser.error('--app must point to an existing .app with Info.plist')
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    signed = run(['codesign', '-d', '--entitlements', ':-', str(args.app)])
    start = signed.find('<?xml')
    if start < 0:
        raise RuntimeError('Could not read XML entitlements from the signed app')
    entitlements = plistlib.loads(signed[start:].encode())
    report = {
        'inspectionOnly': True,
        'app': {'bundle': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'),
                'build': info.get('CFBundleVersion'), 'getTaskAllow': entitlements.get('get-task-allow') is True},
        'jitExecutionVerified': False,
        'note': 'Development signing and debugger access do not establish executable-memory support. No JIT code was executed.'
    }
    if args.device:
        with tempfile.TemporaryDirectory(prefix='veta-jit-preflight-') as temp:
            path = Path(temp) / 'device.json'
            run(['xcrun', 'devicectl', 'device', 'info', 'details', '--device', args.device, '--json-output', str(path)])
            device = json.loads(path.read_text())['result']
            properties = device.get('deviceProperties', {})
            connection = device.get('connectionProperties', {})
            report['device'] = {'os': properties.get('osVersionNumber'),
                                'developerMode': properties.get('developerModeStatus'),
                                'ddiServicesAvailable': properties.get('ddiServicesAvailable'),
                                'paired': connection.get('pairingState') == 'paired',
                                'transport': connection.get('transportType')}
    text = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
