#!/usr/bin/env python3
"""Stage exact notices and a local corresponding-core-source package.

This is not a full corresponding-source offer for the complete VETA application.
No upload or publication is performed.
"""
from pathlib import Path
import hashlib, json, subprocess, tarfile, io
from build import BASE, HERE, PINS

def excluded(name):
    parts = Path(name).parts
    return (any(p in ('.git', 'target', '__pycache__') for p in parts)
            or name.endswith(('.o', '.dylib', '.pyc'))
            or Path(name).name in ('sh2_master_boot_rom.bin', 'sh2_slave_boot_rom.bin', 'm68k_vectors.bin')
            or ('profile' in parts and name.endswith('.rom')))

def main():
    cargo=Path.home()/'.cargo/bin/cargo'
    metadata=json.loads(subprocess.check_output([str(cargo),'metadata','--locked','--format-version','1',
        '--manifest-path',str(HERE/'sega/Cargo.toml')],text=True))
    root=BASE/'.build/commercial170'; root.mkdir(parents=True,exist_ok=True)
    rows=[]; notices=[]; dependencies=[]
    for item in metadata['packages']:
        source=Path(item['manifest_path']).parent
        in_upstream=source.is_relative_to(BASE/'.build/jgenesis-commercial')
        license=item['license'] or ('GPL-3.0-or-later (repository LICENSE)' if in_upstream else None)
        assert license, 'Unidentified dependency license: '+item['name']
        rows.append({'name':item['name'],'version':item['version'],'license':license,'source':item['source'] or 'local pinned source'})
        if not item['source']:continue
        dependencies.append((item,source))
        notices.append(f"\n{item['name']} {item['version']} · {license}\n{item['source']}\n")
        files=sorted(p for p in source.rglob('*') if p.is_file() and
            (p.name.lower().startswith(('license','copying','copyright','notice')) or 'LICENSES' in p.parts))
        for path in files:
            notices.append(f'\n--- {path.relative_to(source)} ---\n'+path.read_text(errors='replace'))
    (root/'dependencies.json').write_text(json.dumps(rows,indent=2)+'\n')
    content=BASE/'Content'
    for name,prefix in [('bsnes-commercial','BSNES'),('jgenesis-commercial','JGenesis')]:
        source=BASE/'.build'/name;repo,pin=PINS[name]
        sections=[f'{repo} · {pin}\nhttps://github.com/{repo}/tree/{pin}\nVETA modifications: BuildSupport/commercial170\n']
        for path in sorted(source.rglob('*')):
            if path.is_file() and '.git' not in path.parts and path.name.lower().startswith(('license','copying','copyright')):
                sections.append(f'\n--- {path.relative_to(source)} ---\n'+path.read_text(errors='replace'))
        if prefix=='JGenesis':sections+=notices
        if prefix=='BSNES':
            sections.append('SPC700 replacement: StackBlender LLC, GPL-3.0-or-later\n'
                'https://github.com/StackBlender/snes-spc700-boot-rom/tree/6f3f92686b6477654fdc76289516281e91e8d509\n'
                +(HERE/'spc700-free/LICENSE').read_text())
        (content/(prefix+'-LICENSE.txt')).write_text('\n'.join(sections))
    # Remove obsolete notices from NEW app packaging only. Old products and
    # original pinned archives retain their complete notices for reproducibility.
    for name in ('Snes9x-LICENSE.txt','snes-ntsc-LICENSE.txt'):
        (content/name).unlink(missing_ok=True)
    archive=root/'commercial170-core-sources.tar.gz'
    # Cargo registry extraction does not necessarily contain vendor checksums.
    # Use Cargo's vendor format so an exported build works offline.
    vendor=root/'cargo-vendor'
    subprocess.run([str(cargo),'vendor','--offline','--locked','--versioned-dirs',
        '--manifest-path',str(HERE/'sega/Cargo.toml'),str(vendor)],check=True,stdout=subprocess.DEVNULL)
    def exclude(info):
        if excluded(info.name):return None
        return info
    with tarfile.open(archive,'w:gz') as tar:
        def add_bytes(name,data):
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=0o644;tar.addfile(info,io.BytesIO(data))
        for name in PINS:
            tree=BASE/'.build'/name;prefix='apple/native/.build/'+name
            tar.add(tree,arcname=prefix,filter=exclude)
            files={p.relative_to(tree).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(tree.rglob('*'))
                   if p.is_file() and not p.is_symlink() and not excluded(str(p))}
            repo,pin=PINS[name]
            add_bytes(prefix+'/VETA-SOURCE-PIN.json',json.dumps({'repo':repo,'commit':pin,'files':files},indent=2).encode())
        tar.add(HERE,arcname='apple/native/BuildSupport/commercial170',filter=exclude)
        tar.add(root/'dependencies.json',arcname='DEPENDENCIES.json')
        for item,source in dependencies:
            folder=item['name']+'-'+item['version']
            # Preserve every vendor file covered by Cargo's checksum manifest;
            # e.g. cc/src/target is source code, not a build directory.
            tar.add(vendor/folder,arcname='cargo-vendor/'+folder)
        add_bytes('.cargo/config.toml',b'[source.crates-io]\nreplace-with="veta-vendored"\n[source.veta-vendored]\ndirectory="cargo-vendor"\n')
    receipt={'archive':str(archive),'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),
             'dependencies':len(rows),'scope':'two cores and adapter; complete VETA distribution compliance remains pending'}
    (root/'source-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n'); print(json.dumps(receipt))

if __name__=='__main__':main()
