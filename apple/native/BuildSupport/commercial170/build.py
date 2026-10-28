#!/usr/bin/env python3
"""Pinned commercial-use core candidates. GPL duties still apply to distribution."""
from pathlib import Path
import argparse, hashlib, json, os, plistlib, shutil, subprocess
from patch_jgenesis import apply
from patch_bsnes import apply as patch_bsnes

HERE = Path(__file__).resolve().parent
BASE = HERE.parents[1]
PINS = {
    'bsnes-commercial': ('libretro/bsnes-mercury', '79d7f9de218b6ffa65a80bbdc5828532bc239232'),
    'jgenesis-commercial': ('jsgroth/jgenesis', '0a00c47ba7a16bd6e77ef7e0b6c8fab2fc603cba'),
}

def checkout(name):
    repo, pin = PINS[name]
    path = BASE/'.build'/name
    if not path.exists():
        subprocess.run(['git','clone','https://github.com/'+repo+'.git',str(path)],check=True)
        subprocess.run(['git','checkout','--detach',pin],cwd=path,check=True)
    if (path/'.git').exists():
        actual = subprocess.check_output(['git','rev-parse','HEAD'],cwd=path,text=True).strip()
        assert actual == pin, (name,actual)
    else:
        # A corresponding-source archive intentionally excludes Git internals.
        manifest=json.loads((path/'VETA-SOURCE-PIN.json').read_text())
        assert manifest['repo']==repo and manifest['commit']==pin
        for relative,digest in manifest['files'].items():
            file=path/relative
            assert not Path(relative).is_absolute() and '..' not in Path(relative).parts
            assert hashlib.sha256(file.read_bytes()).hexdigest()==digest,relative
    return path

def framework(binary, name, output, sdk):
    path = output/(name+'.framework'); path.mkdir(parents=True,exist_ok=True)
    shutil.copy2(binary,path/name)
    subprocess.run(['install_name_tool','-id',f'@rpath/{name}.framework/{name}',str(path/name)],check=True)
    platform={'iphoneos':'iPhoneOS','iphonesimulator':'iPhoneSimulator','macosx':'MacOSX'}[sdk]
    info={'CFBundleIdentifier':'com.krafify.vetaretro.core.'+name.lower(),
          'CFBundleExecutable':name,'CFBundleName':name,'CFBundlePackageType':'FMWK',
          'CFBundleVersion':'170','CFBundleShortVersionString':'0.170.0',
          'CFBundleSupportedPlatforms':[platform],'MinimumOSVersion':'17.4' if sdk!='macosx' else '13.0'}
    (path/'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign','--force','--sign','-',str(path)],check=True)
    return {'framework':str(path),'sha256':hashlib.sha256((path/name).read_bytes()).hexdigest()}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk',choices=['macosx','iphoneos','iphonesimulator'],default='iphoneos')
    args=parser.parse_args(); sdk=args.sdk
    output=BASE/'.build/commercial170'/sdk; output.mkdir(parents=True,exist_ok=True)
    bsnes=checkout('bsnes-commercial'); sega=checkout('jgenesis-commercial'); apply(sega); patch_bsnes(bsnes)
    bsbuild=output/'bsnes-source'
    if not bsbuild.exists():
        shutil.copytree(bsnes,bsbuild,ignore=shutil.ignore_patterns('.git','*.o','*.dylib'))
    patch_bsnes(bsbuild)
    sdkpath=subprocess.check_output(['xcrun','--sdk',sdk,'--show-sdk-path'],text=True).strip()
    triple={'macosx':'arm64-apple-macos13.0','iphoneos':'arm64-apple-ios17.4','iphonesimulator':'arm64-apple-ios17.4-simulator'}[sdk]
    # Use upstream's cross-Apple path for all SDKs; each has its own objects.
    subprocess.run(['make','-j6','platform=osx','PROFILE=performance','CROSS_COMPILE=1',
                    'LIBRETRO_APPLE_PLATFORM='+triple,'LIBRETRO_APPLE_ISYSROOT='+sdkpath],cwd=bsbuild,check=True)
    cargo=Path.home()/'.cargo/bin/cargo'
    target={'macosx':'aarch64-apple-darwin','iphoneos':'aarch64-apple-ios','iphonesimulator':'aarch64-apple-ios-sim'}[sdk]
    env=dict(os.environ,IPHONEOS_DEPLOYMENT_TARGET='17.4',MACOSX_DEPLOYMENT_TARGET='13.0')
    rust=BASE/'.build/commercial170-rust'
    subprocess.run([str(cargo),'build','--locked','--release','--manifest-path',str(HERE/'sega/Cargo.toml'),
                    '--target',target,'--target-dir',str(rust)],env=env,check=True)
    products={
        'BSNESCore':framework(bsbuild/'bsnes_mercury_performance_libretro.dylib','BSNESCore',output,sdk),
        'JGenesisCore':framework(rust/target/'release/libveta_jgenesis_libretro.dylib','JGenesisCore',output,sdk),
    }
    source_hashes={str(p.relative_to(HERE)):hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in [HERE/'patch_jgenesis.py',HERE/'patch_bsnes.py',HERE/'sega/src/lib.rs',HERE/'sega/Cargo.toml',HERE/'sega/Cargo.lock']}
    source_hashes.update({str(p.relative_to(HERE)):hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in (HERE/'spc700-free').rglob('*') if p.is_file()})
    (output/'receipt.json').write_text(json.dumps({'sdk':sdk,'pins':PINS,'sources':source_hashes,'products':products},indent=2)+'\n')
    print(json.dumps(products,indent=2))

if __name__=='__main__': main()
