"""Rebuild pinned SuperGrafx sources with repeat-load cleanup; no ROM downloads."""
from pathlib import Path
import argparse,json,hashlib,tarfile,subprocess,plistlib,shutil
BASE=Path(__file__).resolve().parents[1];ROOT=BASE.parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--sdk',choices=['iphoneos','iphonesimulator','macosx'],default='iphoneos');a=p.parse_args();sdk=a.sdk
 pin=json.loads((BASE/'BuildSupport/supergrafx.json').read_text());archive=ROOT/'vendor/native'/pin['archive'];assert hashlib.sha256(archive.read_bytes()).hexdigest()==pin['sha256']
 out=BASE/'.build/supergrafx'/sdk;source=out/'source';source.mkdir(parents=True,exist_ok=True)
 with tarfile.open(archive)as t:
  for m in t:
   assert not Path(m.name).is_absolute() and '..'not in Path(m.name).parts and (m.isfile()or m.isdir())
   if m.isdir():(source/m.name).mkdir(parents=True,exist_ok=True)
   else:
    dest=source/m.name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(t.extractfile(m).read())
 f=source/'libretro.cpp';s=f.read_text();s=s.replace('   last_pixel_format = MDFN_PixelFormat();','   last_pixel_format = MDFN_PixelFormat();\n   last_sound_rate = 0; // Initialize the newly loaded PSG.');s=s.replace('   MDFNGameInfo = NULL;\n\n   for (unsigned i = 0; i < CDInterfaces.size(); i++)','   MDFNGameInfo = NULL;\n   if (surf) { free(surf->pixels16); surf->pixels16 = NULL; delete surf; surf = NULL; }\n\n   for (unsigned i = 0; i < CDInterfaces.size(); i++)');f.write_text(s)
 sysroot=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip();triple={'iphoneos':'arm64-apple-ios17.4','iphonesimulator':'arm64-apple-ios17.4-simulator','macosx':'arm64-apple-macos13.0'}[sdk]
 subprocess.run(['make','-j6','platform=osx','CROSS_COMPILE=1','LIBRETRO_APPLE_PLATFORM='+triple,'LIBRETRO_APPLE_ISYSROOT='+sysroot],cwd=source,check=True)
 name='SuperGrafxCore';fw=out/(name+'.framework');fw.mkdir(exist_ok=True);shutil.copyfile(source/'mednafen_supergrafx_libretro.dylib',fw/name)
 subprocess.run(['install_name_tool','-id','@rpath/'+fw.name+'/'+name,str(fw/name)],check=True)
 (fw/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.krafify.vetaretro.core.supergrafx','CFBundleExecutable':name,'CFBundleName':name,'CFBundlePackageType':'FMWK','CFBundleVersion':'211','CFBundleShortVersionString':'1.0','CFBundleSupportedPlatforms':[{'iphoneos':'iPhoneOS','iphonesimulator':'iPhoneSimulator','macosx':'MacOSX'}[sdk]],'MinimumOSVersion':'17.4'if sdk!='macosx'else'13.0'}))
 subprocess.run(['codesign','--force','--sign','-',str(fw)],check=True)
 (out/'receipt.json').write_text(json.dumps({'source':pin,'sdk':sdk,'binarySHA256':hashlib.sha256((fw/name).read_bytes()).hexdigest()},indent=2))
if __name__=='__main__':main()
