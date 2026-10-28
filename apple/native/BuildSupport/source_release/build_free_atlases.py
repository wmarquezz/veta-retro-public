#!/usr/bin/env python3
"""Build PPSSPP atlases using only reviewed OFL fonts; never modify upstream assets."""
import argparse, hashlib, json, shlex, shutil, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--ppsspp', required=True, type=Path)
p.add_argument('--fonts', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a=p.parse_args(); src=a.ppsspp.resolve(); out=a.output.resolve(); out.mkdir(parents=True,exist_ok=True)
def run(cmd,**kw): subprocess.run(cmd,check=True,**kw)
# Adapt only tool filesystem plumbing; retain upstream rasterizer/packing/serialization.
text=(src/'Common/Render/AtlasGen.cpp').read_text()
start=text.index('\tsize_t sz;',text.index('bool Image::LoadPNG'))
end=text.index('\tresize(w, h);',start)
text=text[:start]+'''\tunsigned char *img_data;
\tint w, h;
\tif (1 != pngLoad(png_name, &w, &h, &img_data)) return false;
'''+text[end:]
text=text.replace('pngSave(Path(png_name),','pngSaveTool(png_name,').replace('File::OpenCFile(Path(zim_name), "wb")','fopen(zim_name, "wb")')
text=text.replace('typedef unsigned short u16;', 'bool pngSaveTool(const char *, const void *, int, int, int);\ntypedef unsigned short u16;')
# The old brute-force packer silently leaves glyphs at (0,0) when full.
# Use upstream stb skyline packing, add a guard pixel and reject overflow.
text=text.replace('image_width * 2, nodes.data()', '16384, nodes.data()')
text=text.replace('(stbrp_coord)data[i].w;', '(stbrp_coord)(data[i].w + 1);').replace('(stbrp_coord)data[i].h;', '(stbrp_coord)(data[i].h + 1);')
text=text.replace('stbrp_pack_rects(&context, rects.data(), (int)rects.size());', 'if (!stbrp_pack_rects(&context, rects.data(), (int)rects.size())) { fprintf(stderr, "Atlas overflow\\n"); exit(1); }')
text=text.replace('rects[i].x + rects[i].w;', 'rects[i].x + data[index].w;').replace('rects[i].y + rects[i].h;', 'rects[i].y + data[index].h;')
text=text.replace('data[index].ey = rects[i].y + data[index].h;', 'data[index].ey = rects[i].y + data[index].h; if (!data[index].w || !data[index].h) data[index].sx = data[index].sy = data[index].ex = data[index].ey = 0;')
text=text.replace('dest->copyfrom(images[i],', 'if (!data[i].w || !data[i].h) continue;\n\t\tdest->copyfrom(images[i],')
(out/'AtlasGen.cpp').write_text(text)
tool=(src/'ext/native/tools/atlastool.cpp').read_text().replace('bucket.Pack(image_width);','bucket.Pack2(image_width);').replace('Data dat;', 'Data dat{};')
(out/'atlastool.cpp').write_text(tool)
text=(src/'Common/Data/Format/PNGLoad.cpp').read_text().replace('const Path &filename','const char *filename').replace('File::OpenCFile(filename, "wb")','fopen(filename, "wb")').replace('filename.c_str()','filename').replace('File::Delete(filename)','remove(filename)').replace('bool pngSave(', 'bool pngSaveTool(')
(out/'PNGLoad.cpp').write_text(text)
(out/'tool_support.cpp').write_text('''// SPDX-License-Identifier: GPL-3.0-or-later
// Standalone build-tool support; never linked into VETA.
#include "Common/Log.h"
#include <cstring>
#include <string_view>
#include <algorithm>
#include <cstdarg>
#include <cstdio>
static bool logging = true;
bool *g_bLogEnabledSetting = &logging;
LogChannel g_log[(size_t)Log::NUMBER_OF_LOGS];
void GenericLog(Log, LogLevel, const char *, int, const char *fmt, ...) {
 va_list a; va_start(a, fmt); vfprintf(stderr, fmt, a); va_end(a); fputc('\\n', stderr);
}
size_t truncate_cpy(char *dst, size_t size, std::string_view src) {
 if (!size) return 0; auto n=std::min(size-1,src.size()); memcpy(dst,src.data(),n); dst[n]=0; return n;
}
''')
flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','freetype2','libpng','libzstd'],text=True))
run(['c++','-std=c++17','-O2','-DSDL','-I'+str(src),'-I'+str(src/'ext'),'-I'+str(src/'ext/native'), '-I'+str(src/'ext/native/tools'),str(out/'atlastool.cpp'),str(src/'Common/Data/Encoding/Utf8.cpp'),str(src/'Common/Data/Format/ZIMSave.cpp'),str(src/'Common/Data/Convert/ColorConv.cpp'),str(src/'Common/Render/DropShadow.cpp'),str(out/'AtlasGen.cpp'),str(out/'PNGLoad.cpp'),str(out/'tool_support.cpp'),*flags,'-lz','-o',str(out/'atlastool')])
# Paths in recipes are relative so regenerated artifacts do not depend on a developer home.
shutil.copy2(src/'assets/Roboto_Condensed-Regular.ttf',out/'Roboto.ttf')
shutil.copy2(a.fonts/'NotoSansCJKjp-Regular.otf',out/'NotoCJK.otf')
(out/'images').mkdir(exist_ok=True)
run(['swift',str(Path(__file__).with_name('draw_buttons.swift')),str(out/'images')])
shutil.copytree(src/'assets/lang',out/'assets/lang',dirs_exist_ok=True)
shutil.copy2(src/'assets/langregion.ini',out/'assets/langregion.ini')
for font in ['NotoSans','NotoSansThai','NotoSansHebrew']:
 shutil.copy2(a.fonts/(font+'.ttf'),out/(font+'.ttf'))
def fallback(size, ranges):
 return ''.join('font UBUNTU24 '+font+' '+ranges+' '+str(size)+' 0\n' for font in ['NotoSans.ttf','NotoCJK.otf','NotoSansThai.ttf','NotoSansHebrew.ttf'])
recipes={'font':'2048\nfont UBUNTU24 Roboto.ttf UWERS 34 -2\n'+fallback(30,'UWEhkcRGHKVTeS'),
 'asciifont':'2048\nfont UBUNTU24 Roboto.ttf UWERS 34 -2\n',
 'ppge':'2048\n'+fallback(24,'UWEhkcJRGHKVTeS')+''.join('image I_'+n.upper()+' images/'+n+'.png copy\n' for n in ['cross','circle','square','triangle'])}
for name,recipe in recipes.items():
 (out/(name+'.txt')).write_text(recipe)
 with (out/(name+'.log')).open('w') as log: run([str(out/'atlastool'),name+'.txt',name]+(['8888'] if name!='ppge' else []),cwd=out,stdout=log,stderr=subprocess.STDOUT)
for name in recipes:
 log=(out/(name+'.log')).read_text()
 if 'Failed' in log or 'ERROR' in log: raise RuntimeError('Atlas generation failed: '+name)
files={p.name:{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in out.glob('*_atlas.*')}
(out/'outputs.json').write_text(json.dumps(files,indent=2)+'\n')
print(json.dumps(files,indent=2))
