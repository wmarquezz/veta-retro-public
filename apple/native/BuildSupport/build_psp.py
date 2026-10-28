#!/usr/bin/env python3
"""Build PPSSPP + FFmpeg from pinned offline sources for both Apple arm64 SDKs."""
from pathlib import Path
import hashlib,json,tarfile,subprocess,shutil,plistlib,os
from patch_ppsspp_jit_policy import apply as apply_jit_policy
base=Path(__file__).resolve().parents[1];repo=base.parents[1]
meta=json.loads((base/'BuildSupport/ppsspp.json').read_text());archive=repo/'vendor/native'/meta['archive']
assert hashlib.sha256(archive.read_bytes()).hexdigest()==meta['sha256']
source=base/'.build/ppsspp';stamp=source/'.veta-source'
if not stamp.exists() or stamp.read_text()!=meta['sha256']:
    source.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive) as tar:
        for member in tar:
            member.name='/'.join(member.name.split('/')[1:])
            if not member.name:continue
            assert not member.name.startswith('/') and '..' not in Path(member.name).parts and not member.issym() and not member.islnk()
            tar.extract(member,source)
    stamp.write_text(meta['sha256'])
(source/'assets/debugger').mkdir(parents=True,exist_ok=True) # Debugger web UI is not used or bundled in VETA.
# Cancellation may arrive while the asynchronous disc/firmware loader is still
# running. Drain it before the frontend destroys GL: FinishPendingBoot creates
# GPU resources and cannot safely run after context_destroy.
frontend=source/'libretro/libretro.cpp'
text=frontend.read_text()
hook='''extern "C" __attribute__((visibility("default"))) void veta_prepare_unload(void) {
   if (Libretro::useEmuThread) Libretro::EmuThreadStop();
   Libretro::FinishPendingBoot();
}

'''
if 'void veta_prepare_unload(void)' not in text:
    anchor='void retro_unload_game(void) {'
    assert anchor in text
    text=text.replace(anchor,hook+anchor,1)
# A save/load call must leave the emulation thread at the captured boundary.
# retro_run already resumes a paused thread. Resuming here lets the guest run
# ahead while the frontend writes a save or prepares the next frame.
for start,end in [('bool retro_serialize(void *data, size_t size)', 'bool retro_unserialize('),('bool retro_unserialize(', 'void *retro_get_memory_data(')]:
    begin=text.index(start);finish=text.index(end,begin+len(start));section=text[begin:finish]
    section=section.replace('   if (useEmuThread)\n      EmuThreadStart();\n','   // Resume only on the next retro_run, not during frontend state I/O.\n')
    text=text[:begin]+section+text[finish:]
frontend.write_text(text)
# PPSSPP exposes guest RAM to debuggers, but it is not cartridge battery RAM.
# Returning its size for SAVE_RAM made the frontend write a useless 32/64 MB
# battery file on the UI thread every 30 seconds (get_memory_data rejects it).
text=frontend.read_text()
old='''size_t retro_get_memory_size(unsigned id)
{
\tif (Memory::IsActive())'''
new='''size_t retro_get_memory_size(unsigned id)
{
\tif (id == RETRO_MEMORY_SYSTEM_RAM && Memory::IsActive())'''
if new not in text:
    assert old in text
    frontend.write_text(text.replace(old,new,1))
exports=source/'libretro/libretro.osx.def'
text=exports.read_text()
if '_veta_prepare_unload' not in text:exports.write_text(text.rstrip()+'\n_veta_prepare_unload\n')
apply_jit_policy(source)
output=base/'.build/PSPCore.xcframework'
key=hashlib.sha256(Path(__file__).read_bytes()+(base/'BuildSupport/patch_ppsspp_jit_policy.py').read_bytes()+archive.name.encode()+meta['sha256'].encode()+subprocess.check_output(['xcodebuild','-version'])).hexdigest()
if (output/'.veta-build').exists() and (output/'.veta-build').read_text()==key:raise SystemExit(0)
cache=Path.home()/'Library/Developer/Xcode/DerivedData/VetaPSPBuild';frameworks=[]
for sdk,platform in [('iphoneos','iPhoneOS'),('iphonesimulator','iPhoneSimulator')]:
    build=cache/sdk;build.mkdir(parents=True,exist_ok=True)
    # Keep source provenance independent of the surrounding VETA Git checkout.
    (build/'git-version.cpp').write_text('const char *PPSSPP_GIT_VERSION = "'+meta['commit']+'";\n#define PPSSPP_GIT_VERSION_NO_UPDATE 1\n')
    flags=['-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_SYSROOT='+sdk,'-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET=16.4','-DFORCED_CPU=arm64','-DCMAKE_SYSTEM_PROCESSOR=arm64','-DIOS=ON','-DIOS_APP_STORE=ON','-DLIBRETRO=ON','-DUSING_GLES2=ON','-DHEADLESS=OFF','-DUNITTEST=OFF','-DUSE_DISCORD=OFF','-DUSE_FFMPEG=ON','-DBUILD_BUNDLED_FFMPEG=ON','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_C_FLAGS=-D_DARWIN_C_SOURCE -DMOBILE_DEVICE','-DCMAKE_CXX_FLAGS=-D_DARWIN_C_SOURCE -DMOBILE_DEVICE','-DOPENGL_LIBRARIES=-framework OpenGLES;-framework GLKit;-framework Foundation;-framework UIKit;-framework CoreText;-framework QuartzCore']
    subprocess.run(['cmake','-S',str(source),'-B',str(build),'-G','Unix Makefiles']+flags,check=True)
    subprocess.run(['cmake','--build',str(build),'--target','ppsspp_libretro','-j',str(min(8,os.cpu_count() or 4))],check=True)
    framework=build/'PSPCore.framework';framework.mkdir(exist_ok=True)
    shutil.copy2(build/'lib/ppsspp_libretro.dylib',framework/'PSPCore')
    subprocess.run(['install_name_tool','-id','@rpath/PSPCore.framework/PSPCore',str(framework/'PSPCore')],check=True)
    (framework/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.krafify.vetaretro.core.psp','CFBundleName':'PSPCore','CFBundleExecutable':'PSPCore','CFBundlePackageType':'FMWK','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundleSupportedPlatforms':[platform],'MinimumOSVersion':'16.4'}))
    frameworks += ['-framework',str(framework)]
if output.exists():shutil.rmtree(output)
subprocess.run(['xcodebuild','-create-xcframework']+frameworks+['-output',str(output)],check=True)
subprocess.run(['xattr','-cr',str(output)],check=True)
(output/'.veta-build').write_text(key)
