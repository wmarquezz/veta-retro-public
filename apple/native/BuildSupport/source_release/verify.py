#!/usr/bin/env python3
"""Independently verify every file in a source export, without executing its code."""
import argparse,hashlib,json
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();root=a.root.resolve()
data=json.loads((root/'SOURCE-MANIFEST.json').read_text());errors=[]
for name,entry in data['files'].items():
 rel=Path(name);path=root/rel
 if rel.is_absolute() or '..' in rel.parts or path.is_symlink() or not path.is_file():errors.append(name);continue
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 if h.hexdigest()!=entry['sha256'] or path.stat().st_size!=entry['bytes']:errors.append(name)
print(json.dumps({'files':len(data['files']),'errors':errors,'passed':not errors},indent=2))
raise SystemExit(bool(errors))
