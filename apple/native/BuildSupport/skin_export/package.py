#!/usr/bin/env python3
"""Package native exports with offline gallery, guides and contact sheets."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import argparse,base64,html,json,hashlib,zipfile
p=argparse.ArgumentParser();p.add_argument('folder',type=Path);a=p.parse_args();root=a.folder
rows=json.loads((root/'manifest.json').read_text());assert len(rows)==40
fontpath='/System/Library/Fonts/Supplemental/Arial.ttf'
def font(n):return ImageFont.truetype(fontpath,n)
for row in rows:
 folder=root/row['folder'];w,h=row['canvasPoints'];png=folder/'control.png'
 im=Image.open(png);assert im.size==(round(w*3),round(h*3));im.verify()
 model=json.loads((folder/'distribucion.json').read_text());assert len(model['controls'])==len(row['controls'])
 encoded=base64.b64encode(png.read_bytes()).decode()
 elements=[]
 for c in row['controls']:
  x,y,cw,ch=c['rectPoints'];label=html.escape(c['id']);elements.append(f'<g id="zona-{label}"><rect x="{x:.4f}" y="{y:.4f}" width="{cw:.4f}" height="{ch:.4f}" rx="3"/><text x="{x+3:.4f}" y="{y+11:.4f}">{label}</text></g>')
 svg=f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="{int(w*3)}" height="{int(h*3)}" viewBox="0 0 {w} {h}"><title>{html.escape(row['name'])} · {row['orientation']}</title><desc>Arte actual rasterizado de UIKit y zonas táctiles vectoriales editables. Oculta la capa areas-tactiles para rediseñar.</desc><g id="arte-base"><image width="{w}" height="{h}" xlink:href="data:image/png;base64,{encoded}"/></g><g id="areas-tactiles" fill="none" stroke="#00e2ce" stroke-width="0.7">{''.join(elements)}</g><style>text{{fill:#fff;stroke:#10202c;stroke-width:2;paint-order:stroke;font:9px sans-serif}}</style></svg>'''
 (folder/'guia-editable.svg').write_text(svg)
 # The reference geometry stays in points; PNG is 3x, not 3x the touch target.
 (folder/'LEEME.txt').write_text(f"{row['name']} · {'Horizontal' if row['orientation']=='landscape' else 'Vertical'}\nEstilo principal: {row['palette']}.\nControl: {int(w*3)} × {int(h*3)} píxeles; lienzo lógico: {w:g} × {h:g} puntos.\n\nRediseña control.png o vista-completa.png. Conserva dimensiones/proporción y todos los botones necesarios. Si mueves botones, marca dónde deben responder al toque.\n\ncontrol.png: dibujo actual; horizontal conserva transparencia.\nvista-completa.png: composición de referencia con espacio de juego y menú ilustrativos.\nareas-tactiles.png: zonas que reciben los toques.\nguia-editable.svg: arte PNG incrustado + zonas vectoriales etiquetadas; no convierte los botones en vectores.\ndistribucion.json: distribución compatible con el importador actual de VETA para esta consola y orientación; no incluye imágenes.\nvariante-*.png: los cuatro estilos actuales.\n\nEstas son distribuciones predeterminadas de VETA167; no incluyen ajustes personales de tu iPhone.\n")
# Two printable overview sheets, retaining aspect ratios.
for orientation,label,cols,tw,th in [('portrait','VERTICAL',5,270,650),('landscape','HORIZONTAL',4,440,250)]:
 subset=[r for r in rows if r['orientation']==orientation];pad=24;top=135;count=(len(subset)+cols-1)//cols
 sheet=Image.new('RGB',(pad+(tw+pad)*cols,top+count*(th+pad)+pad),'#eef2f0');draw=ImageDraw.Draw(sheet)
 draw.text((pad,24),f'VETA  /  CONTROLES EN {label}',font=font(32),fill='#152831')
 draw.text((pad,76),'20 consolas · modelos predeterminados · imágenes individuales a 3× en el paquete',font=font(18),fill='#4c5e66')
 for i,r in enumerate(subset):
  x=pad+(i%cols)*(tw+pad);y=top+(i//cols)*(th+pad)
  draw.rounded_rectangle((x,y,x+tw,y+th),radius=12,fill='white')
  draw.text((x+12,y+12),r['name'],font=font(19),fill='#152831')
  im=Image.open(root/r['folder']/'vista-completa.png').convert('RGB');im.thumbnail((tw-24,th-57),Image.Resampling.LANCZOS)
  sheet.paste(im,(x+(tw-im.width)//2,y+45+(th-57-im.height)//2))
 sheet.save(root/f'RESUMEN-{label}.jpg',quality=94)
# Compact main gallery: all content local, no network or upload.
cards=[]
for console in dict.fromkeys(r['console'] for r in rows):
 items=[r for r in rows if r['console']==console];name=items[0]['name'];views=[]
 for r in items:
  folder=r['folder'];ori=r['orientation'];label='Vertical' if ori=='portrait' else 'Horizontal'
  variants=''.join(f'<a href="{folder}/variante-{slug}.png" download>{text}</a>' for slug,text in [('clasica','Clásica'),('veta','VETA'),('noche','Noche'),('transparente','Transparente')])
  views.append(f'''<section class="orientation {ori}"><a class="preview" href="{folder}/vista-completa.png"><img loading="lazy" src="{folder}/vista-completa.png" alt="Mando {html.escape(name)} en {label.lower()}"/></a><div class="links"><a class="primary" href="{folder}/control.png" download="{console}-{ori}-control.png">PNG del control ↓</a><a href="{folder}/vista-completa.png" download="{console}-{ori}-completa.png">Vista completa ↓</a><a href="{folder}/guia-editable.svg" download>Guía SVG ↓</a><a href="{folder}/areas-tactiles.png">Áreas táctiles</a><a href="{folder}/distribucion.json" download>Posiciones JSON ↓</a></div><details><summary>Otros estilos actuales</summary><div class="variants">{variants}</div></details></section>''')
 cards.append(f'<article data-name="{html.escape(name.lower())}"><h2>{html.escape(name)}</h2>{"".join(views)}</article>')
page='''<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>VETA · Plantillas de skins</title><style>
:root{color-scheme:light;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#172e36;background:#edf2ef}*{box-sizing:border-box}body{margin:0}header,main,footer{max-width:1480px;margin:auto;padding:32px}header{padding-top:52px}.eyebrow{font-size:13px;letter-spacing:.17em;font-weight:750;color:#337567}h1{font-size:clamp(32px,5vw,58px);letter-spacing:-.045em;line-height:1.04;margin:18px 0}header p{max-width:780px;font-size:18px;line-height:1.55;color:#465c62}.toolbar{display:flex;gap:12px;flex-wrap:wrap;margin:26px 0 12px;align-items:center}button,input{font:inherit;min-height:46px;border:1px solid #899f96;border-radius:8px;padding:10px 18px}button{background:transparent;color:inherit;cursor:pointer}button[aria-pressed=true]{background:#163e3b;color:#fff;border-color:#163e3b}input{background:#fff;flex:1;min-width:200px;max-width:380px}a{color:#166853;text-underline-offset:3px}a:focus-visible,button:focus-visible,input:focus-visible,summary:focus-visible{outline:3px solid #c07000;outline-offset:4px}.notes{font-size:14px;line-height:1.6}.catalog{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:24px}body.landscape .catalog{grid-template-columns:repeat(auto-fill,minmax(400px,1fr))}article{background:white;border:1px solid #d1dcd6;border-radius:14px;overflow:hidden;padding:22px}h2{font-size:21px;margin:0 0 20px}.preview{display:flex;justify-content:center;background:#080d11;border-radius:8px;overflow:hidden;height:390px}.preview img{height:100%;max-width:100%;object-fit:contain}body.landscape .preview{height:auto;aspect-ratio:844/390}body.landscape .preview img{width:100%}.links{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:16px}.links a{display:flex;align-items:center;min-height:44px;font-size:14px}.links .primary{grid-column:1/-1;justify-content:center;background:#d8eee5;color:#164c3e;border-radius:7px;font-weight:700;text-decoration:none}summary{cursor:pointer;min-height:44px;padding-top:14px;font-size:14px}.variants{display:flex;gap:14px;flex-wrap:wrap;padding:12px 0}.variants a{min-height:44px}body:not(.landscape) .orientation.landscape,body.landscape .orientation.portrait{display:none}footer{color:#465c62;line-height:1.6;padding-bottom:60px}@media(max-width:500px){header,main,footer{padding:22px}body.landscape .catalog{grid-template-columns:1fr}.preview{height:350px}}
</style><body><header><div class="eyebrow">VETA 167 / KIT DE REDISEÑO</div><h1>Tus controles.<br>Tu próximo diseño.</h1><p>20 consolas, ambas orientaciones y los cuatro estilos actuales. Descarga el PNG, rediseña el mando y devuélvelo indicando la consola y orientación.</p><div class="notes"><a href="LEEME.txt">Cómo preparar tu diseño</a> · <a href="FORMATO-PROPUESTO.txt">Skins propios: propuesta de funcionamiento</a><br>Vistas predeterminadas generadas con el dibujo nativo de VETA. No son capturas de tus perfiles personales.</div><div class="toolbar"><button id="vertical" aria-pressed="true">Vertical</button><button id="horizontal" aria-pressed="false">Horizontal</button><input id="search" type="search" aria-label="Buscar consola" placeholder="Buscar consola…"></div><div class="notes">PNG a 3× · zonas táctiles editables · sin conexión ni subidas automáticas</div></header><main class="catalog">CARDS</main><footer>Los PNG son arte para rediseñar. El importador actual de VETA admite el JSON de posiciones, no imágenes. El formato de skins con arte queda propuesto para una próxima implementación.<br><a href="RESUMEN-VERTICAL.jpg">Resumen vertical</a> · <a href="RESUMEN-HORIZONTAL.jpg">Resumen horizontal</a></footer><script>
const v=document.querySelector('#vertical'),h=document.querySelector('#horizontal');function orientation(wide){document.body.classList.toggle('landscape',wide);v.setAttribute('aria-pressed',!wide);h.setAttribute('aria-pressed',wide)}v.onclick=()=>orientation(false);h.onclick=()=>orientation(true);document.querySelector('#search').addEventListener('input',e=>{let q=e.target.value.toLocaleLowerCase();document.querySelectorAll('article').forEach(c=>c.hidden=!c.dataset.name.includes(q))});
</script></body></html>'''.replace('CARDS',''.join(cards))
(root/'ABRIR-GALERIA.html').write_text(page)
(root/'LEEME.txt').write_text('''VETA · KIT DE REDISEÑO DE CONTROLES · 27-10-2026

Empieza por ABRIR-GALERIA.html. Funciona localmente sin conexión.
20 consolas × 2 orientaciones = 40 conjuntos. También están los 4 estilos actuales por conjunto.

PARA REDISEÑAR
1. Elige consola y orientación. Abre control.png para diseñar sólo el mando, o vista-completa.png para ver su relación con la pantalla.
2. Trabaja encima de una copia, conservando las dimensiones y proporción. Las imágenes están a 3×: 132 píxeles representan 44 puntos táctiles.
3. Cambia colores, texturas, formas y decoración. Conserva una identificación clara de cada botón. Evita cubrir el área del juego; en horizontal, conserva transparencia donde debe verse el juego.
4. Si mueves o agrandas botones, usa guia-editable.svg o areas-tactiles.png para marcar también dónde deben responder. Una imagen por sí sola no define el área táctil.
5. Devuelve el PNG con nombre como gamecube-horizontal-mi-skin.png. Adjunta el archivo editable si lo tienes y describe movimientos o cambios de botones. Puedes enviarnos ambas orientaciones juntas o empezar con una.

ARCHIVOS
control.png: dibujo nativo actual del mando, en reposo.
vista-completa.png: referencia de pantalla de teléfono con área del juego y menú ilustrativos.
areas-tactiles.png: dibujo con los límites reales de las zonas táctiles.
guia-editable.svg: PNG actual incrustado y zonas vectoriales etiquetadas; el arte no se convierte en vectores.
distribucion.json: posiciones del diseño; compatible con el importador actual por consola/orientación. No contiene imágenes.
variante-clasica/veta/noche/transparente.png: los cuatro estilos de VETA.
RESUMEN-*.jpg: hojas de contacto de las 20 consolas.
manifest.json: dimensiones, zonas y correspondencias del paquete.

ALCANCE
Son los diseños predeterminados de VETA167, dibujados por su código UIKit real en simulador. No se copió la configuración personal del iPhone. No se usaron juegos ni imágenes de terceros.
Las vistas completas usan lienzos de referencia de400×866 puntos vertical y844×390 horizontal; las áreas seguras y el espacio de juego pueden variar según teléfono y opciones del usuario. Para DS/3DS se reserva el área total de juego, sin simular una partida ni sus dos imágenes.
El render respeta opacidad actual; los controles horizontales se dibujan al62% por el comportamiento existente de VETA.
Los controles del mando adicional usan el mismo sistema; este paquete muestra la distribución del jugador con zona de juego de referencia, no una nueva vista de vídeo del mando adicional.

USO ACTUAL Y FUTURO
Hoy VETA importa/exporta distribución JSON por consola/orientación. Todavía NO importa estos PNG como skins. FORMATO-PROPUESTO.txt describe cómo añadir esa función por usuario; es una propuesta, no una función instalada.
''')
(root/'FORMATO-PROPUESTO.txt').write_text('''SKINS PERSONALIZADOS POR USUARIO · PROPUESTA PARA IMPLEMENTAR

Experiencia propuesta
Ajustes → Skins y controles → Mis skins → Crear / Importar.
Elegir consola; añadir diseño vertical y horizontal; colocar/ajustar áreas táctiles sobre cada imagen; probar todos los botones; guardar con nombre y vista previa. Elegir un skin distinto por consola y orientación. Volver al original siempre disponible.

Cada usuario conserva su propia colección en el dispositivo/perfil. Importar un skin no cambia el predeterminado de otros usuarios. Compartir/exportar será una acción explícita. Si no existe una orientación, usar el diseño original de esa orientación y avisarlo en la vista previa.

Arte y controles
El paquete de skin debe separar: identidad/nombre/autor/consola; imágenes vertical y horizontal; dimensiones de referencia; zona de juego y menú; mapa táctil con IDs estables; variantes pulsado/normal opcionales; versión del formato.
PNG con transparencia para el fondo y para piezas. Guardar coordenadas normalizadas y un lienzo lógico. La cruceta y los sticks siguen siendo controles con direcciones/ejes, aunque se personalice su apariencia. El marco/arte decorativo no debe interceptar toques fuera de sus zonas.
Tamaño táctil mínimo44×44 puntos, sin zonas incompatibles superpuestas. Conservar controles requeridos y evaluar áreas seguras en el tamaño del teléfono. Vista previa antes de aplicar y reversión al diseño anterior.

Importación propuesta
Un paquete .vetaskin podría contener skin.json, portrait.png, landscape.png y preview.png, con IDs de controles y referencias a archivos internos. Definir límites de dimensiones/peso antes de implementarlo; validar consola, formato, cantidad de archivos y geometría. Sin código ejecutable ni descargas implícitas. Los nombres se mantienen dentro del paquete.
El JSON actual veta-controller-layout se conserva para intercambiar posiciones. No cambiar su esquema para aceptar imágenes de forma silenciosa: introducir un formato nuevo con versión explícita y conversión guiada del diseño previo.

Generación propuesta
Diseño manual: añadir arte propio y ajustar zonas en el editor.
Plantillas: elegir consola/paleta/material y mantener controles correctos.
Generación con IA opcional: descripción → borrador de arte → asignación/revisión de botones → prueba → guardar. Generar una imagen no garantiza que un skin funcione. Proveedor, coste, consentimiento y tratamiento de imágenes pendientes de definición; no hay servicio ni subida activa.

Primer paso recomendado
Usar uno de estos PNG para tu primer rediseño. Integrar ese diseño como caso de referencia con ambas orientaciones y controles comprobados. Después implementar importar/exportar, biblioteca por usuario y previsualización. No requiere cambiar motores de emulación, JIT ni los guardados de juego.

Estado: propuesta solamente. No hay importador de imágenes ni generador de skins instalado por esta entrega.
''')
# Verify all image assets decode, names are unique, and exported layouts match manifest.
images=list(root.rglob('*.png'))
for pth in images:
 with Image.open(pth) as im:im.verify()
checks={'consoles':len(set(r['console'] for r in rows)),'orientationSets':len(rows),'fullViews':len(list(root.rglob('vista-completa.png'))),'controllerPNGs':len(list(root.rglob('control.png'))),'palettes':len(list(root.rglob('variante-*.png'))),'PNGsVerified':len(images),'jsonLayouts':len(list(root.rglob('distribucion.json'))),'SVGGuides':len(list(root.rglob('guia-editable.svg'))),'source':'native UIKit rendering; default layouts','appChanged':False,'phoneUsed':False}
assert checks['consoles']==20 and checks['orientationSets']==40 and checks['palettes']==160
(root/'verification.json').write_text(json.dumps(checks,indent=2,ensure_ascii=False)+'\n')
zip_path=root.parent/'VETA-Skins-20-consolas.zip'
with zipfile.ZipFile(zip_path,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
 for f in sorted(root.rglob('*')):
  if f.is_file():archive.write(f,Path(root.name)/f.relative_to(root))
with zipfile.ZipFile(zip_path) as archive:assert archive.testzip() is None
print(json.dumps({**checks,'zipBytes':zip_path.stat().st_size,'zipSHA256':hashlib.sha256(zip_path.read_bytes()).hexdigest()},ensure_ascii=False))
