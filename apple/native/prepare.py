#!/usr/bin/env python3
"""Pinned native source preparation (downloads advanced cores on first run). Run before xcodegen/build."""
from pathlib import Path
import hashlib, tarfile, json, subprocess, shutil
base=Path(__file__).resolve().parent
repo=base.parent.parent
archive=repo/'vendor/native/fceumm-ac0d00a.tar.gz'
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='6d9664deb1223c079ffa982e664a89485932761cd8655609a9b2039699434612'
core=base/'.build/fceumm'
core.mkdir(parents=True,exist_ok=True)
with tarfile.open(archive) as f:
    assert all(not m.name.startswith('/') and '..' not in Path(m.name).parts and not m.issym() and not m.islnk() for m in f.getmembers())
    f.extractall(core)
from BuildSupport.patch_nes_lifecycle import apply as patch_nes_lifecycle
patch_nes_lifecycle(core)
make='CORE_DIR := src\nHAVE_NTSC := 0\nHAVE_HDPACK := 0\nSTATIC_LINKING := 0\ninclude Makefile.common\nprint:\n\t@echo $(SOURCES_C)\n'
sources=subprocess.check_output(['make','-s','-f','-','print'],input=make.encode(),cwd=core).decode().split()
includes=['src','src/input','src/boards','src/drivers/libretro','src/drivers/libretro/libretro-common/include']
# Official, unmodified source archives; extracted without links/path traversal.
for name, version, digest in [('mgba','0.10.5','9475c26e9fa2f4b30c07ab6636e4b0a5b62e4baee2109ede7b2fecc52edae366')]:
    source=repo/f'vendor/native/{name}-{version}.tar.gz'
    assert hashlib.sha256(source.read_bytes()).hexdigest()==digest
    destination=base/'.build'/name
    with tarfile.open(source) as archive:
        for member in archive.getmembers():
            member.name='/'.join(member.name.split('/')[1:])
            if not member.name: continue
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts and not member.issym() and not member.islnk()
            archive.extract(member,destination)
from BuildSupport.patch_mgba_lifecycle import apply as patch_mgba_lifecycle
patch_mgba_lifecycle(base/'.build/mgba')
from BuildSupport.patch_mgba_rocket import apply as patch_mgba_rocket
patch_mgba_rocket(base/'.build/mgba')
resources=base/'Content'
for game in ['thwaite','croom','akanoid-gb','sushi-gb','gluf-gbc','space-game','gold-rush','sushi-sms','sushi-gg','berta','akanoid-gg','gluf-sms']:
    dest=resources/game
    dest.mkdir(exist_ok=True)
    for f in (repo/'os/ui/public/free-games'/game).iterdir():
        if f.is_file(): shutil.copy2(f,dest/f.name)
shutil.copy2(core/'Copying',resources/'FCEUmm-COPYING.txt')
info={'CFBundleDisplayName':'VETA-Retro','CFBundleShortVersionString':'0.147.0','CFBundleVersion':'147',
      'UIAppFonts':['Content/Fonts/BarlowCondensed-Bold.ttf','Content/Fonts/Manrope.ttf'],'UILaunchScreen':{},'UIFileSharingEnabled':True,'LSSupportsOpeningDocumentsInPlace':True,
      'CADisableMinimumFrameDurationOnPhone':True,
      'NSLocalNetworkUsageDescription':'VETA conecta controles y jugadores cercanos en tu red local.',
      'NSBonjourServices':['_veta-play._tcp','_veta-play._udp'],
      'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':True,'UISceneConfigurations':{'UIWindowSceneSessionRoleExternalDisplayNonInteractive':[{'UISceneConfigurationName':'VETA TV','UISceneClassName':'UIWindowScene','UISceneDelegateClassName':'$(PRODUCT_MODULE_NAME).VetaExternalSceneDelegate'}]}},
      'CFBundleDevelopmentRegion':'es','CFBundleLocalizations':['es','en','zh-Hans','hi','ar','fr','de','it'],
      'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],
      'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']}
project={'name':'VetaNative','options':{'deploymentTarget':{'iOS':'16.4'}},
 'settings':{'base':{'SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'1,2','IPHONEOS_DEPLOYMENT_TARGET':'16.4','ENABLE_USER_SCRIPT_SANDBOXING':'YES'}},
 'targets':{
  'FCEUmm':{'type':'library.static','platform':'iOS','sources':[{'path':'.build/fceumm/'+f} for f in sources],
   'settings':{'base':{'HEADER_SEARCH_PATHS':['$(SRCROOT)/.build/fceumm/'+f for f in includes],
    'GCC_PREPROCESSOR_DEFINITIONS':['__LIBRETRO__','FRONTEND_SUPPORTS_RGB888','FCEU_VERSION_NUMERIC=9900'],
    'GCC_OPTIMIZATION_LEVEL':'2','GCC_C_LANGUAGE_STANDARD':'gnu11','GCC_WARN_INHIBIT_ALL_WARNINGS':'YES','SKIP_INSTALL':'YES'}}},
  'VetaNative':{'type':'application','platform':'iOS','sources':[{'path':'Sources','excludes':['NextGen']},{'path':'Content','type':'folder','buildPhase':'resources'}],
   'dependencies':[{'target':'FCEUmm'},{'sdk':'MetalKit.framework'},{'sdk':'OpenGLES.framework'},{'sdk':'AVFoundation.framework'},{'sdk':'GameController.framework'},{'sdk':'CoreHaptics.framework'},{'sdk':'GameKit.framework'},{'sdk':'AVKit.framework'},{'sdk':'MultipeerConnectivity.framework'},{'sdk':'libc++.tbd'}],
   'info':{'path':'Info.plist','properties':info},
   'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'com.krafify.vetaretro','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','SWIFT_OBJC_BRIDGING_HEADER':'Sources/VetaNative-Bridging-Header.h',
    'HEADER_SEARCH_PATHS':['$(SRCROOT)/.build/fceumm/src/drivers/libretro/libretro-common/include','$(SRCROOT)/.build/engine-sources/azahar/externals/vulkan-headers/include','$(SRCROOT)/.build/engine-sources/azahar/externals/libretro-common/libretro-common/include'], 'CLANG_CXX_LANGUAGE_STANDARD':'gnu++17', 'CODE_SIGN_STYLE':'Automatic','GCC_PREPROCESSOR_DEFINITIONS':['$(inherited)'], 'GCC_OPTIMIZATION_LEVEL':'2', 'SWIFT_OPTIMIZATION_LEVEL':'-O'}}},
  'VetaNativeTests':{'type':'bundle.unit-test','platform':'iOS','sources':[{'path':'Tests','excludes':['play_audio_test.cpp']}],'dependencies':[{'target':'VetaNative'}],
   'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'com.krafify.vetaretro.tests','GENERATE_INFOPLIST_FILE':'YES','SWIFT_OBJC_BRIDGING_HEADER':'Sources/VetaNative-Bridging-Header.h'}}},
  'VetaNativeUITests':{'type':'bundle.ui-testing','platform':'iOS','sources':['UITests'],'dependencies':[{'target':'VetaNative'}],
   'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'com.krafify.vetaretro.uitests','GENERATE_INFOPLIST_FILE':'YES'}}}},
 'schemes':{'VetaNative':{'build':{'targets':{'VetaNative':'all'}},'test':{'targets':['VetaNativeTests','VetaNativeUITests']}}}}
symbols=json.loads((base/'BuildSupport/retro-symbols.json').read_text())+json.loads((base/'BuildSupport/shared-symbols.json').read_text())
mgba=json.loads((base/'BuildSupport/mgba.json').read_text())
for target,prefix,files,headers,defines in [
 ('mGBA','mgba',mgba['sources'],['BuildSupport/mgba/include','.build/mgba/src','.build/mgba/include'],mgba['defines'])]:
    project['targets'][target]={'type':'library.static','platform':'iOS','sources':[{'path':f} for f in files],
      'settings':{'base':{'HEADER_SEARCH_PATHS':['$(SRCROOT)/'+f for f in headers],
        'GCC_PREPROCESSOR_DEFINITIONS':defines+[f'{symbol}={prefix}_{symbol}' for symbol in symbols],
        'GCC_OPTIMIZATION_LEVEL':'2','GCC_C_LANGUAGE_STANDARD':'gnu11','CLANG_CXX_LANGUAGE_STANDARD':'gnu++17','GCC_WARN_INHIBIT_ALL_WARNINGS':'YES','SKIP_INSTALL':'YES'}}}
    project['targets']['VetaNative']['dependencies'].append({'target':target})
shutil.copy2(base/'.build/mgba/LICENSE',resources/'mGBA-LICENSE.txt')
# New engines are isolated in embedded, signed frameworks. They ship in the app;
# no executable code is downloaded, and their global C symbols cannot collide.
for item in json.loads((base/'BuildSupport/extra-cores.json').read_text()):
    if item['name']=='genesis': continue  # Replaced by commercial170 jgenesis.
    source=repo/'vendor/native'/item['archive']
    assert hashlib.sha256(source.read_bytes()).hexdigest()==item['sha256']
    destination=base/'.build'/item['name']
    with tarfile.open(source) as archive:
        for member in archive.getmembers():
            member.name='/'.join(member.name.split('/')[1:])
            if not member.name:continue
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts and not member.issym() and not member.islnk()
            archive.extract(member,destination)
    if item['name']=='pcsx': (destination/'include/revision.h').write_text('#define REV "'+item['commit'][:8]+'"\n')
    if item['name']=='desmume':
        from BuildSupport.patch_ds_lifecycle import apply as patch_ds_lifecycle
        patch_ds_lifecycle(destination)
    if item['name']=='genesis':
        from BuildSupport.patch_genesis_state import patch_genesis_state
        patch_genesis_state(destination)
    build=item['build'];target=build['target'];prefix='.build/'+item['name']+'/'
    project['targets'][target]={'type':'framework','platform':'iOS','sources':[{'path':prefix+f} for f in build['sources']],
      'dependencies':[{'sdk':'libz.tbd'},{'sdk':'libc++.tbd'}],
      'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'com.krafify.vetaretro.core.'+item['name'],
        'GENERATE_INFOPLIST_FILE':'YES','DEFINES_MODULE':'NO','SKIP_INSTALL':'YES','DEAD_CODE_STRIPPING':'NO',
        'GCC_SYMBOLS_PRIVATE_EXTERN':'NO','CLANG_ENABLE_MODULES':'NO','CLANG_CXX_LANGUAGE_STANDARD':'gnu++17',
        'GCC_C_LANGUAGE_STANDARD':'gnu11','GCC_OPTIMIZATION_LEVEL':'2','GCC_WARN_INHIBIT_ALL_WARNINGS':'YES',
        'OTHER_CFLAGS':['-fno-strict-aliasing'],'OTHER_CPLUSPLUSFLAGS':['-fno-strict-aliasing'],
        'HEADER_SEARCH_PATHS':['$(SRCROOT)/'+prefix+f for f in build['headers']],
        'GCC_PREPROCESSOR_DEFINITIONS':[value.replace(' ','\\ ') for value in build['defines']]}}}
    project['targets']['VetaNative']['dependencies'].append({'target':target,'embed':True,'link':False,'codeSign':True})
# PSP keeps its upstream CMake build, including FFmpeg and all pinned submodules.
subprocess.run(['python3',str(base/'BuildSupport/build_psp.py')],check=True)
project['targets']['VetaNative']['dependencies'].append({'framework':'.build/PSPCore.xcframework','embed':True,'link':False,'codeSign':True})
pspAssets=resources/'PPSSPP'
if pspAssets.exists():shutil.rmtree(pspAssets)
shutil.copytree(base/'.build/ppsspp/assets',pspAssets,ignore=shutil.ignore_patterns('debugger'))
shutil.copytree(base/'BuildSupport/thirdparty-notices/ppsspp',pspAssets/'VETA-Font-Notices',dirs_exist_ok=True)
# Optional DS interpreter keeps states separate from the original DeSmuME engine.
subprocess.run(['python3',str(base/'BuildSupport/build_melonds.py')],check=True)
project['targets']['VetaNative']['dependencies'].append({'framework':'.build/MelonDSCore.xcframework','embed':True,'link':False,'codeSign':True})
# Advanced engines use pinned source/submodules and narrow compatibility patches.
subprocess.run(['python3',str(base/'BuildSupport/build_advanced.py')],check=True)
subprocess.run(['python3',str(base/'BuildSupport/prepare_vulkan.py')],check=True)
project['targets']['VetaNative']['dependencies'].append({'framework':'.build/MoltenVK.xcframework','embed':True,'link':True,'codeSign':True})
for engine in json.loads((base/'BuildSupport/advanced-cores.json').read_text()):
    project['targets']['VetaNative']['dependencies'].append({'framework':'.build/'+engine['framework']+'.xcframework','embed':True,'link':False,'codeSign':True})
dolphinAssets=resources/'DolphinSys'
if dolphinAssets.exists():shutil.rmtree(dolphinAssets)
shutil.copytree(base/'.build/engine-sources/dolphin-retro/Data/Sys',dolphinAssets)
subprocess.run(['python3',str(base/'BuildSupport/write_extra_credits.py')],check=True)
from BuildSupport.commercial170.integration import apply as apply_commercial_cores
apply_commercial_cores(project,base)
from BuildSupport.cartridge_compatibility import apply as apply_cartridge_cores, notices as cartridge_notices
apply_cartridge_cores(project,base)
cartridge_notices(base)
from BuildSupport.public_games import apply as apply_public_games
apply_public_games(project,base)
(base/'project.json').write_text(json.dumps(project,indent=2)+'\n')
subprocess.run(['xcodegen','generate','--spec','project.json'],cwd=base,check=True)
print('Native core pinned ac0d00a; '+str(len(sources))+' C files; no web runtime.')
