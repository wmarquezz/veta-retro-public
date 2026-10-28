#!/usr/bin/env python3
"""Collect exact upstream notices from a reviewed corresponding-source export.

This is an attribution inventory, not a license compatibility determination.
The superset includes dependencies and tools present in the source export;
listing them does not imply that every component is linked into the app.
"""
import argparse,hashlib,json,re,tarfile
from pathlib import Path

def is_notice(name):
    path=Path(name)
    return (any(p.lower()=='licenses' for p in path.parts[:-1]) or
            bool(re.fullmatch(r'(?:licen[sc]e|copying|copyright|notice|ofl)(?:[._-].*)?',path.name,re.I)))

def collect(root):
    groups={}
    def add(origin,data):
        if not data or b'\0' in data:return
        digest=hashlib.sha256(data).hexdigest()
        row=groups.setdefault(digest,{'sha256':digest,'bytes':len(data),'origins':[],'data':data})
        row['origins'].append(origin)
    for path in sorted(root.rglob('*')):
        if not path.is_file() or path.is_symlink():continue
        rel=path.relative_to(root).as_posix()
        if rel.startswith(('apple/native/Publication/rights/','apple/native/Content/')):continue
        if is_notice(rel):add(rel,path.read_bytes())
        if rel.startswith('vendor/native/') and path.name.endswith('.tar.gz'):
            with tarfile.open(path) as archive:
                for member in archive:
                    if member.isfile() and is_notice(member.name):
                        if member.size>4*1024*1024:raise ValueError('Oversized notice: '+member.name)
                        add(rel+'!/'+member.name,archive.extractfile(member).read())
    if not groups:raise ValueError('No source notices found')
    return sorted(groups.values(),key=lambda row:sorted(row['origins'])[0])

def generate(root,output,index):
    groups=collect(root)
    sections=['VETA Retro — Third-party notices / Avisos de terceros\n\n'
              'Textos originales de los motores, dependencias y herramientas del paquete de fuentes.\n'
              'Es un inventario ampliado: no afirma que todas las herramientas se enlacen en la app.\n'
              'Cada tercero conserva sus términos. La GPL de VETA no sustituye estas licencias.\n']
    for row in groups:
        sections.append('\n'+'='*72+'\n'+'\n'.join(sorted(row['origins']))+'\nSHA-256: '+row['sha256']+'\n\n')
        data=row.pop('data')
        try:text=data.decode('utf-8')
        except UnicodeDecodeError:text=data.decode('latin-1')
        sections.append(text+'\n')
    output.parent.mkdir(parents=True,exist_ok=True);output.write_text(''.join(sections))
    record={'schema':1,'scope':'upstream notice superset, not link graph or legal clearance','uniqueTexts':len(groups),
            'sourceNoticeFiles':sum(len(row['origins']) for row in groups),'outputSHA256':hashlib.sha256(output.read_bytes()).hexdigest(),'notices':groups}
    index.parent.mkdir(parents=True,exist_ok=True);index.write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({key:record[key] for key in ['uniqueTexts','sourceNoticeFiles','outputSHA256']}))
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('--output',type=Path,required=True);p.add_argument('--index',type=Path,required=True);a=p.parse_args();generate(a.source,a.output,a.index)
