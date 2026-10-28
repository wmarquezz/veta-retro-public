#!/usr/bin/env python3
"""Reconstruct the exported public project, never the personal development app."""
import argparse, hashlib, json, subprocess, sys, tarfile
from pathlib import Path
BASE=Path(__file__).resolve().parents[2];ROOT=BASE.parents[1]
sys.path.insert(0,str(BASE/'BuildSupport'))
def unpack(filename,destination,strip=1,expected=None):
 source=ROOT/'vendor/native'/filename
 if expected and hashlib.sha256(source.read_bytes()).hexdigest()!=expected:raise ValueError('Archive checksum: '+filename)
 destination.mkdir(parents=True,exist_ok=True)
 with tarfile.open(source) as archive:
  for m in archive:
   name=Path(*Path(m.name).parts[strip:])
   if str(name)=='.':continue
   if name.is_absolute() or '..' in name.parts or not (m.isfile() or m.isdir()):raise ValueError('Unsafe source archive')
   target=destination/name
   if m.isdir():target.mkdir(parents=True,exist_ok=True)
   else:
    target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(archive.extractfile(m).read());target.chmod(0o755 if m.mode&0o111 else 0o644)
def run(args):subprocess.run([str(x) for x in args],cwd=ROOT,check=True)
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prepare-only',action='store_true');a=p.parse_args()
unpack('fceumm-ac0d00a.tar.gz',BASE/'.build/fceumm',0,'6d9664deb1223c079ffa982e664a89485932761cd8655609a9b2039699434612')
unpack('mgba-0.10.5.tar.gz',BASE/'.build/mgba',1,'9475c26e9fa2f4b30c07ab6636e4b0a5b62e4baee2109ede7b2fecc52edae366')
for core in json.loads((BASE/'BuildSupport/extra-cores.json').read_text()):
 if core['name'] in ('genesis','stella'):continue
 unpack(core['archive'],BASE/'.build'/core['name'],1,core['sha256'])
 if core['name']=='pcsx':(BASE/'.build/pcsx/include/revision.h').write_text('#define REV "'+core['commit'][:8]+'"\n')
psp=json.loads((BASE/'BuildSupport/ppsspp.json').read_text())
unpack(psp['archive'],BASE/'.build/ppsspp',1,psp['sha256'])
from public_games import apply,audit
project=json.loads((BASE/'project.json').read_text());apply(project,BASE)
(BASE/'project.json').write_text(json.dumps(project,indent=2)+'\n')
if audit(BASE/'.build/public-games',BASE):raise ValueError('Public content audit')
# Verify that every statically compiled source and explicitly selected source directory exists.
missing=[]
for target in project['targets'].values():
 for source in target.get('sources',[]):
  path=source if isinstance(source,str) else source['path']
  if not (BASE/path).exists():missing.append(path)
if missing:raise ValueError('Missing project sources: '+repr(missing[:20]))
if a.prepare_only:
 print('Public resources and all selected source paths verified');sys.exit(0)
for script,args in [('build_psp.py',[]),('build_melonds.py',[]),('build_advanced.py',[]),('prepare_vulkan.py',[])]:
 run([sys.executable,BASE/'BuildSupport'/script,*args])
run([sys.executable,BASE/'BuildSupport/source_release/build_device_cores.py'])
for sdk in ['iphoneos','iphonesimulator']:
 run([sys.executable,BASE/'BuildSupport/commercial170/build.py','--sdk',sdk])
run([sys.executable,BASE/'BuildSupport/commercial170/integration.py'])
subprocess.run(['xcodegen','generate','--spec','project.json'],cwd=BASE,check=True)
print('Project prepared. Build VetaNative with your own signing configuration; see README.md.')
