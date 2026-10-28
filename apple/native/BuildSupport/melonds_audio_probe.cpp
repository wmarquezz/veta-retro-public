// VETA actual libretro integration probe; no game or BIOS bytes included.
// argv: authorized NDS fixture, private output directory, optional long-run frames.
#include "libretro.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <CoreFoundation/CoreFoundation.h>
#include <map>
#include <string>
#include <vector>
#include <set>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <chrono>
#include <fstream>
#include <sys/stat.h>
#include <cstdlib>
static std::string base;static std::map<std::string,std::string> options;
static unsigned width,height;static std::vector<uint32_t> pixels;
static uint16_t mask;static bool touch;static uint64_t audioFrames,audioNonzero,videoFrames;
static retro_frame_time_callback timeCallback;
static bool shutdownRequested;
static void logcb(enum retro_log_level level,const char *fmt,...) {if(level<RETRO_LOG_INFO)return;va_list a;va_start(a,fmt);vfprintf(stderr,fmt,a);va_end(a);}
static bool env(unsigned cmd,void *data) {
 switch(cmd) {
 case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:((retro_log_callback*)data)->log=logcb;return true;
 case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
 case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:*(const char**)data=base.c_str();return true;
 case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:*(unsigned*)data=0;return true;
 case RETRO_ENVIRONMENT_SET_VARIABLES: {
  for(auto v=(retro_variable*)data;v&&v->key;v++){const char *p=strstr(v->value,"; ");if(p){p+=2;options[v->key]=std::string(p,strcspn(p,"|"));}}
  options["melonds_network_mode"]="disabled";options["melonds_touch_mode"]="touch";return true;
 }
 case RETRO_ENVIRONMENT_GET_VARIABLE: {auto v=(retro_variable*)data;auto i=options.find(v->key);v->value=i==options.end()?nullptr:i->second.c_str();return v->value!=nullptr;}
 case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:*(bool*)data=false;return true;
 case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:return *(retro_pixel_format*)data==RETRO_PIXEL_FORMAT_XRGB8888;
 case RETRO_ENVIRONMENT_GET_CAN_DUPE:*(bool*)data=true;return true;
 case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:return true;
 case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK:timeCallback=*(retro_frame_time_callback*)data;return true;
 case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
 case RETRO_ENVIRONMENT_SET_GEOMETRY:
 case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
 case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
 case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:return true;
 case RETRO_ENVIRONMENT_SHUTDOWN:shutdownRequested=true;return true;
 default:return false;
 }
}
static void video(const void *data,unsigned w,unsigned h,size_t pitch) {
 if(!data)return;videoFrames++;width=w;height=h;pixels.resize(w*h);
 for(unsigned y=0;y<h;y++)memcpy(pixels.data()+y*w,(const char*)data+y*pitch,w*4);
}
static size_t batch(const int16_t *data,size_t n){audioFrames+=n;for(size_t i=0;i<n;i++)if(data[i*2]||data[i*2+1])audioNonzero++;return n;}
static void sample(int16_t l,int16_t r){int16_t x[]={l,r};batch(x,1);}
static void poll(){}
static int16_t input(unsigned port,unsigned device,unsigned index,unsigned id){
 if(port)return 0;
 if(device==RETRO_DEVICE_JOYPAD)return id==RETRO_DEVICE_ID_JOYPAD_MASK?mask:(id<16&&(mask&(1u<<id))?1:0);
 if(device==RETRO_DEVICE_POINTER && index==0){if(id==RETRO_DEVICE_ID_POINTER_X)return 0;if(id==RETRO_DEVICE_ID_POINTER_Y)return 16384;if(id==RETRO_DEVICE_ID_POINTER_PRESSED)return touch;if(id==RETRO_DEVICE_ID_POINTER_COUNT)return touch?1:0;}
 return 0;
}
static void png(const char *name){
 if(pixels.empty())return;
 auto bytes=CFDataCreate(nullptr,(const UInt8*)pixels.data(),pixels.size()*4);auto provider=CGDataProviderCreateWithCFData(bytes);auto color=CGColorSpaceCreateDeviceRGB();
 auto image=CGImageCreate(width,height,8,32,width*4,color,kCGImageAlphaNoneSkipFirst|kCGBitmapByteOrder32Little,provider,nullptr,false,kCGRenderingIntentDefault);
 std::string path=base+"/"+name;auto url=CFURLCreateFromFileSystemRepresentation(nullptr,(const UInt8*)path.c_str(),path.size(),false);auto dst=CGImageDestinationCreateWithURL(url,CFSTR("public.png"),1,nullptr);CGImageDestinationAddImage(dst,image,nullptr);CGImageDestinationFinalize(dst);
 CFRelease(dst);CFRelease(url);CGImageRelease(image);CGColorSpaceRelease(color);CGDataProviderRelease(provider);CFRelease(bytes);
}
static void run(int n){for(int i=0;i<n;i++){if(timeCallback.callback)timeCallback.callback(16715);retro_run();}}
static uint64_t hash(){uint64_t h=1469598103934665603ull;for(auto p:pixels){h^=p;h*=1099511628211ull;}return h;}
int main(int argc,char **argv){
 if(argc<3||argc>4)return 2;base=argv[2];mkdir(base.c_str(),0700);
 retro_set_environment(env);retro_set_video_refresh(video);retro_set_audio_sample_batch(batch);retro_set_audio_sample(sample);retro_set_input_poll(poll);retro_set_input_state(input);
 retro_init();retro_system_info info{};retro_get_system_info(&info);fprintf(stderr,"CORE %s %s fullpath=%d\n",info.library_name,info.library_version,info.need_fullpath);
 std::ifstream file(argv[1],std::ios::binary);std::vector<char> rom((std::istreambuf_iterator<char>(file)),{});retro_game_info game{argv[1],rom.data(),rom.size(),nullptr};
 if(!retro_load_game(&game)){fprintf(stderr,"LOAD FAILED\n");retro_deinit();return 3;}
 retro_set_controller_port_device(0,RETRO_DEVICE_JOYPAD);retro_system_av_info av{};retro_get_system_av_info(&av);
 auto start=std::chrono::steady_clock::now();run(360);png("boot.png");auto boot=hash();
 touch=true;mask=8;run(3);touch=false;mask=0;run(120);touch=true;mask=256;run(3);touch=false;mask=0;run(240);png("input.png");auto changed=hash()!=boot;
 size_t size=retro_serialize_size();std::vector<char> state(size);bool saved=size>0&&retro_serialize(state.data(),state.size());
 run(20);auto expected=hash();bool restored=saved&&retro_unserialize(state.data(),state.size());run(20);bool replay=hash()==expected;png("restored.png");
 // Repeat from the same checkpoint with touch + A held to demonstrate input,
 // independently of naturally advancing animation.
 bool restored2=retro_unserialize(state.data(),state.size());touch=true;mask=256;run(20);bool inputEffect=hash()!=expected;touch=false;mask=0;png("different-input.png");
 retro_unload_game();retro_deinit();retro_set_environment(env);retro_set_video_refresh(video);retro_set_audio_sample_batch(batch);retro_set_audio_sample(sample);retro_set_input_poll(poll);retro_set_input_state(input);retro_init();
 bool reopened=retro_load_game(&game);
 if(reopened) {retro_set_controller_port_device(0,RETRO_DEVICE_JOYPAD);run(2);reopened=retro_unserialize(state.data(),state.size());if(reopened){run(20);reopened=hash()==expected;}}
 fprintf(stderr,"REOPEN_STATE_REPLAY=%s\n",reopened?"true":"false");
 unsigned longFrames=argc==4?unsigned(strtoul(argv[3],nullptr,10)):0;
 if(longFrames>120000)return 5;
 for(unsigned frame=0;frame<longFrames;frame++){touch=frame%60<3;mask=0;run(1);}
 touch=false;mask=0;png("sustained.png");
 double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
 std::set<uint32_t> colors(pixels.begin(),pixels.end());
 printf("{\"core\":\"%s\",\"version\":\"%s\",\"width\":%u,\"height\":%u,\"fpsTarget\":%.8f,\"sampleRate\":%.1f,\"videoFrames\":%llu,\"audioFrames\":%llu,\"nonzeroAudioFrames\":%llu,\"colors\":%zu,\"changedAfterInput\":%s,\"saved\":%s,\"restored\":%s,\"deterministicReplay\":%s,\"differentInputFromSameState\":%s,\"stateSize\":%zu,\"elapsedSeconds\":%.5f,\"shutdownRequested\":%s}\n",info.library_name,info.library_version,width,height,av.timing.fps,av.timing.sample_rate,(unsigned long long)videoFrames,(unsigned long long)audioFrames,(unsigned long long)audioNonzero,colors.size(),changed?"true":"false",saved?"true":"false",restored&&restored2?"true":"false",replay?"true":"false",inputEffect?"true":"false",size,elapsed,shutdownRequested?"true":"false");
 bool ok=reopened&&saved&&restored&&restored2&&replay&&colors.size()>2&&audioFrames>10000&&audioNonzero>1000&&!shutdownRequested;
 retro_unload_game();retro_deinit();return ok?0:4;
}
