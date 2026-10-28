#!/usr/bin/env python3
"""Rebuild the 38 bundled skins from their retained SVGs, with playable controls.

No downloaded art, source ZIP scripts, or user-installed packages are modified.
Requires Node and @resvg/resvg-js (VETA_RESVG_MODULE may select a local install).
"""
from pathlib import Path
import base64,copy,json,os,subprocess,tempfile,xml.etree.ElementTree as ET,hashlib
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Content/StudioSkins'
NS='http://www.w3.org/2000/svg';ET.register_namespace('',NS)
def tag(n):return '{'+NS+'}'+n
def element(n,**attrs):return ET.Element(tag(n),{k.replace('_','-'):str(v) for k,v in attrs.items()})
def targets(console,folder,layout,size):
 w,h=size
 old={c['id']:[c['x']*w,c['y']*h,c['width']*w,c['height']*h] for c in layout['controls']};d=copy.deepcopy(old)
 def put(k,x,y,a,b=None):
  if k in d:d[k]=[x,y,a,a if b is None else b]
 if folder=='horizontal':
  # Keep edge anchoring and a clear center; all art remains fully opaque.
  for k in ('SELECT','START','HOME','+','−'): 
   if k in d:d[k][1]=272;d[k][3]=48
  if 'X' in d and 'Y' in d and console not in ('megaDrive','saturn','gamecube'):
   for k,x,y in [('X',710,124),('Y',648,186),('A',772,186),('B',710,248)]:put(k,x,y,60)
   if console=='dreamcast':d['A'],d['B'],d['X'],d['Y']=d['B'],d['A'],d['Y'],d['X']
  if 'stick0' in d:
   top,bottom=('stick0','dpad') if console in ('dreamcast','gamecube','threeDS') else ('dpad','stick0')
   put(top,16,60,108);put(bottom,12,200,112)
  if console in ('megaDrive','saturn'):
   for row,keys in enumerate([['X','Y','Z'],['A','B','C']]):
    for col,k in enumerate(keys):put(k,644+64*col,188+64*row,60)
  if console=='n64':
   for k,x,y in [('C↑',726,52),('C←',670,108),('C→',782,108),('C↓',726,164)]:put(k,x,y,52)
  if console=='nes':put('dpad',24,92,152)
  if console=='gamecube':put('B',658,214,52);put('Y',714,101,64,48)
  if console=='wii':
   put('−',310,272,48,48);put('+',486,272,48,48)
   for row,keys in enumerate([['A','B'],['1','2']]):
    for col,k in enumerate(keys):put(k,702+64*col,62+62*row,60)
  return d
 # Portrait groups use available controller space, never the game viewport.
 for k in ('L','R','L2','R2','C','Z','SHAKE'):
  if k in d and old[k][1]<10:d[k][3]=48;d[k][1]=2
 for k in ('SELECT','START','HOME','+','−','A+B'):
  if k in d:d[k][3]=48;d[k][1]=min(d[k][1],h-50)
 if console=='threeDS':
  put('stick0',24,50,96);put('dpad',26,148,88);put('SELECT',132,138,56,48);put('START',132,190,56,48)
  return d
 if console=='ds':
  put('dpad',12,60,112)
  put('SELECT',140,72,60,48);put('START',140,130,60,48)
  for k,x,y in [('X',286,52),('Y',230,94),('A',342,94),('B',286,136)]:put(k,x,y,48)
  return d
 put('dpad',16,60,144)
 put('SELECT',116,h-50,64,48);put('START',188,h-50,64,48);put('A+B',324,h-50,60,48)
 if console in ('nes','gb','gbc','gba','gameGear','masterSystem','pcEngine','atari2600'):
  put('B',220,108,76);put('A',308,108 if console in ('nes','masterSystem','pcEngine') else 78,76)
 elif console in ('megaDrive','saturn'):
  for row,keys in enumerate([['X','Y','Z'],['A','B','C']]):
   for col,k in enumerate(keys):put(k,216+60*col,100+60*row,54)
 elif console in ('snes','ps1'):
  for k,x,y in [('X',270,54),('Y',208,116),('A',332,116),('B',270,178)]:put(k,x,y,58)
 else:
  top,bottom=('stick0','dpad') if console in ('dreamcast','gamecube') else ('dpad','stick0')
  put(top,18,56,112);put(bottom,18,182,112)
  put('SELECT',140,218,60,48);put('START',168,270,64,48)
  for k,x,y in [('X',270,54),('Y',206,118),('A',334,118),('B',270,182)]:put(k,x,y,60)
  if console=='dreamcast':d['A'],d['B'],d['X'],d['Y']=d['B'],d['A'],d['Y'],d['X']
  if console=='n64':
   for k,x,y in [('C↑',286,54),('C←',232,108),('C→',340,108),('C↓',286,162)]:put(k,x,y,50)
   put('B',236,220,64);put('A',312,220,64);put('START',160,270,64,48)
  if console=='gamecube':
   put('A',280,110,66);put('B',216,174,56);put('X',350,110,48,66);put('Y',280,54,66,48);put('stick1',270,234,80)
  if console=='wii':
   for row,keys in enumerate([['A','B'],['1','2']]):
    for col,k in enumerate(keys):put(k,248+68*col,56+68*row,60)
   put('stick0',18,176,96);put('stick1',276,194,76);put('−',20,272,48);put('HOME',76,272,64,48);put('+',332,272,48)
 return d

records=[];jobs=[];items=[]
for path in sorted(SOURCE.glob('*/*/control.svg')):
 console,folder=path.parts[-3:-1]
 layout=json.loads((path.parent/'distribucion-propuesta.json').read_text())
 size=json.loads((path.parent/'integracion.json').read_text())['logicalCanvas']
 layout['palette']='Estudio'
 if console=='ds' and folder=='vertical':layout['version']=4
 svg=ET.parse(path).getroot();groups={g.get('id')[6:]:g for g in svg if g.get('id','').startswith('input-')}
 assert set(groups)=={c['id'] for c in layout['controls']},path
 new=targets(console,folder,layout,size)
 for key,g in groups.items():
  # Labels are placed in the key, not in decorative space outside its hit area.
  for parent in g.iter():
   for child in list(parent):
    if child.tag==tag('text'):parent.remove(child)
  isolate=element('svg',width=size[0],height=size[1],viewBox=f'0 0 {size[0]} {size[1]}')
  for defs in svg.findall(tag('defs')):isolate.append(copy.deepcopy(defs))
  isolate.append(copy.deepcopy(g));jobs.append(ET.tostring(isolate,encoding='unicode'))
  items.append((console,folder,key,g,new[key]))
 records.append((console,folder,path,layout,size,svg,new))
node="const {Resvg}=require(process.env.VETA_RESVG_MODULE||'@resvg/resvg-js');let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>console.log(JSON.stringify(JSON.parse(s).map(x=>{let b=new Resvg(x).getBBox();return [b.x,b.y,b.width,b.height]}))));"
bounds=json.loads(subprocess.check_output(['node','-e',node],input=json.dumps(jobs),text=True))
for (console,folder,key,g,r),b in zip(items,bounds):
 x,y,w,h=r;bx,by,bw,bh=b
 # Use the full control surface, leaving a 2pt edge inside the hit rectangle.
 sx,sy=(w-4)/bw,(h-4)/bh
 if key=='dpad' or key.startswith('stick'):sx=sy=min(sx,sy)
 g.set('transform',f'translate({x+w/2-bw*sx/2} {y+h/2-bh*sy/2}) scale({sx} {sy}) translate({-bx} {-by})')
 # Existing art uses a recognizable palette and shape; labels share its new center.
 if key not in ('dpad','stick0','stick1') and not (console in ('ps1','psp') and key in ('A','B','X','Y')):
  label={'C↑':'↑','C↓':'↓','C←':'←','C→':'→','SHAKE':'↝','HOME':'⌂'}.get(key,key)
  if console in ('ps1','psp'):label={'A':'○','B':'×','X':'△','Y':'□','L':'L1' if console=='ps1' else 'L','R':'R1' if console=='ps1' else 'R'}.get(key,label)
  if console in ('masterSystem','gameGear'):label={'A':'2','B':'1','SELECT':'SELECT','START':'PAUSE' if console=='masterSystem' else 'START'}.get(key,label)
  if console=='pcEngine':label={'A':'I','B':'II','START':'RUN'}.get(key,label)
  if console=='atari2600':label={'A':'FIRE','START':'RESET'}.get(key,label)
  if console=='megaDrive' and key=='SELECT':label='MODE'
  t=element('text',x=x+w/2,y=y+h/2,text_anchor='middle',dominant_baseline='central',font_family='Arial,sans-serif',font_size=13 if len(label)>3 else 18 if len(label)>1 else 23,font_weight=700,fill='#ffffff',stroke='#111820',stroke_width='.45',paint_order='stroke')
  t.text=label
  # Append as sibling later to avoid the geometry transform.
  g.attrib['data-label']=ET.tostring(t,encoding='unicode')
manifest=json.loads((SOURCE/'MANIFEST.json').read_text());manifest['revision']=183;manifest['variants']=[]
packages={}
for console,folder,path,layout,size,svg,new in records:
 for child in list(svg):
  # Full-height landscape panels used to obscure the picture. Keep controls only.
  # NES portrait needs a new uncluttered faceplate for the larger thumb groups.
  if child.tag!=tag('defs') and not child.get('id','').startswith('input-'):
   if folder=='horizontal' or console=='nes' or child.tag==tag('text') or (console=='dreamcast' and child.tag==tag('rect') and child.get('width') not in ('400','400.000')):svg.remove(child)
 if folder=='vertical' and console=='nes':
  svg.insert(1,element('rect',x=0,y=0,width=400,height=size[1],fill='#c9c8c3'))
  svg.insert(2,element('rect',x=8,y=8,width=384,height=size[1]-16,rx=14,fill='#242628',stroke='#ecebe5',stroke_width=2))
 for g in list(svg):
  if 'data-label' in g.attrib:svg.append(ET.fromstring(g.attrib.pop('data-label')))
 for c in layout['controls']:
  x,y,w,h=new[c['id']];c.update(x=x/size[0],y=y/size[1],width=w/size[0],height=h/size[1])
 dest=path.parent;vector=dest/'control-runtime.svg';png=dest/'control-runtime.png'
 changed=not vector.exists() or vector.read_bytes()!=ET.tostring(svg) or not png.exists()
 vector.write_bytes(ET.tostring(svg));(dest/'layout-runtime.json').write_text(json.dumps(layout,ensure_ascii=False,indent=2)+'\n')
 if changed:subprocess.run(['node',str(ROOT/'BuildSupport/skin_export/render_svg.cjs'),str(vector),str(png)],check=True)
 data=png.read_bytes();packages.setdefault(console,[]).append({'layout':layout,'imagePNG':base64.b64encode(data).decode()})
 manifest['variants'].append({'console':console,'orientation':layout['orientation'],'logicalCanvas':size,'imageSHA256':hashlib.sha256(data).hexdigest(),'revision':183})
for console,variants in packages.items():
 path=ROOT/'Sources/Resources'/f'studio-{console}.vetaskin';skin=json.loads(path.read_text());skin['variants']=variants
 path.write_text(json.dumps(skin,ensure_ascii=False,separators=(',',':')))
manifest['scope']='Retained SVG control shapes and palettes, enlarged input and visible controls together. Landscape has transparent empty space and opaque controls; game viewport unchanged. Original sources and personal packages preserved.'
(SOURCE/'MANIFEST.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print('Rebuilt',len(packages),'skins /',len(records),'orientations')

# Editable layers must be refreshed whenever the source art is rebuilt.
subprocess.run([__import__("sys").executable,str(ROOT/"BuildSupport/layer_studio_skins.py")],check=True)
