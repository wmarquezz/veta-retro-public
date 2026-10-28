#!/usr/bin/env python3
"""Relink existing built objects in isolation; run XCTest without app launch service.
Requires a completed build-for-testing log. Never modifies the Xcode product.
No UIApplicationMain means system scene behaviors (idle timer, windows, AX) are
not established by a passing component test. Failures are never filtered.
"""
import argparse
import os
import pathlib
import re
import shlex
import signal
import subprocess

p=argparse.ArgumentParser()
p.add_argument('--build-log',type=pathlib.Path,required=True)
p.add_argument('--app',required=True)
p.add_argument('--test',required=True)
p.add_argument('--class-name',nargs='+',required=True)
p.add_argument('--timeout',type=float,default=120)
p.add_argument('--fixtures',nargs='*',type=pathlib.Path,default=[])
p.add_argument('--fixture-directory',type=pathlib.Path)
p.add_argument('--documents-fixture',nargs=2,action='append',default=[],metavar=('RELATIVE_DESTINATION','SOURCE'))
p.add_argument('--method',nargs='+',default=[])
p.add_argument('--simulator',required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[3]
lines=a.build_log.read_text().splitlines()
if '** TEST BUILD SUCCEEDED **' not in '\n'.join(lines):raise SystemExit('A successful build-for-testing log is required')
def link_line(name):
 return next(shlex.split(x) for x in lines if '/usr/bin/clang' in x and name+'.LinkFileList' in x)
app_args=link_line(a.app);test_args=link_line(a.test)
source=pathlib.Path(app_args[app_args.index('-o')+1]).parent
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
copy=out/source.name
if copy.exists():raise SystemExit('Use a fresh output directory to preserve earlier evidence')
subprocess.run(['cp','-cR',str(source),str(copy)],check=True)
lib=copy/'Frameworks/libVetaJITLabHeadless.dylib'
def rewrite(args,destination,library=False):
 result=[];i=0
 while i<len(args):
  if args[i] in ('-o','-bundle_loader'):i+=2;continue
  if args[i:i+2] in (['-Xlinker','-object_path_lto'],['-Xlinker','-dependency_info']):i+=4;continue
  result.append(args[i]);i+=1
 result+=['-o',str(destination)]
 result+=['-dynamiclib','-install_name','@rpath/libVetaJITLabHeadless.dylib'] if library else [str(lib)]
 return result
subprocess.run(rewrite(app_args,lib,True),cwd=repo/'apple/native',check=True)
subprocess.run(rewrite(test_args,copy/f'PlugIns/{a.test}.xctest/{a.test}'),cwd=repo/'apple/native',check=True)
developer=pathlib.Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
platform=developer/'Platforms/iPhoneSimulator.platform/Developer'
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
cmd=['xcrun','--sdk','iphonesimulator','swiftc','-target','arm64-apple-ios17.0-simulator','-sdk',sdk,'-F',str(platform/'Library/Frameworks'),'-I',str(platform/'usr/lib'),'-L',str(platform/'usr/lib')]
for path in (platform/'Library/Frameworks',platform/'Library/PrivateFrameworks',platform/'usr/lib','@executable_path/Frameworks'):
 cmd+=['-Xlinker','-rpath','-Xlinker',str(path)]
cmd += [str(pathlib.Path(__file__).with_name('headless_xctest_runner.swift')),'-o',str(copy/a.app)]
subprocess.run(cmd,check=True)
# Relinking invalidates the copied product's original signatures. Recent
# Simulator runtimes enforce signatures even for these isolated test libraries.
for artifact in (*sorted((copy/'Frameworks').glob('*.framework')),lib,copy/f'PlugIns/{a.test}.xctest',copy):
 subprocess.run(['codesign','--force','--sign','-',str(artifact)],check=True)
home=out/'Home';documents=home/'Documents/EngineFixtures';documents.parent.mkdir(parents=True)
if a.fixture_directory:
 if not a.fixture_directory.is_dir():raise SystemExit('Missing fixture directory')
 subprocess.run(['cp','-cR',str(a.fixture_directory),str(documents)],check=True)
else:documents.mkdir()
for fixture in a.fixtures:
 if not fixture.is_file():raise SystemExit(f'Missing fixture: {fixture}')
 destination=documents/fixture.name
 if destination.exists():raise SystemExit(f'Duplicate fixture: {fixture.name}')
 subprocess.run(['cp','-c',str(fixture),str(destination)],check=True)
for relative,origin in a.documents_fixture:
 relative=pathlib.Path(relative);origin=pathlib.Path(origin)
 if relative.is_absolute() or '..' in relative.parts or not origin.is_file():raise SystemExit('Invalid documents fixture')
 destination=home/'Documents'/relative
 if destination.exists():raise SystemExit(f'Duplicate documents fixture: {relative}')
 destination.parent.mkdir(parents=True,exist_ok=True)
 subprocess.run(['cp','-c',str(origin),str(destination)],check=True)
environment=dict(os.environ,SIMCTL_CHILD_CFFIXED_USER_HOME=str(home),SIMCTL_CHILD_VETA_HEADLESS_HOME=str(home),SIMCTL_CHILD_VETA_HEADLESS_METHODS='\n'.join(a.method))
with (out/'result.log').open('w') as log:
 try:
  run=subprocess.run(['xcrun','simctl','spawn',a.simulator,str(copy/a.app),a.test,*a.class_name],stdout=log,stderr=subprocess.STDOUT,timeout=a.timeout,env=environment)
 except (subprocess.TimeoutExpired,KeyboardInterrupt):
  # simctl's lifetime is not the simulator child's lifetime. Stop only the
  # exact executable we cloned for this run; never leave a timed-out core live.
  content=(out/'result.log').read_text()
  identity=re.search(r'HEADLESS_PID (\d+)',content)
  if identity:
   pid=int(identity[1])
   command=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True)
   if command.stdout.startswith(str(copy/a.app)+' '):
    try:os.kill(pid,signal.SIGKILL)
    except ProcessLookupError:pass
  print(content)
  raise
text=(out/'result.log').read_text();print(text)
match=re.search(r'HEADLESS_XCTEST executed=(\d+) failures=(\d+)',text)
raise SystemExit(0 if run.returncode==0 and match and int(match[1])>0 and int(match[2])==0 else 1)
