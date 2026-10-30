#!/usr/bin/env python3
"""Synchronize public app versions from Publication/version.json; never edit history."""
import argparse,json,plistlib,re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--write',action='store_true');args=p.parse_args()
 release=json.loads((root/'Publication/version.json').read_text());version=release['version'];build=str(release['build'])
 if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version) or not build.isdecimal() or int(build)<1:raise ValueError('Invalid version/build')
 project=json.loads((root/'project.json').read_text());target=project['targets']['VetaNative'];info=plistlib.loads((root/'Info.plist').read_bytes())
 changes=[]
 for values,keys,label in [(project['settings']['base'],['MARKETING_VERSION','CURRENT_PROJECT_VERSION'],'project'),(target['settings']['base'],['MARKETING_VERSION','CURRENT_PROJECT_VERSION'],'target'),(target['info']['properties'],['CFBundleShortVersionString','CFBundleVersion'],'generated Info'),(info,['CFBundleShortVersionString','CFBundleVersion'],'Info.plist')]:
  for key,value in zip(keys,[version,build]):
   if str(values.get(key))!=value:changes.append(label+': '+key);values[key]=value
 if args.write:
  (root/'project.json').write_text(json.dumps(project,indent=2)+'\n');(root/'Info.plist').write_bytes(plistlib.dumps(info,sort_keys=False))
 elif changes:raise ValueError('Version drift: '+', '.join(changes))
 print(json.dumps({'version':version,'build':build,'channel':release['channel'],'synchronized':not changes or args.write}))
if __name__=='__main__':main()
