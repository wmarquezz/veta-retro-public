"""Produce VETA icon sizes from the user-approved V/controller master.
Only CoreGraphics resizing/PNG encoding; preserves the supplied artwork and colors.
Run from any directory: python3 scripts/prepare-retro-brand.py
"""
from pathlib import Path
import subprocess,json,base64,struct,shutil,tempfile
r=Path(__file__).resolve().parents[1]
brand=r/'branding/v-control187';assets=r/'web/product-site/assets'
assets.mkdir(parents=True,exist_ok=True)
temporary=tempfile.TemporaryDirectory(prefix='veta-brand-')
resize=Path(temporary.name)/'resize-brand'
subprocess.run(['swiftc',str(r/'apple/native/make-icon.swift'),'-o',str(resize)],check=True)
for size in (16,32,48,64,128,180,192,256,512,1024):
 subprocess.run([str(resize),str(brand/f'veta-v-{size}.png'),str(brand/'master.png'),str(size)],check=True)
svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><image width="512" height="512" href="data:image/png;base64,'+base64.b64encode((brand/'veta-v-512.png').read_bytes()).decode()+'"/></svg>'
(brand/'mark.svg').write_text(svg)
imgs=[(s,(brand/f'veta-v-{s}.png').read_bytes()) for s in (16,32,48)]
offset=6+16*len(imgs);ico=struct.pack('<HHH',0,1,len(imgs));payload=b''
for size,data in imgs:
 ico+=struct.pack('<BBBBHHII',size,size,0,0,1,32,len(data),offset);payload+=data;offset+=len(data)
(brand/'favicon.ico').write_bytes(ico+payload)
for name,size in [('veta-mark187.png',512),('veta-social187.png',1024),('favicon-32.png',32),('favicon-16.png',16),('apple-touch-icon.png',180),('icon-192.png',192),('icon-512.png',512)]:shutil.copy2(brand/f'veta-v-{size}.png',assets/name)
for name in ['mark.svg','favicon.ico']:shutil.copy2(brand/name,assets/name)
for folder in ['os/ui/public','os/mobile/public']:
 p=r/folder
 if p.exists():
  for name in ['mark.svg','icon-192.png','icon-512.png','favicon.ico','apple-touch-icon.png']:shutil.copy2(assets/name,p/name)
shutil.copy2(brand/'veta-v-1024.png',r/'apple/native/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png')
p=r/'apple/native/Sources/Assets.xcassets/VetaLogo.imageset';p.mkdir(exist_ok=True)
shutil.copy2(brand/'veta-v-256.png',p/'VetaLogo.png')
(p/'Contents.json').write_text(json.dumps({'images':[{'filename':'VetaLogo.png','idiom':'universal'}],'info':{'author':'xcode','version':1}},indent=2))

temporary.cleanup()
print('V/controller app and web assets generated from',brand/'master.png')
