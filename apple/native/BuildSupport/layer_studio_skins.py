#!/usr/bin/env python3
"""Add lossless editable layers to all retained Estudio packages.
The composite PNG is deliberately unchanged, so pre-layer user edits can be recovered.
"""
from pathlib import Path
import base64,copy,json,subprocess,tempfile,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1];NS='http://www.w3.org/2000/svg';ET.register_namespace('',NS)
def tag(n):return '{'+NS+'}'+n
def png(svg,work):
 (work/'layer.svg').write_bytes(ET.tostring(svg))
 subprocess.run(['node',str(ROOT/'BuildSupport/skin_export/render_svg.cjs'),str(work/'layer.svg'),str(work/'layer.png')],check=True)
 return base64.b64encode((work/'layer.png').read_bytes()).decode()
with tempfile.TemporaryDirectory() as tmp:
 work=Path(tmp)
 for path in sorted((ROOT/'Sources/Resources').glob('studio-*.vetaskin')):
  skin=json.loads(path.read_text())
  for v in skin['variants']:
   layout=v['layout'];folder='vertical' if layout['orientation']=='portrait' else 'horizontal'
   source=ROOT/'Content/StudioSkins'/skin['console']/folder
   svg=ET.parse(source/'control-runtime.svg').getroot()
   size=json.loads((source/'integracion.json').read_text())['logicalCanvas'];w,h=size
   background=copy.deepcopy(svg)
   for child in list(background):
    if child.get('id','').startswith('input-') or child.tag==tag('text'):background.remove(child)
   bg=png(background,work);sprites={}
   for c in layout['controls']:
    x,y,cw,ch=c['x']*w,c['y']*h,c['width']*w,c['height']*h
    part=ET.Element(tag('svg'),width=str(round(cw*3)),height=str(round(ch*3)),viewBox=f'{x} {y} {cw} {ch}')
    for child in svg:
     if child.tag==tag('defs') or child.get('id')=='input-'+c['id'] or (child.tag==tag('text') and abs(float(child.get('x','-999'))-(x+cw/2))<.01 and abs(float(child.get('y','-999'))-(y+ch/2))<.01):part.append(copy.deepcopy(child))
    sprites[c['id']]=png(part,work)
   v['artwork']={'layout':copy.deepcopy(layout),'backgroundPNG':bg,'controlsPNG':sprites}
  path.write_text(json.dumps(skin,ensure_ascii=False,separators=(',',':')))
  print(path.name,flush=True)
