#!/usr/bin/env python3
"""Build pinned, interpreter-only melonDS DS for Apple arm64 (no phone actions)."""
import argparse, json, os, plistlib, shutil, subprocess
from pathlib import Path
from source_snapshot import verify_snapshot
BASE = Path(__file__).resolve().parents[1]
LOCK = json.loads((BASE/'BuildSupport/melonds-ds.json').read_text())

def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)

def checkout(repo, commit, path, patch=None):
    if verify_snapshot(path, commit):
        return  # Snapshot already contains the recorded freeBIOS patch.
    if not (path/'.git').exists():
        path.mkdir(parents=True, exist_ok=True)
        run(['git','init',path]);run(['git','-C',path,'remote','add','origin',repo])
    current = subprocess.run(['git','-C',path,'rev-parse','HEAD'],capture_output=True,text=True)
    if current.returncode or current.stdout.strip()!=commit:
        run(['git','-C',path,'fetch','--depth','1','origin',commit]);run(['git','-C',path,'checkout','--detach',commit])
    dirty=subprocess.check_output(['git','-C',path,'status','--porcelain','--untracked-files=no'],text=True)
    if dirty.strip():
        actual=subprocess.check_output(['git','-C',path,'diff','--binary','HEAD'],text=True)
        if patch is None or actual.strip()!=patch.read_text().strip():
            raise RuntimeError(f'Source contains unreviewed modifications: {path}')
    elif patch is not None:
        run(['git','-C',path,'apply',patch.resolve()])

parser=argparse.ArgumentParser()
parser.add_argument('--source',type=Path)
parser.add_argument('--reuse-deps',type=Path)
parser.add_argument('--jobs',type=int,default=2)
args=parser.parse_args()
cache=BASE/'.build/melonds';cache.mkdir(parents=True,exist_ok=True)
source=args.source or cache/'source'
checkout(LOCK['frontend']['repo'],LOCK['frontend']['commit'],source)
deps=[]
for item in LOCK['dependencies']:
    path=(args.reuse_deps/(item['name']+'-src')) if args.reuse_deps else cache/'deps'/item['name']
    checkout(item['repo'],item['commit'],path,BASE/'BuildSupport/melonds-freebios.patch' if item['name']=='melonds' else None)
    key=item['name'].upper().replace('-','_')
    deps += [f'-DFETCHCONTENT_SOURCE_DIR_{key}={path.resolve()}',f'-D{key}_REPOSITORY_TAG={item["commit"]}']
frameworks=[]
for sdk,platform in [('iphonesimulator','SIMULATORARM64'),('iphoneos','OS64')]:
    build=cache/sdk
    cmd=['cmake','-S',source,'-B',build,f'-DCMAKE_TOOLCHAIN_FILE={source.resolve()}/cmake/toolchain/ios.toolchain.cmake',f'-DPLATFORM={platform}', '-DDEPLOYMENT_TARGET=17.0','-DCMAKE_BUILD_TYPE=Release','-DENABLE_JIT=OFF','-DENABLE_OPENGL=OFF','-DENABLE_NETWORKING=ON','-DBUILD_TESTING=OFF','-DBUILD_AS_SHARED_LIBRARY=ON',*deps]
    run(cmd);run(['cmake','--build',build,'--parallel',max(1,args.jobs)])
    framework=cache/sdk/'MelonDSCore.framework';framework.mkdir(exist_ok=True)
    executable=framework/'MelonDSCore';shutil.copy2(build/'src/libretro/melondsds_libretro.dylib',executable)
    run(['install_name_tool','-id','@rpath/MelonDSCore.framework/MelonDSCore',executable])
    with (framework/'Info.plist').open('wb') as out:
        plistlib.dump({'CFBundleExecutable':'MelonDSCore','CFBundleIdentifier':'com.krafify.veta.core.melonds','CFBundleName':'MelonDSCore','CFBundlePackageType':'FMWK','CFBundleShortVersionString':'1.4.0','CFBundleVersion':'2','MinimumOSVersion':'17.0','CFBundleSupportedPlatforms':['iPhoneSimulator' if sdk=='iphonesimulator' else 'iPhoneOS']},out)
    run(['codesign','--force','--sign','-',framework]);frameworks.append(framework)
output=BASE/'.build/MelonDSCore.xcframework'
if output.exists():shutil.rmtree(output)
run(['xcodebuild','-create-xcframework','-framework',frameworks[0],'-framework',frameworks[1],'-output',output])
notices=cache/'iphonesimulator/melondsds-LICENSE.txt'
if not notices.exists():
    candidates=list((cache/'iphonesimulator').rglob('melondsds-LICENSE.txt'))
    if not candidates:raise RuntimeError('Generated third-party license file missing')
    notices=candidates[0]
(BASE/'Content/MelonDS-LICENSE.txt').write_bytes(notices.read_bytes().rstrip()+b'\n')
(cache/'build-provenance.json').write_text(json.dumps({'pins':LOCK,'freeBIOSPatch':'melonds-freebios.patch','stateABI':'v2','jit':False,'opengl':False,'networkingCompiled':True,'runtimeNetworking':'disabled by VETA','framework':str(output)},indent=2)+'\n')
print(output)
