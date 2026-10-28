#!/usr/bin/env python3
"""Rebuild the exact exported local-device engine sources; no JIT activation."""
import json,plistlib,shutil,subprocess,sys
from pathlib import Path
BASE=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(BASE/'BuildSupport'))
from source_snapshot import verify_snapshot
for item in json.loads((Path(__file__).parent/'device-cores.json').read_text()):
 source=BASE/item['source']
 if not verify_snapshot(source,item['commit']):raise ValueError('Use the complete corresponding-source archive')
 build=BASE/'.build/public-device-build'/item['engine'];build.mkdir(parents=True,exist_ok=True)
 cmake_source=source
 if item['engine']=='mupen-next':
  cmake_source=build/'cmake';cmake_source.mkdir(exist_ok=True)
  (cmake_source/'CMakeLists.txt').write_text((Path(__file__).parent/'N64-CMakeLists.txt').read_text())
 subprocess.run(['cmake','-S',str(cmake_source),'-B',str(build/'build'),'-DCMAKE_OSX_SYSROOT=iphoneos','-DVETA_ENGINE_SOURCE='+str(source),'-DVETA_SIMULATOR=OFF',*item['flags']],check=True)
 subprocess.run(['cmake','--build',str(build/'build'),'--target',item['target'],'-j','4'],check=True)
 name=item['framework'];fw=BASE/'.build/public-device'/(name+'.framework');fw.mkdir(parents=True,exist_ok=True)
 shutil.copyfile(build/'build'/item['artifact'],fw/name)
 subprocess.run(['install_name_tool','-id','@rpath/'+fw.name+'/'+name,str(fw/name)],check=True)
 (fw/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.krafify.vetaretro.core.'+item['engine'],'CFBundleName':name,'CFBundleExecutable':name,'CFBundlePackageType':'FMWK','CFBundleVersion':'179','CFBundleShortVersionString':'1.0','CFBundleSupportedPlatforms':['iPhoneOS'],'MinimumOSVersion':item['minimum']}))
print('Local iOS device engines rebuilt; no physical gameplay claim')
