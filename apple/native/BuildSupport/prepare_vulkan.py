#!/usr/bin/env python3
"""Stage the official MoltenVK 1.4.2 iOS/Simulator runtime with SHA-256 checks.

Only the two Apple mobile SDK slices and the Apache-2.0 notice are extracted.
No private-API macOS build is used. Downloads are cached for offline rebuilds.
"""
from pathlib import Path
import hashlib,plistlib,shutil,tarfile,urllib.request
base=Path(__file__).resolve().parents[1]
archive=base/'.build/MoltenVK-all-1.4.2.tar'
url='https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-all.tar'
digest='562a15a29bc358446a56a4091c5f7e08f604184187c1d34f712148b61ef17276'
expected={'ios-arm64':'6cd5888490d08b36356d04c50c05e2eda5b9bcb3d0338ece693a28987de96aff','ios-arm64_x86_64-simulator':'c6027cfbc343e9595cd8b072aab9f587cde4f8f0a52ad6159dd5794769592e1d'}
destination=base/'.build/MoltenVK.xcframework'
notice=base/'Content/MoltenVKLicense.txt'
def verified(root):
 return all((path:=root/sdk/'MoltenVK.framework/MoltenVK').is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==sha for sdk,sha in expected.items())
if not verified(destination) or not notice.exists():
 if not archive.exists():
  download=archive.with_suffix('.download')
  urllib.request.urlretrieve(url,download)
  if hashlib.sha256(download.read_bytes()).hexdigest()!=digest:raise SystemExit('MoltenVK archive checksum mismatch')
  download.rename(archive)
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=digest:raise SystemExit('MoltenVK archive checksum mismatch')
 temporary=destination.with_suffix('.staging')
 if temporary.exists():shutil.rmtree(temporary)
 temporary.mkdir()
 prefix='MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/'
 with tarfile.open(archive) as bundle:
  for member in bundle.getmembers():
   if not member.name.startswith(prefix):continue
   relative=Path(member.name[len(prefix):])
   if not relative.parts or (relative.parts[0] not in expected and relative.as_posix()!='Info.plist'):continue
   if relative.is_absolute() or '..' in relative.parts or not (member.isfile() or member.isdir()):raise SystemExit('Unsafe MoltenVK archive entry')
   target=temporary/relative
   if member.isdir():target.mkdir(parents=True,exist_ok=True)
   else:
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes(bundle.extractfile(member).read())
  license=bundle.extractfile('MoltenVK/LICENSE').read().decode()
 info=plistlib.loads((temporary/'Info.plist').read_bytes())
 info['AvailableLibraries']=[x for x in info['AvailableLibraries'] if x['LibraryIdentifier'] in expected]
 (temporary/'Info.plist').write_bytes(plistlib.dumps(info))
 if not verified(temporary):raise SystemExit('MoltenVK SDK binary checksum mismatch')
 if destination.exists():shutil.rmtree(destination)
 temporary.rename(destination)
 notice.write_text('MoltenVK 1.4.2 — Vulkan over Apple Metal\nhttps://github.com/KhronosGroup/MoltenVK/releases/tag/v1.4.2\n\n'+license)
print('MoltenVK 1.4.2 device and Simulator binaries verified')
