"""Package pinned interpreter-only compatibility cores and register their notices."""
from pathlib import Path
import json, subprocess, shutil, tarfile, hashlib
CORES={'supergrafx':'SuperGrafxCore','gearsystem':'GearsystemCore','sameboy':'SameBoyCore'}
def apply(project,base):
 base=Path(base)
 for target in project['targets'].values():
  if target.get('type')!='application':continue
  deps=target.setdefault('dependencies',[])
  for key,name in CORES.items():
   path=base/'.build'/key/(name+'.xcframework')
   if not any(Path(d.get('framework','')).name==path.name for d in deps):deps.append({'framework':str(path),'embed':True,'link':False,'codeSign':True})
def package(base):
 base=Path(base)
 for key,name in CORES.items():
  root=base/'.build'/key;args=[]
  for sdk in ['iphoneos','iphonesimulator']:
   fw=root/sdk/(name+'.framework');receipt=json.loads((root/sdk/'receipt.json').read_text());assert hashlib.sha256((fw/name).read_bytes()).hexdigest()==receipt['binarySHA256'];args+=['-framework',str(fw)]
  dest=root/(name+'.xcframework')
  if dest.exists():shutil.rmtree(dest)
  subprocess.run(['xcodebuild','-create-xcframework',*args,'-output',str(dest)],check=True)
def notices(base):
 base=Path(base);root=base.parents[1];parts=[];extra_notices=[]
 for key,name in CORES.items():
  pin=json.loads((base/'BuildSupport'/(key+'.json')).read_text());parts.append(f"\n{name}\nhttps://github.com/{pin['repo']}\nCommit: {pin['commit']}\n{pin['license']}\n")
  with tarfile.open(root/'vendor/native'/pin['archive'])as t:
   for m in t:
    if m.isfile() and Path(m.name).name.lower().startswith(('license','copying','copyright','notice')):
     raw=t.extractfile(m).read()
     parts.append('\n--- '+m.name+' ---\n'+raw.decode('utf-8',errors='replace'))
     extra_notices.append({'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw),'origins':['vendor/native/'+pin['archive']+'!/'+m.name]})
 text='\n'.join(parts)
 for name in ['EngineLicenses.txt','ThirdPartyNotices.txt']:
  p=base/'Content'/name;s=p.read_text();marker='\nVETA CARTRIDGE COMPATIBILITY CORES 211\n';s=s.split(marker)[0];p.write_text(s+marker+text+'\n')
 index=base/'Publication/rights/THIRD-PARTY-NOTICES.json'
 record=json.loads(index.read_text());groups={row['sha256']:row for row in record['notices']}
 for row in extra_notices:
  existing=groups.setdefault(row['sha256'],dict(row,origins=[]))
  existing['origins']=sorted(set(existing['origins']+row['origins']))
 record['notices']=sorted(groups.values(),key=lambda row:row['sha256'])
 record['uniqueTexts']=len(groups)
 record['sourceNoticeFiles']=sum(len(row['origins']) for row in groups.values())
 record['outputSHA256']=hashlib.sha256((base/'Content/ThirdPartyNotices.txt').read_bytes()).hexdigest()
 index.write_text(json.dumps(record,indent=2)+'\n')
if __name__=='__main__':
 import argparse
 p=argparse.ArgumentParser();p.add_argument('--notices-only',action='store_true');a=p.parse_args();base=Path(__file__).resolve().parents[1]
 if not a.notices_only:package(base)
 notices(base)
