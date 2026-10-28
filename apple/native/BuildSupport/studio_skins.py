#!/usr/bin/env python3
"""Package reviewed, user-supplied control art; never execute scripts from the ZIP."""
import argparse,base64,hashlib,json,uuid,zipfile,subprocess,xml.etree.ElementTree as ET
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('archive',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1];out=root/'Sources/Resources';source=root/'Content/StudioSkins';source.mkdir(parents=True,exist_ok=True)
records=[]
# Minimal vector + hit-map adjustments prevent 44pt targets intersecting at375pt.
# Offsets are reference points, applied equally to SVG groups and touch centers.
adjustments={'n64':{'C←':(-2,0),'C→':(2,0),'C↑':(0,2)},'ds':{'A':(2,0),'Y':(-2,0),'X':(0,2)},'gamecube':{'A':(-4,0),'Y':(-4,0)},'psp':{'A':(2,0),'Y':(-2,0)},'dreamcast':{'B':(2,0),'X':(-2,0)}}
with zipfile.ZipFile(a.archive) as z:
 prefix='VETA-Skins-19-Estudio/skins/'
 consoles=sorted({n[len(prefix):].split('/')[0] for n in z.namelist() if n.startswith(prefix)})
 assert len(consoles)==19 and 'ps2' not in consoles
 for console in consoles:
  variants=[]
  for folder,orientation in [('vertical','portrait'),('horizontal','landscape')]:
   path=prefix+console+'/'+folder+'/'
   layout=json.loads(z.read(path+'distribucion-propuesta.json'));info=json.loads(z.read(path+'integracion.json'))
   assert layout['console']==console and layout['orientation']==orientation
   layout['palette']='Estudio'
   if console=='ds' and orientation=='portrait':
    assert info['logicalCanvas']==[400,188];layout['version']=4
   data=z.read(path+'control.png');assert data.startswith(b'\x89PNG\r\n\x1a\n')

   dest=source/console/folder;dest.mkdir(parents=True,exist_ok=True)
   for name in ['control.svg','distribucion-propuesta.json','integracion.json']:(dest/name).write_bytes(z.read(path+name))
   offsets=adjustments.get(console,{}) if orientation=='portrait' else {}
   if offsets:
    svg=ET.fromstring(z.read(path+'control.svg'))
    for group in svg.iter():
     ident=group.get('id','').removeprefix('input-')
     if ident in offsets:
      dx,dy=offsets[ident];assert not group.get('transform');group.set('transform',f'translate({dx} {dy})')
    for control in layout['controls']:
     if control['id'] in offsets:
      dx,dy=offsets[control['id']];control['x']+=dx/info['logicalCanvas'][0];control['y']+=dy/info['logicalCanvas'][1]
    ET.register_namespace('','http://www.w3.org/2000/svg')
    (dest/'control-runtime.svg').write_bytes(ET.tostring(svg))
    subprocess.run(['node',str(root/'BuildSupport/skin_export/render_svg.cjs'),str(dest/'control-runtime.svg'),str(dest/'control-runtime.png')],check=True)
    data=(dest/'control-runtime.png').read_bytes()
   (dest/'layout-runtime.json').write_text(json.dumps(layout,ensure_ascii=False,indent=2))
   variants.append({'layout':layout,'imagePNG':base64.b64encode(data).decode()})
   records.append({'adjustments':offsets,'console':console,'orientation':orientation,'imageSHA256':hashlib.sha256(data).hexdigest(),'logicalCanvas':info['logicalCanvas']})
  skin={'format':'veta-personal-skin','version':1,'id':str(uuid.uuid5(uuid.NAMESPACE_URL,'https://retro.krafify.com/skins/estudio/1/'+console)).upper(),'name':'VETA Estudio · '+console,'console':console,'variants':variants}
  (out/('studio-'+console+'.vetaskin')).write_text(json.dumps(skin,ensure_ascii=False,separators=(',',':')))
(source/'MANIFEST.json').write_text(json.dumps({'archiveSHA256':hashlib.sha256(a.archive.read_bytes()).hexdigest(),'variants':records,'scope':'User-supplied control art only; no reference photographs or executable ZIP scripts. DS portrait uses explicit layout version4 (400x188).'},ensure_ascii=False,indent=2))
print('Packaged',len(consoles),'skins /',len(records),'variants')

# Apply the current playable geometry after importing the retained original artwork.
subprocess.run([__import__('sys').executable,str(root/'BuildSupport/refresh_studio_skins.py')],check=True)
