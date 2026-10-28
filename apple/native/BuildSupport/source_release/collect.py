#!/usr/bin/env python3
"""Collect exact local public-build inputs; no Git history, credentials or phone data.

The private mapping contains checkout locations. Output records only portable paths,
upstream identities, source hashes and local changes. This does not publish anything.
"""
import argparse, gzip, hashlib, io, json, os, re, shutil, subprocess, tarfile
from pathlib import Path
NATIVE=Path(__file__).resolve().parents[2]
ROOT=NATIVE.parents[1]
DENIED={'.git','.DS_Store','__pycache__','Secrets','local-secrets'}
BINARY={'.o','.obj','.a','.lib','.dll','.dylib','.exe','.pdb','.ipa'}
def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def safe(name):
 p=Path(name)
 if p.is_absolute() or '..' in p.parts or set(p.parts)&DENIED:raise ValueError('Unsafe export path: '+name)
 return p

def copy_file(source,destination):
 destination.parent.mkdir(parents=True,exist_ok=True)
 shutil.copyfile(source,destination)
 destination.chmod(0o755 if source.stat().st_mode&0o111 else 0o644)

def snapshot(item,root):
 src=Path(item['source']).resolve(); dest=root/safe(item['destination'])
 actual=subprocess.check_output(['git','-C',str(src),'rev-parse','HEAD'],text=True).strip()
 if actual!=item['commit']:raise ValueError('Unexpected commit: '+item['name'])
 names=subprocess.check_output(['git','-C',str(src),'ls-files','--recurse-submodules','-z']).decode().split('\0')
 names += item.get('extraSourceFiles', [])
 hashes={};omitted=[];symlinks=[]
 for name in sorted(set(names)-{''}):
  path=src/safe(name)
  if not path.is_file():
   omitted.append({'path':name,'reason':'not a regular tracked file (gitlink or removed source)' });continue
  if path.suffix.lower() in BINARY:
   omitted.append({'path':name,'reason':'prebuilt artifact; source build uses the supplied source trees'});continue
  if path.is_symlink():
   if src not in path.resolve().parents:raise ValueError('External symlink: '+name)
   symlinks.append({'path':name,'target':os.readlink(path)})
  copy_file(path,dest/name);hashes[name]=sha(dest/name)
 patch=subprocess.check_output(['git','-C',str(src),'diff','--binary','HEAD'])
 if patch:
  target=root/'source-evidence/patches'/(item['name']+'.patch');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(patch)
 record={k:item[k] for k in ['name','repo','commit','destination']}
 record.update(files=hashes,omitted=omitted,materializedSymlinks=symlinks,
               submodules=subprocess.run(['git','-C',str(src),'submodule','status','--recursive'],capture_output=True,text=True).stdout.splitlines())
 (dest/'VETA-SOURCE-PIN.json').write_text(json.dumps(record,indent=2)+'\n')
 print(item['name'],len(hashes),'source files',flush=True)
 return {k:v for k,v in record.items() if k!='files'}|{'fileCount':len(hashes)}

def extract_checked(archive,dest):
 with tarfile.open(archive) as tar:
  for member in tar:
   rel=safe(member.name)
   if member.isdir():continue
   if not member.isfile():raise ValueError('Non-regular source archive member: '+member.name)
   out=dest/rel;out.parent.mkdir(parents=True,exist_ok=True)
   with tar.extractfile(member) as inp,out.open('wb') as output:shutil.copyfileobj(inp,output)
   out.chmod(0o755 if member.mode&0o111 else 0o644)

def collect(mapping,dest):
 if dest.exists():raise ValueError('Output must be new')
 dest.mkdir(parents=True)
 policy=json.loads((NATIVE/'Publication/source-review-files.json').read_text())
 entries=set(policy['files'])
 # Current source-release helpers are themselves corresponding source.
 for folder in ['BuildSupport/source_release','BuildSupport/thirdparty-notices/ppsspp']:
  entries.update(p.relative_to(ROOT).as_posix() for p in (NATIVE/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
 entries.add('apple/native/BuildSupport/source_snapshot.py')
 for name in sorted(entries):
  path=ROOT/safe(name)
  if path.is_symlink():raise ValueError('Own source symlink')
  data=path.read_bytes()
  if path.suffix not in ['.png','.zim','.meta','.ttf','.otf'] and any(re.search(p,data) for p in [rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',rb'\b(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}',rb'/' + rb'Users/[^/\s]+/']):
   raise ValueError('Review private-data pattern: '+name)
  copy_file(path,dest/name)
 # Core170 contains exact patched source, Rust vendor graph and source manifests.
 core=NATIVE/'.build/commercial170/commercial170-core-sources.tar.gz'
 if sha(core)!='6eaa6d805cd101c462705972e2d2e622fbbc303e2b76b9f9829e8022fa10966f':raise ValueError('Changed core170 source archive')
 extract_checked(core,dest)
 # Retain CURRENT adapters and source instructions over the historical snapshot.
 for path in (NATIVE/'BuildSupport/commercial170').rglob('*'):
  if path.is_file() and '__pycache__' not in path.parts:copy_file(path,dest/path.relative_to(ROOT))
 # Original basic-core archives, used by pinned extraction/build recipes.
 archives=['fceumm-ac0d00a.tar.gz','mgba-0.10.5.tar.gz','ppsspp-31e94fcf.tar.gz']
 archives += [e['archive'] for e in json.loads((NATIVE/'BuildSupport/extra-cores.json').read_text()) if e['name'] not in ('genesis','stella')]
 archives.append(json.loads((NATIVE/'BuildSupport/tia.json').read_text())['archive'])
 for name in archives:
  if name!='ppsspp-31e94fcf.tar.gz':copy_file(ROOT/'vendor/native'/name,dest/'vendor/native'/name)
 extras=json.loads((dest/'apple/native/BuildSupport/extra-cores.json').read_text())
 (dest/'apple/native/BuildSupport/extra-cores.json').write_text(json.dumps([e for e in extras if e['name'] not in ('genesis','stella')],indent=2)+'\n')
 # Do not redistribute the old atlas binaries whose font inputs were unclear.
 # Preserve the code and recipes; public resources contain the new OFL outputs.
 psp=json.loads((NATIVE/'BuildSupport/ppsspp.json').read_text())
 original=ROOT/'vendor/native'/psp['archive']
 if sha(original)!=psp['sha256']:raise ValueError('Changed original PPSSPP archive')
 old_sha=psp['sha256'];new_name='ppsspp-31e94fcf-veta-free-atlases.tar.gz'
 output=dest/'vendor/native'/new_name;removed=[]
 with output.open('wb') as raw,gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0) as gz:
  with tarfile.open(fileobj=gz,mode='w') as out,tarfile.open(original) as inp:
   for member in sorted(inp.getmembers(),key=lambda m:m.name):
    safe(member.name)
    if Path(member.name).name in {n+'_atlas.'+ext for n in ['font','asciifont','ppge'] for ext in ['meta','zim']}:
     removed.append(member.name);continue
    if not (member.isfile() or member.isdir()):raise ValueError('Unsafe upstream archive entry')
    member.uid=member.gid=member.mtime=0;member.uname=member.gname=''
    out.addfile(member,inp.extractfile(member) if member.isfile() else None)
 if len(removed)!=6:raise ValueError('Unexpected upstream atlas inventory')
 psp.update(archive=new_name,sha256=sha(output),sourceArchiveOriginalSHA256=old_sha,removedGeneratedAtlases=removed)
 (dest/'apple/native/BuildSupport/ppsspp.json').write_text(json.dumps(psp,indent=2)+'\n')
 components=[snapshot(item,dest) for item in mapping['trees'] if item['name'] != 'play']
 advanced=dest/'apple/native/BuildSupport/advanced-cores.json'
 advanced.write_text(json.dumps([x for x in json.loads(advanced.read_text()) if x['name'] != 'play'],indent=2)+'\n')
 # Public staging is independently validated before inclusion; only 2 MIT games.
 import sys
 sys.path.insert(0,str(NATIVE/'BuildSupport'))
 import public_games
 staged=public_games.stage()
 if public_games.audit(staged):raise ValueError('Public resource audit failed')
 shutil.copytree(staged/'Content',dest/'apple/native/Content',dirs_exist_ok=True)
 copy_file(staged/'DiscoveryCatalog.json',dest/'apple/native/Sources/DiscoveryCatalog.json')
 # Frozen project instead of legacy prepare.py, which also prepares a private catalog.
 project=json.loads((NATIVE/'project.json').read_text())
 def portable(value):
  if isinstance(value,str):return value.replace(str(NATIVE)+'/', '')
  if isinstance(value,list):return [portable(v) for v in value]
  if isinstance(value,dict):return {k:portable(v) for k,v in value.items()}
  return value
 project=portable(project)
 # Physical UI tests depend on a private game library and are not app sources.
 project['targets'].pop('VetaNativeUITests',None)
 for scheme in project.get('schemes',{}).values():
  if 'test' in scheme:scheme['test']['targets']=[x for x in scheme['test'].get('targets',[]) if x!='VetaNativeUITests']
 (dest/'apple/native/project.json').write_text(json.dumps(project,indent=2)+'\n')
 for item in mapping.get('files',[]):copy_file(Path(item['source']),dest/safe(item['destination']))
 evidence=dest/'source-evidence';evidence.mkdir(exist_ok=True)
 (evidence/'COMPONENTS.json').write_text(json.dumps(components,indent=2)+'\n')
 notices=[p.relative_to(dest).as_posix() for p in dest.rglob('*') if p.is_file() and any(term in p.name.lower() for term in ['license','copying','copyright','notice'])]
 (evidence/'NOTICE-INDEX.json').write_text(json.dumps(sorted(notices),indent=2)+'\n')
 copy_file(NATIVE/'BuildSupport/source_release/README.md',dest/'README.md')
 # Paths, sizes and SHA-256 cover every exported file, including nested notices.
 files={p.relative_to(dest).as_posix():{'sha256':sha(p),'bytes':p.stat().st_size} for p in sorted(dest.rglob('*')) if p.is_file()}
 manifest={'schema':1,'scope':'public-native-source-candidate','published':False,'ownCodeLicense':'GPL-3.0-or-later', 'files':files}
 (dest/'SOURCE-MANIFEST.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print(json.dumps({'files':len(files),'bytes':sum(x['bytes'] for x in files.values()),'components':len(components),'notices':len(notices)}))

if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--mapping',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
 a=p.parse_args();collect(json.loads(a.mapping.read_text()),a.output.resolve())
