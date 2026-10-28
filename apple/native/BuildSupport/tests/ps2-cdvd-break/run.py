#!/usr/bin/env python3
"""Run real CDVDFSV RPC and state regression using an existing Mac Play reference build."""
import argparse,json,shlex,subprocess
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True,help='Play source to test')
p.add_argument('--base-source',type=Path,required=True,help='Play source originally used by the reference build')
p.add_argument('--build',type=Path,required=True,help='Mac CMake build containing play-gl-interactive link.txt')
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();S=a.source.resolve();R=a.base_source.resolve();B=a.build.resolve();O=a.out.resolve();O.mkdir(parents=True,exist_ok=False)
f=(B/'PlayCore/CMakeFiles/PlayCore.dir/flags.make').read_text();flags=[]
for key in ['CXX_DEFINES','CXX_INCLUDES','CXX_FLAGS']:
 flags+=shlex.split(next(line.split(' = ',1)[1] for line in f.splitlines() if line.startswith(key+' = ')))
flags=[x.replace(str(R),str(S)) for x in flags]
objects=[]
for name in ['Iop_Cdvdfsv.cpp','IopBios.cpp']:
 obj=O/(name+'.o');objects.append(str(obj))
 c=subprocess.run(['/usr/bin/c++',*flags,'-c',str(S/'Source/iop'/name),'-o',str(obj)],capture_output=True,text=True)
 (O/(name+'.build.log')).write_text(c.stdout+c.stderr)
 if c.returncode:raise SystemExit(c.returncode)
link=shlex.split((B/'CMakeFiles/play-gl-interactive.dir/link.txt').read_text());libs=link[link.index('PlayCore/libPlayCore.a'):]
libs=[str(B/x) if x.endswith('.a') and not x.startswith('/') else x for x in libs]
exe=O/'ps2-cdvd-break-regression'
c=subprocess.run(['/usr/bin/c++',*flags,str(Path(__file__).with_name('ps2-cdvd-break-regression.cpp')),*objects,'-o',str(exe),*libs],capture_output=True,text=True)
(O/'link.log').write_text(c.stdout+c.stderr)
if c.returncode:raise SystemExit(c.returncode)
r=subprocess.run([str(exe)],cwd=O,capture_output=True,text=True,timeout=30)
(O/'regression.log').write_text(r.stdout+r.stderr)
(O/'result.json').write_text(json.dumps({'exit_code':r.returncode,'pass_count':sum(x.startswith('PASS ') for x in r.stdout.splitlines()),'fail_count':sum(x.startswith('FAIL ') for x in r.stdout.splitlines())},indent=2)+'\n')
print(r.stdout,end='');raise SystemExit(r.returncode)
