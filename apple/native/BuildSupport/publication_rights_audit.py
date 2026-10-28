#!/usr/bin/env python3
"""Read-only evidence inventory, not legal clearance; never modifies the app."""
import argparse, hashlib, json, plistlib, subprocess, zipfile
from pathlib import Path

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()

def audit(app, native):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    catalog = json.loads((app / 'DiscoveryCatalog.json').read_text())
    games = []
    for entry in catalog:
        item = dict(entry)
        if entry.get('bundled'):
            folder = app / 'Content' / entry['bundled']
            payload = folder / entry['filename']
            license_path = folder / 'LICENSE.txt'
            archive = folder / 'source-and-game.zip'
            item['evidence'] = {
                'binaryExists': payload.is_file(),
                'binarySHA256': sha(payload) if payload.is_file() else None,
                'licenseExists': license_path.is_file(),
                'licenseSHA256': sha(license_path) if license_path.is_file() else None,
                'sourceArchiveExists': archive.is_file(),
                'sourceArchiveSHA256': sha(archive) if archive.is_file() else None,
            }
            if archive.is_file():
                with zipfile.ZipFile(archive) as source:
                    names = source.namelist()
                    item['evidence']['archiveEntries'] = len(names)
                    item['evidence']['codeFiles'] = sum(Path(n).suffix.lower() in ('.c','.cpp','.h','.s','.asm','.inc','.bas') for n in names)
                    item['evidence']['identicalBinaryInArchive'] = [f.filename for f in source.infolist()
                        if payload.is_file() and f.file_size == payload.stat().st_size
                        and hashlib.sha256(source.read(f)).hexdigest() == item['evidence']['binarySHA256']]
            item['publicationStatus'] = 'license-evidence-present-further-rights-review-required'
        else:
            item['publicationStatus'] = 'external-offer-permission-not-cleared'
        games.append(item)
    engines = []
    for name in ('extra-cores.json', 'advanced-cores.json'):
        for entry in json.loads((native / 'BuildSupport' / name).read_text()):
            if entry['name']=='genesis' and not (app/'Frameworks/GenesisCore.framework').exists():
                continue
            engines.append({k:entry[k] for k in ('name','repo','commit')})
    for framework, name, repo, commit in (
        ('BSNESCore','bsnes-mercury','libretro/bsnes-mercury','79d7f9de218b6ffa65a80bbdc5828532bc239232'),
        ('JGenesisCore','jgenesis','jsgroth/jgenesis','0a00c47ba7a16bd6e77ef7e0b6c8fab2fc603cba')):
        if (app/'Frameworks'/(framework+'.framework')).is_dir():
            engines.append({'name':name,'repo':repo,'commit':commit,'modifications':'BuildSupport/commercial170'})
    psp = json.loads((native / 'BuildSupport/ppsspp.json').read_text())
    engines.append({'name':'ppsspp','repo':psp['repo'],'commit':psp['commit']})
    frameworks = []
    for bundle in sorted((app / 'Frameworks').glob('*.framework')):
        metadata = plistlib.loads((bundle / 'Info.plist').read_bytes())
        binary = bundle / metadata['CFBundleExecutable']
        frameworks.append({'name':bundle.name,'sha256':sha(binary)})
    firmware = []
    dolphin = native / '.build/engine-sources/dolphin-retro'
    pin = next(e['commit'] for e in engines if e['name']=='dolphin-retro')
    for name in ('dsp_rom.bin','dsp_coef.bin'):
        file = app / 'Content/DolphinSys/GC' / name
        upstream = subprocess.run(['git','show',pin+':Data/Sys/GC/'+name],cwd=dolphin,capture_output=True)
        firmware.append({'path':file.relative_to(app).as_posix(),'sha256':sha(file),
                         'matchesPinnedFreeReplacement':upstream.returncode==0 and hashlib.sha256(upstream.stdout).hexdigest()==sha(file),
                         'source':f'https://github.com/libretro/dolphin/tree/{pin}/docs/DSP/free_dsp_rom'})
    known = {'sega_101.bin','mpr-17933.bin','scph1001.bin','scph5500.bin','scph5501.bin','scph5502.bin','dc_boot.bin','dc_flash.bin','bios7.bin','bios9.bin','bios.bin','firmware.bin','ipl.bin','prod.keys','aes_keys.txt','boot9.bin','boot11.bin'}
    matches = sorted(p.relative_to(app).as_posix() for p in app.rglob('*') if p.is_file() and p.name.lower() in known)
    notices = []
    for p in (app / 'Content').rglob('*'):
        if p.is_file() and any(k in p.name.lower() for k in ('license','copying','ofl','notice')):
            notices.append({'path':p.relative_to(app).as_posix(),'sha256':sha(p)})
    return {'schema':1,'kind':'rights-evidence-not-legal-clearance','version':info['CFBundleVersion'],
            'mainBinarySHA256':sha(app / info['CFBundleExecutable']),
            'catalogCount':len(games),'bundledCount':sum(bool(e.get('bundled')) for e in games),
            'games':games,'declaredEnginePins':engines,'frameworks':frameworks,'dolphinReplacements':firmware,
            'knownFirmwareNameMatches':matches,'noticeFiles':notices,
            'limitations':['Filename checks do not prove absence of embedded or renamed third-party firmware.',
                           'Source archives are inspected but not rebuilt; license scope over art/music needs review.',
                           'Declared pins are not proof of reproducible binary-to-source correspondence.',
                           'No iPhone container or external private collection inspected.'],
            'publicationCleared':False}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app',type=Path)
    parser.add_argument('--report',type=Path,required=True)
    args = parser.parse_args()
    result = audit(args.app,Path(__file__).resolve().parents[1])
    args.report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ('version','catalogCount','bundledCount','knownFirmwareNameMatches','publicationCleared')}))
