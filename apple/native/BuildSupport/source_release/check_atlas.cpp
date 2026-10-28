// SPDX-License-Identifier: GPL-3.0-or-later
// Verify generated assets with the exact PPSSPP runtime metadata reader.
#include "Common/Render/TextureAtlas.h"
#include <fstream>
#include <iterator>
#include <vector>
#include <iostream>
#include <cmath>
#include <cstring>
#include <cassert>
#include <set>
bool pngSaveTool(const char *,const void *,int,int,int);
int pngLoad(const char *,int *,int *,unsigned char **);
int main(int argc,char **argv) {
 if(argc!=2)return 2;
 for(auto name:{"font","asciifont","ppge"}) {
  std::string prefix=std::string(argv[1])+"/"+name+"_atlas";
  std::ifstream file(prefix+".meta",std::ios::binary);std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)),{});
  Atlas atlas;assert(!bytes.empty()&&atlas.LoadMeta(bytes.data(),bytes.size()));
  auto font=atlas.getFont(FontID("UBUNTU24"));assert(font);
  int w,h;unsigned char *pixels=nullptr;assert(pngLoad((prefix+".zim.png").c_str(),&w,&h,&pixels)==1);
  assert(w>0&&h>0&&w<=16384&&h<=16384);
  std::set<std::pair<float,float>> positions;
  for(int c=33;c<127;c++){auto g=font->getChar(c);assert(g&&g->wx>0);assert(positions.insert({g->sx,g->sy}).second);assert(g->sx>=0&&g->sy>=0&&g->ex<=1&&g->ey<=1);}
  if(std::string(name)!="asciifont")for(int c:{0x00f1,0x00e1,0x3042,0x65e5,0x4e2d,0xd55c,0x0e01,0x05d0})assert(font->getChar(c));
  if(std::string(name)=="ppge")for(auto id:{"I_CROSS","I_CIRCLE","I_SQUARE","I_TRIANGLE"}){auto img=atlas.getImage(ImageID(id));assert(img&&img->w==32&&img->h==32);}
  // Show Latin text through the atlas instead of the system font.
  std::vector<uint32_t> preview(900*120,0xff181818);int pen=15;
  for(char c:std::string("VETA  Guardar  Cargar  0123456789")){
   auto g=font->getChar(c);if(!g){pen+=10;continue;}
   int x0=std::round(g->sx*w),y0=std::round(g->sy*h),gw=g->pw,gh=g->ph;
   for(int y=0;y<gh&&y+30<120;y++)for(int x=0;x<gw&&pen+x<900;x++){
    auto alpha=pixels[((y0+y)*w+x0+x)*4+3];
    int bright=24+int(alpha)*231/255;preview[(y+30)*900+pen+x]=0xff000000|bright|(bright<<8)|(bright<<16);
   }
   pen+=std::max(1,int(std::ceil(g->wx)));
  }
  assert(pngSaveTool((prefix+"-sample.png").c_str(),preview.data(),900,120,4));free(pixels);
  std::cout<<name<<": metadata, ASCII, language samples, icons and dimensions PASS ("<<w<<"x"<<h<<")\n";
 }
}
