"""Replace both restricted cores in public and integrated project generation."""
from pathlib import Path
import hashlib, json, subprocess

OLD={'Snes9x','GenesisCore','libSnes9x.a','GenesisCore.framework'}
NEW=('BSNESCore','JGenesisCore')

def apply(project,base):
    base=Path(base)
    for name in ('Snes9x','GenesisCore'):
        project['targets'].pop(name,None)
    for target in project['targets'].values():
        dependencies=target.get('dependencies',[])
        target['dependencies']=[dep for dep in dependencies if dep.get('target') not in OLD and
            Path(dep.get('framework','')).name not in OLD]
        if target.get('type') not in ('application','bundle.unit-test','bundle.ui-testing'): continue
        # These packaged slices are built for iOS 17.4. Do not advertise an
        # older deployment target for a new app that embeds them.
        settings=target.setdefault('settings',{}).setdefault('base',{})
        current=settings.get('IPHONEOS_DEPLOYMENT_TARGET',project.get('settings',{}).get('base',{}).get('IPHONEOS_DEPLOYMENT_TARGET','16.4'))
        if tuple(map(int,str(current).split('.'))) < (17,4):
            settings['IPHONEOS_DEPLOYMENT_TARGET']='17.4'
        if target.get('type')!='application': continue
        for name in NEW:
            path=base/'.build/commercial170'/(name+'.xcframework')
            if not path.is_dir():
                raise ValueError(f'Build both commercial170 iPhone SDKs and package XCFrameworks first: {path}')
            if not any(Path(dep.get('framework','')).name==path.name for dep in target['dependencies']):
                target['dependencies'].append({'framework':str(path),'embed':True,'link':False,'codeSign':True})

def package(base):
    base=Path(base); root=base/'.build/commercial170'
    for name in NEW:
        args=[]
        for sdk in ('iphoneos','iphonesimulator'):
            receipt=json.loads((root/sdk/'receipt.json').read_text())['products'][name]
            path=Path(receipt['framework'])
            assert hashlib.sha256((path/name).read_bytes()).hexdigest()==receipt['sha256']
            args.extend(['-framework',str(path)])
        destination=root/(name+'.xcframework')
        # Only replace generated package; source slices remain independently pinned.
        import shutil
        if destination.exists(): shutil.rmtree(destination)
        subprocess.run(['xcodebuild','-create-xcframework',*args,'-output',str(destination)],check=True)

if __name__=='__main__': package(Path(__file__).resolve().parents[2])
