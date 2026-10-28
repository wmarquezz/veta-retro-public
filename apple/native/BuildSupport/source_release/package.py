#!/usr/bin/env python3
"""Create a deterministic archive only after checking its complete file manifest."""
import argparse,gzip,hashlib,json,tarfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',required=True,type=Path);p.add_argument('--output',required=True,type=Path);a=p.parse_args();root=a.root.resolve()
manifest=json.loads((root/'SOURCE-MANIFEST.json').read_text())
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
actual={f.relative_to(root).as_posix() for f in root.rglob('*') if f.is_file()}
if actual!=set(manifest['files'])|{'SOURCE-MANIFEST.json'}:raise ValueError('Unexpected/missing file in source staging')
for name,entry in manifest['files'].items():
 path=root/name
 if path.is_symlink() or Path(name).is_absolute() or '..' in Path(name).parts or path.stat().st_size!=entry['bytes'] or sha(path)!=entry['sha256']:raise ValueError('Changed source: '+name)
with a.output.open('xb') as raw,gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0,compresslevel=6) as gz:
 with tarfile.open(fileobj=gz,mode='w') as archive:
  for name in sorted(actual):
   path=root/name;member=tarfile.TarInfo('veta-public-source/'+name);member.size=path.stat().st_size;member.mode=0o755 if path.stat().st_mode&0o111 else 0o644
   with path.open('rb') as f:archive.addfile(member,f)
print(json.dumps({'sha256':sha(a.output),'bytes':a.output.stat().st_size,'files':len(actual),'published':False},indent=2))
