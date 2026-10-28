#!/usr/bin/env python3
"""Build pinned libretro engines. Source checkouts and products remain local.

First run downloads the exact upstream commits and their pinned submodules;
subsequent builds use the cache. No BIOS or game files are downloaded here.
"""
from pathlib import Path
import argparse, hashlib, json, plistlib, shutil, subprocess
from runtime165 import recipe as runtime165
from patch_jit_cores import apply as patch_jit_cores
from source_snapshot import verify_snapshot
base=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--source-root',type=Path)
parser.add_argument('--recipe',choices=['legacy','runtime165'],default='legacy')
parser.add_argument('--dry-run',action='store_true',help='Verify existing runtime165 sources/patches without applying or building')
parser.add_argument('--only',nargs='*')
parser.add_argument('--sdk',choices=['iphoneos','iphonesimulator','both'],default='both')
args=parser.parse_args()
if args.recipe=='runtime165' and args.sdk!='iphoneos':parser.error('runtime165 currently certifies device source configuration only; pass --sdk iphoneos')
if args.dry_run and args.recipe!='runtime165':parser.error('--dry-run requires --recipe runtime165')
if args.recipe=='runtime165' and args.only and set(args.only)-set(runtime165.PINS['engines']):parser.error('runtime165 only supports dolphin-retro and mupen-next')
source_root=(args.source_root or base/'.build'/('runtime165/engine-sources' if args.recipe=='runtime165' else 'engine-sources')).resolve()
def run(command,**kwargs):subprocess.run(command,check=True,**kwargs)
for meta in json.loads((base/'BuildSupport/advanced-cores.json').read_text()):
    if args.only and meta['name'] not in args.only:continue
    if args.recipe=='runtime165' and meta['name'] not in runtime165.PINS['engines']:continue
    source=source_root/meta['name']
    if args.recipe=='runtime165':runtime165.verify_build_metadata(meta)
    if args.dry_run:
        print(json.dumps(runtime165.prepare(meta['name'],source,dry_run=True)))
        continue
    exported = args.recipe == 'legacy' and verify_snapshot(source, meta['commit'])
    if not exported and not (source/'.git').exists():
        if args.recipe=='runtime165' and source.exists() and any(source.iterdir()):
            raise RuntimeError('Refusing to initialize a nonempty source directory: '+str(source))
        source.mkdir(parents=True,exist_ok=True)
        run(['git','init',str(source)])
        run(['git','-C',str(source),'remote','add','origin','https://github.com/'+meta['repo']+'.git'])
        run(['git','-C',str(source),'fetch','--depth','1','origin',meta['commit']])
        run(['git','-C',str(source),'checkout','--detach','FETCH_HEAD'])
        # Mupen's pinned tree contains an unused gnulib gitlink but no .gitmodules.
        if (source/'.gitmodules').exists():
            run(['git','-C',str(source),'submodule','update','--init','--recursive','--depth','1'])
    actual=meta['commit'] if exported else subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    if actual!=meta['commit']:raise RuntimeError('Unexpected source revision for '+meta['name'])
    if args.recipe=='runtime165':
        recipe_meta=runtime165.metadata(meta['name'])
        if meta['commit']!=recipe_meta['commit'] or meta['repo']!=recipe_meta['repo']:
            raise RuntimeError('Advanced metadata differs from runtime165 pin')
        runtime165.prepare(meta['name'],source)
    else:
        # Upstream currently references optional GBPlayer symbols without its guard.
        if meta['name']=='dolphin-retro':
            path=source/'Source/Core/DolphinLibretro/Boot.cpp'
            text=path.read_text()
            start='  if (Libretro::GBPlayer_active)\n  {\n    Config::SetBase'
            end='  Discord::SetDiscordPresenceEnabled(false);'
            if start in text and '#ifdef HAS_LIBMGBA\n'+start not in text:
                text=text.replace(start,'#ifdef HAS_LIBMGBA\n'+start,1)
                text=text.replace(end,'#endif\n'+end,1)
                path.write_text(text)
        if meta['name'] in ['play','dolphin-retro']:
            patch=base/'BuildSupport'/('play-save-directory.patch' if meta['name']=='play' else 'dolphin-system-directory.patch')
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='dolphin-retro':
            patch=base/'BuildSupport/dolphin-software-frontend.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='dolphin-retro':
            patch=base/'BuildSupport/dolphin-ios-buffer-stream.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='dolphin-retro':
            patch=base/'BuildSupport/dolphin-state-result.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='dolphin-retro':
            patch=base/'BuildSupport/dolphin-ios-depth-readback.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='mupen-next':
            patch=base/'BuildSupport/n64-audio-registers.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='play':
            patch=base/'BuildSupport/play-audio-batches.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        patch_jit_cores(meta['name'],source)
        if meta['name']=='play':
            patch=base/'BuildSupport/play-state-synchronization.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='play':
            patch=base/'BuildSupport/play-clean-vblank.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
        if meta['name']=='play':
            patch=base/'BuildSupport/play-cdvd-break-error.patch'
            check=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
            if check.returncode:run(['git','-C',str(source),'apply',str(patch)])
    cmake_source=source
    if meta['name']=='mupen-next':
        manifest=json.loads((base/'BuildSupport/mupen-next.json').read_text())['build']
        cmake_source=base/'.build'/('runtime165/mupen-cmake' if args.recipe=='runtime165' else 'mupen-cmake');cmake_source.mkdir(parents=True,exist_ok=True)
        def paths(key):return ' '.join(json.dumps(str(source/f)) for f in manifest[key])
        definitions=' '.join(json.dumps(d) for d in manifest['defines'])
        (cmake_source/'CMakeLists.txt').write_text('\n'.join([
            'cmake_minimum_required(VERSION 3.18)', 'project(VetaN64 LANGUAGES C CXX ASM)',
            'set(CMAKE_C_STANDARD 11)', 'set(CMAKE_CXX_STANDARD 17)',
            'set(N64_SOURCES '+paths('sources')+')',
            'if(NOT VETA_SIMULATOR)',
            'list(FILTER N64_SOURCES EXCLUDE REGEX "mupen64plus-rsp-paraLLEl")',
            'endif()',
            'add_library(N64NextCore SHARED ${N64_SOURCES})',
            'if(VETA_SIMULATOR)',
            'target_compile_definitions(N64NextCore PRIVATE HAVE_PARALLEL_RSP PARALLEL_INTEGRATION)',
            'endif()',
            'target_include_directories(N64NextCore PRIVATE '+paths('headers')+')',
            'target_compile_definitions(N64NextCore PRIVATE '+definitions+')',
            'target_compile_options(N64NextCore PRIVATE -fno-strict-aliasing -Wno-error=implicit-function-declaration "SHELL:-include math.h" "SHELL:-include stdio.h")',
            'target_link_libraries(N64NextCore PRIVATE z "-framework Foundation" "-framework OpenGLES" "-framework AudioToolbox")',
            'set_target_properties(N64NextCore PROPERTIES PREFIX "")',
            'set_source_files_properties('+json.dumps(str(source/'mupen64plus-rsp-paraLLEl/lightning/lib/lightning.c'))+' PROPERTIES COMPILE_DEFINITIONS "HAVE_MMAP=1")']))
    products=[]
    for sdk,folder,platform in [('iphoneos','device','iPhoneOS'),('iphonesimulator','simulator','iPhoneSimulator')]:
        if args.sdk!='both' and sdk!=args.sdk:continue
        build=Path.home()/'Library/Developer/Xcode/DerivedData'/meta['cache']/('runtime165/'+folder if args.recipe=='runtime165' else folder)
        run(['cmake','-S',str(cmake_source),'-B',str(build),'-DCMAKE_OSX_SYSROOT='+sdk]+meta['flags']+(runtime165.metadata(meta['name'])['extraFlags'] if args.recipe=='runtime165' else [])+(['-DVETA_SIMULATOR='+('ON' if sdk=='iphonesimulator' else 'OFF')] if meta['name']=='mupen-next' else []))
        run(['cmake','--build',str(build),'--target',meta['target'],'-j','8'])
        name=meta['framework'];framework=build/(name+'.framework');framework.mkdir(exist_ok=True)
        shutil.copyfile(build/meta['artifact'],framework/name)
        run(['install_name_tool','-id','@rpath/'+framework.name+'/'+name,str(framework/name)])
        (framework/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=runtime165.metadata(meta['name'])['bundleIdentifier'] if args.recipe=='runtime165' else 'com.krafify.vetaretro.core.'+meta['name'],CFBundleName=name,CFBundleExecutable=name,CFBundlePackageType='FMWK',CFBundleVersion='1',CFBundleShortVersionString='1.0',CFBundleSupportedPlatforms=[platform],MinimumOSVersion='16.4')))
        if args.recipe=='runtime165':
            runtime165.verify_checkout(meta['name'],source)
            abi=runtime165.verify_binary(meta['name'],framework/name)
            destination=base/'.build/runtime165'/sdk/framework.name
            destination.parent.mkdir(parents=True,exist_ok=True)
            # Only this recipe's generated canonical product is replaced.
            if destination.exists():shutil.rmtree(destination)
            shutil.copytree(framework,destination)
            binary=destination/name
            receipt={'recipe':'runtime165','engine':meta['name'],'commit':meta['commit'],
                     'patchSHA256':runtime165.metadata(meta['name'])['patchSHA256'],
                     'framework':str(destination),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
                     'sdk':sdk,'abi':abi,'flags':meta['flags']+runtime165.metadata(meta['name'])['extraFlags'],
                     'compiler':subprocess.check_output(['xcrun','clang','--version'],text=True),
                     'uuid':subprocess.check_output(['dwarfdump','--uuid',str(binary)],text=True).strip(),
                     'dependencies':subprocess.check_output(['otool','-L',str(binary)],text=True),
                     'deviceTest':'NOT_RUN','referenceBinaryEquality':'NOT_CLAIMED'}
            (destination.parent/(name+'-recipe.json')).write_text(json.dumps(receipt,indent=2)+'\n')
        products+=['-framework',str(framework)]
    if args.sdk=='both':
        output=base/'.build'/(meta['framework']+'.xcframework')
        if output.exists():shutil.rmtree(output)
        run(['xcodebuild','-create-xcframework']+products+['-output',str(output)])
        run(['xattr','-cr',str(output)])
