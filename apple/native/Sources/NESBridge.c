#include "NESBridge.h"
#include <TargetConditionals.h>
#include "CoreAPI.h"
#include "HardwareVulkan.h"
bool veta_hw_setup(struct retro_hw_render_callback *request);
void veta_hw_begin(void);
void veta_hw_make_current(void);
void veta_hw_size(unsigned width,unsigned height);
bool veta_hw_read(uint32_t *pixels,unsigned width,unsigned height);
void veta_hw_destroy(void);
void veta_hw_shared_configure(bool requested);
bool veta_hw_shared_active(void);
bool veta_hw_shared_set_device(void *device);
bool veta_hw_shared_publish(unsigned width,unsigned height);
VetaSharedFrame veta_hw_shared_acquire(void);
bool veta_hw_shared_copy(uint32_t *pixels,unsigned width,unsigned height,uint64_t *generation,uint64_t *sequence);
bool veta_exec_alloc(struct retro_exec_mem_alloc *request);
bool veta_exec_free(struct retro_exec_mem_free *request);
bool veta_jit_available(void);
#ifdef VETA_JIT_LAB
static const VetaCoreAPI *core;
#else
static const VetaCoreAPI *core=&nesAPI;
#endif
static unsigned activeConsole;
static bool gameCubeExecutable;
static bool interpreterExecution;
bool veta_execution_allows_jit(void) {return !interpreterExecution && veta_jit_available();}

// Guest CPUs may change ARM64 rounding/flush modes. Preserve their environment
// between calls, but never leave those modes active in UIKit/SwiftUI.
static fenv_t guestFPU;
static bool guestFPUValid;
typedef struct {fenv_t host;} VetaFPUScope;
static VetaFPUScope enter_guest_fpu(void) {
    VetaFPUScope scope;fegetenv(&scope.host);
    if(guestFPUValid)fesetenv(&guestFPU);
    return scope;
}
static void leave_guest_fpu(VetaFPUScope *scope) {
    fegetenv(&guestFPU);guestFPUValid=true;fesetenv(&scope->host);
}
#define GUEST_FPU_SCOPE VetaFPUScope fpuScope __attribute__((cleanup(leave_guest_fpu)))=enter_guest_fpu()

#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <time.h>

// Main-thread owned, matching the libretro lifecycle. Vulkan callbacks publish
// their independent counters atomically; profiling never touches audio callbacks.
static bool runProfileRequested;
static VetaRunProfile runProfile;
static uint64_t run_profile_clock(void) {
    struct timespec value={0};if(clock_gettime(CLOCK_MONOTONIC_RAW,&value)!=0)return 0;
    return (uint64_t)value.tv_sec*1000000000ull+(uint64_t)value.tv_nsec;
}
void veta_run_profile_enable(bool enabled) {
#if DEBUG
    runProfileRequested=enabled;
#else
    (void)enabled;runProfileRequested=false;
#endif
}
VetaRunProfile veta_run_profile_snapshot(void) {
    VetaRunProfile out=runProfile;
    if(!out.enabled)return out;
    VetaVulkanProfile vk=veta_vk_profile_snapshot();
    out.video_read_count=vk.read_count;out.video_read_failures=vk.read_failures;out.video_read_ns=vk.read_ns;
    out.queue_submit_count=vk.submit_count;out.queue_submit_ns=vk.submit_ns;
    out.queue_wait_count=vk.wait_count;out.queue_wait_ns=vk.wait_ns;
    out.callback_wait_count=vk.callback_wait_count;out.callback_wait_ns=vk.callback_wait_ns;
    out.queue_lock_count=vk.lock_count;out.queue_lock_ns=vk.lock_ns;
    out.cpu_convert_count=vk.convert_count;out.cpu_convert_ns=vk.convert_ns;
    return out;
}

// Lifecycle and video belong to the main thread. A dual-core engine can poll
// input and produce audio on its CPU thread, including the tail of retro_run.
// Audio remains one producer/one realtime consumer; neither takes a lock.
#define AUDIO_CAPACITY 16384u
static int16_t audioRing[AUDIO_CAPACITY][2];
static atomic_uint audioWrite, audioRead;
static atomic_uint_fast64_t audioDelivered, audioUnderruns, audioDropped;
static uint32_t pixels[2048*2048];
static unsigned width=256,height=240,pixelFormat=RETRO_PIXEL_FORMAT_0RGB1555;
static _Atomic(uint32_t) inputMasks[4], analogPairs[4][2];
static _Atomic(uint64_t) pointerState;
static bool loaded, initialized;
static atomic_bool shutdownRequested;
bool veta_shutdown_requested(void) {return shutdownRequested;}
static double fps=60.0988, sampleRate=48000;
static uint64_t frames;
static _Atomic(uint64_t) audioFrames,audioNonzero;
static void refresh_dolphin_timing(void) {
    if(!loaded || (activeConsole!=17 && activeConsole!=18))return;
    // Dolphin's first VI settle can notify GEOMETRY only, even if the
    // initial 50 Hz fallback became 59.94 Hz. Query the actual core timing.
    struct retro_system_av_info info={0};core->get_system_av_info(&info);
    if(isfinite(info.timing.fps) && info.timing.fps>=10 && info.timing.fps<=240)fps=info.timing.fps;
    if(isfinite(info.timing.sample_rate) && info.timing.sample_rate>=8000 && info.timing.sample_rate<=192000)sampleRate=info.timing.sample_rate;
}
static char directory[4096],systemDirectory[4096], region[16];
static struct { char key[128]; char value[128]; } defaults[256];
static unsigned defaultCount;
static struct { char key[128]; char value[128]; } pendingOptions[16], activeOptions[16];
static unsigned pendingOptionCount, activeOptionCount;
static bool optionsChanged;
static atomic_uint rumble[4][2];
unsigned veta_max_players(unsigned console) {
    if(console==12 || console==15 || console==17)return 4; // N64, Dreamcast, GameCube native ports.
    if((console>=2 && console<=4) || console==7 || console==11 || console==14 || console==16 || console==18 || console==20)return 1;
    return 2; // No implicit multitap or handheld link emulation.
}
void veta_options_clear(void) {pendingOptionCount=0;memset(pendingOptions,0,sizeof(pendingOptions));}
bool veta_option_set(const char *key,const char *value) {
    if(!key || !value || !*key || !*value || strlen(key)>=128 || strlen(value)>=128)return false;
    // Exact allowlist mirrors CoreOptionID. Never expose arbitrary engine/JIT knobs.
    bool valid=(!strcmp(key,"fceumm_region") && (!strcmp(value,"Auto") || !strcmp(value,"NTSC") || !strcmp(value,"PAL") || !strcmp(value,"Dendy"))) ||
      (!strcmp(key,"snes9x_region") && (!strcmp(value,"auto") || !strcmp(value,"ntsc") || !strcmp(value,"pal"))) ||
      (!strcmp(key,"genesis_plus_gx_region_detect") && (!strcmp(value,"auto") || !strcmp(value,"ntsc-u") || !strcmp(value,"pal") || !strcmp(value,"ntsc-j"))) ||
      (!strcmp(key,"ppsspp_internal_resolution") && (!strcmp(value,"480x272") || !strcmp(value,"960x544"))) ||
      (!strcmp(key,"play_bilinear_filtering") && (!strcmp(value,"false") || !strcmp(value,"true"))) ||
      (!strcmp(key,"play_res_multi") && (!strcmp(value,"1x") || !strcmp(value,"2x"))) ||
      (!strcmp(key,"ppsspp_texture_filtering") && (!strcmp(value,"Auto") || !strcmp(value,"Nearest") || !strcmp(value,"Linear")));
    if(!valid)return false;
    unsigned i=0;for(;i<pendingOptionCount;i++)if(!strcmp(key,pendingOptions[i].key))break;
    if(i>=16)return false;if(i==pendingOptionCount)pendingOptionCount++;
    snprintf(pendingOptions[i].key,128,"%s",key);snprintf(pendingOptions[i].value,128,"%s",value);return true;
}
void veta_rumble_clear(void) {for(unsigned p=0;p<4;p++)for(unsigned e=0;e<2;e++)atomic_store(&rumble[p][e],0);}
unsigned veta_rumble_strength(unsigned port,unsigned effect) {return port<4 && effect<2 ? atomic_load(&rumble[port][effect]):0;}
static bool set_rumble(unsigned port,enum retro_rumble_effect effect,uint16_t strength) {
    if(port>=veta_max_players(activeConsole) || (unsigned)effect>=2)return false;
    atomic_store(&rumble[port][effect],strength);return true;
}

static void log_core(enum retro_log_level level,const char *fmt,...) {
#ifdef DEBUG
    if(level>=RETRO_LOG_WARN || (level>=RETRO_LOG_INFO && getenv("VETA_CORE_VERBOSE"))) {
        va_list args; va_start(args,fmt); vfprintf(stderr,fmt,args); va_end(args);
    }
#endif
#ifdef VETA_JIT_DEVELOPMENT
    // Private, bounded engine warnings for diagnosing physical-device failures.
    if(level>=RETRO_LOG_WARN && directory[0]) {
        char path[4200];snprintf(path,sizeof(path),"%s/jit-core-warnings.log",directory);
        FILE *file=fopen(path,"a+");
        if(file){fseek(file,0,SEEK_END);if(ftell(file)<1024*1024){va_list args;va_start(args,fmt);vfprintf(file,fmt,args);va_end(args);}fclose(file);}
    }
#endif
}
static bool environment(unsigned cmd,void *data) {
    switch(cmd) {
    case RETRO_ENVIRONMENT_SHUTDOWN: shutdownRequested=true;return true;
    case RETRO_ENVIRONMENT_EXEC_MEM_ALLOC:return !interpreterExecution && veta_exec_alloc(data);
    case RETRO_ENVIRONMENT_EXEC_MEM_FREE:return veta_exec_free(data);
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE: *(bool*)data=!interpreterExecution && veta_jit_available();return true;
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER: *(enum retro_hw_context_type*)data=activeConsole==16 ? RETRO_HW_CONTEXT_VULKAN:RETRO_HW_CONTEXT_OPENGLES3;return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER:return veta_hw_setup(data);
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE:return veta_vk_environment(cmd,data);
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((struct retro_log_callback*)data)->log=log_core; return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *(const char**)data=systemDirectory;return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char**)data=directory; return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: *(bool*)data=true; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        pixelFormat=*(enum retro_pixel_format*)data; return pixelFormat<=RETRO_PIXEL_FORMAT_RGB565;
    case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE: ((struct retro_rumble_interface*)data)->set_rumble_state=set_rumble;return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *(unsigned*)data=0; return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES: {
        const struct retro_variable *v=data; defaultCount=0;
        for(;v && v->key && defaultCount<256;v++) {
            const char *start=strstr(v->value,"; "); if(!start) continue; start+=2;
            size_t len=strcspn(start,"|"); if(len>127) len=127;
            snprintf(defaults[defaultCount].key,128,"%s",v->key);
            memcpy(defaults[defaultCount].value,start,len); defaults[defaultCount].value[len]=0; defaultCount++;
        } return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *v=data; v->value=NULL;
        if(interpreterExecution && !strcmp(v->key,"dolphin_cpu_core")){
            v->value="5";
#ifdef VETA_JIT_DEVELOPMENT
            const char *engineTest=getenv("VETA_PERF165_ENGINE_TEST");
            const char *cpuCore=getenv("VETA_PERF165_CPU_CORE");
            if(engineTest && !strcmp(engineTest,"1") && cpuCore && !strcmp(cpuCore,"6"))
                v->value="6";
#endif
            return true;
        }
#ifdef VETA_JIT_DEVELOPMENT
        // Device default verified with Mario 64 and Ocarina, not all N64 games.
        // Explicit 0 retains the old backend; 1 also enables GPU in simulator QA.
        const char *n64GPU=getenv("VETA_QA_N64_GPU");
        if(activeConsole==12 && (n64GPU ? !strcmp(n64GPU,"1") : !TARGET_OS_SIMULATOR)) {
            if(!strcmp(v->key,"mupen64plus-rdp-plugin")){v->value="gliden64";return true;}
            if(!strcmp(v->key,"mupen64plus-rsp-plugin")){v->value="hle";return true;}
            if(!strcmp(v->key,"mupen64plus-cpucore")){v->value="cached_interpreter";return true;}
            if(!strcmp(v->key,"mupen64plus-43screensize")){v->value="640x480";return true;}
            if(!strcmp(v->key,"mupen64plus-aspect")){v->value="4:3";return true;}
            if(!strcmp(v->key,"mupen64plus-EnableNativeResFactor")){v->value="0";return true;}
            if(!strcmp(v->key,"mupen64plus-ThreadedRenderer")){v->value="False";return true;}
            if(!strcmp(v->key,"mupen64plus-MultiSampling")){v->value="0";return true;}
            if(!strcmp(v->key,"mupen64plus-FXAA")){v->value="0";return true;}
        }
        // Bounded A/B diagnostics only; production defaults below stay unchanged.
        const char *engineTest165=getenv("VETA_PERF165_ENGINE_TEST");
        if(interpreterExecution && engineTest165 && !strcmp(engineTest165,"1")) {
            if(!strcmp(v->key,"dolphin_cpu_clock_rate")){v->value="1.00";return true;}
            if(!strcmp(v->key,"dolphin_emulation_speed")){v->value="1.0";return true;}
        }
        const char *parallel165=getenv("VETA_PERF165_PARALLEL");
        if(interpreterExecution && parallel165 && (!strcmp(parallel165,"1") || !strcmp(parallel165,"0")) &&
           (!strcmp(v->key,"dolphin_main_cpu_thread") || !strcmp(v->key,"flycast_threaded_rendering"))) {
            v->value=!strcmp(parallel165,"1") ? "enabled":"disabled";return true;
        }
#endif
        // Keep persisted profile keys while translating to replacement cores.
        const char *legacyKey=!strcmp(v->key,"bsnes_region") ? "snes9x_region":
            !strcmp(v->key,"veta_jgenesis_region") ? "genesis_plus_gx_region_detect":NULL;
        if(legacyKey){
            v->value="auto";
            for(unsigned i=0;i<activeOptionCount;i++)if(!strcmp(legacyKey,activeOptions[i].key))v->value=activeOptions[i].value;
            return true;
        }
        if(!strcmp(v->key,"veta_jgenesis_system")){v->value=activeConsole==6 ? "sms":activeConsole==7 ? "gg":"md";return true;}
        // bsnes gates chip HLE behind this master option. Keep other accuracy
        // overrides at their defaults; no external DSP/CX4 firmware is required.
        if(!strcmp(v->key,"bsnes_violate_accuracy")){v->value="enabled";return true;}
        if(!strcmp(v->key,"bsnes_chip_hle")){v->value="HLE";return true;}
        for(unsigned i=0;i<activeOptionCount;i++)if(!strcmp(v->key,activeOptions[i].key)){v->value=activeOptions[i].value;return true;}
        if(!strcmp(v->key,"melonds_network_mode")) v->value="disabled";
        else if(!strcmp(v->key,"melonds_touch_mode")) v->value="touch";
        else if(!strcmp(v->key,"fceumm_region")) v->value=region;
        else if(!strcmp(v->key,"mgba_gb_model")) v->value=activeConsole==2 ? "Game Boy":"Game Boy Color";
        else if(!strcmp(v->key,"mgba_sgb_borders")) v->value="OFF";
        else if(!strcmp(v->key,"mgba_use_bios")) v->value="OFF";
        else if(!strcmp(v->key,"mgba_skip_bios")) v->value="ON";
        else if(!strcmp(v->key,"genesis_plus_gx_system_hw")) v->value=activeConsole==6 ? "master system":activeConsole==7 ? "game gear":"mega drive / genesis";
        else if(!strcmp(v->key,"beetle_saturn_save_method")) v->value="libretro";
        else if(!strcmp(v->key,"dolphin_dsp_hle")) v->value=gameCubeExecutable ? "disabled":"enabled";
        else if(!strcmp(v->key,"dolphin_ir_mode")) v->value="1";
        else if(!strcmp(v->key,"dolphin_main_cpu_thread")) v->value=interpreterExecution ? "enabled":"disabled";
        else if(interpreterExecution && !strcmp(v->key,"dolphin_cpu_clock_rate")) v->value="1.00";
        else if(interpreterExecution && !strcmp(v->key,"dolphin_emulation_speed")) v->value="1.0";
        else if(!strcmp(v->key,"dolphin_osd_enabled")) v->value="disabled"; // Frontend status and private logs handle diagnostics.
        else if(!strcmp(v->key,"dolphin_cpu_core")) v->value=!interpreterExecution && veta_jit_available() ? "4":"5";
        else if(!strcmp(v->key,"dolphin_fastmem") || !strcmp(v->key,"dolphin_fastmem_arena")) v->value="disabled";
        else if(!strcmp(v->key,"dolphin_renderer")) {
#ifdef VETA_JIT_DEVELOPMENT
            v->value=TARGET_OS_SIMULATOR ? "Software":"Hardware";
#elif defined(VETA_JIT_LAB)
            v->value=getenv("VETA_LAB_SOFTWARE") ? "Software":"Hardware";
#else
            v->value=TARGET_OS_SIMULATOR ? "Software":"Hardware";
#endif
        }
        else if(!strcmp(v->key,"flycast_threaded_rendering")) v->value="disabled";
        else if(!strcmp(v->key,"ppsspp_cpu_core")) v->value="IR JIT"; // Upstream name for its non-executable IR interpreter.
        else if(!strcmp(v->key,"ppsspp_internal_resolution")) v->value="480x272";
        else if(!strcmp(v->key,"desmume_pointer_type")) v->value="touch";
        else if(!strcmp(v->key,"desmume_pointer_mouse")) v->value="enabled";
        else if(!strcmp(v->key,"mupen64plus-cpucore")) v->value="cached_interpreter";
        else if(!strcmp(v->key,"mupen64plus-alt-map")) v->value="True";
        else if(!strcmp(v->key,"mupen64plus-rdp-plugin")) v->value="angrylion";
        else if(!strcmp(v->key,"mupen64plus-rsp-plugin")) v->value=TARGET_OS_SIMULATOR ? "parallel":"cxd4";
        else if(!strcmp(v->key,"parallel-n64-cpucore")) v->value="cached_interpreter";
        else if(!strcmp(v->key,"parallel-n64-rspplugin")) v->value="cxd4";
        else if(!strcmp(v->key,"parallel-n64-gfxplugin")) v->value="angrylion";
        else if(!strcmp(v->key,"pcsx_rearmed_drc")) v->value="disabled";
        else if(!strcmp(v->key,"fceumm_sndrate_hint")) v->value="48KHz";
        else if(!strcmp(v->key,"fceumm_overscan_h") || !strcmp(v->key,"fceumm_overscan_v")) v->value="disabled";
        else for(unsigned i=0;i<defaultCount;i++) if(!strcmp(v->key,defaults[i].key)) {v->value=defaults[i].value;break;}
        return v->value!=NULL;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *(bool*)data=optionsChanged;optionsChanged=false; return true;
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
        struct retro_system_av_info *info=data; fps=info->timing.fps; sampleRate=info->timing.sample_rate; return true;
    }
    case RETRO_ENVIRONMENT_SET_GEOMETRY: refresh_dolphin_timing();return true;
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
    case RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE: *(float*)data=60; return true;
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE: *(int*)data=3; return true;
    default: return false;
    }
}
// VETA165_DEFERRED_VIDEO_BEGIN: main-thread owned, like video/lifecycle.
static VetaVideoReadbackProfile videoReadback;
static bool videoReadbackHasImage;
static bool sharedVideoRequested,sharedVideoImage;
static uint64_t sharedPixelsGeneration,sharedPixelsSequence;
static bool videoReadbackHybrid;
static bool videoReadbackNextFinal=true,videoReadbackRunFinal=true;
static void configure_video_readback(void) {
    videoReadback=(VetaVideoReadbackProfile){0};videoReadbackHasImage=false;
    sharedVideoRequested=sharedVideoImage=false;sharedPixelsGeneration=sharedPixelsSequence=0;
#if VETA_JIT_DEVELOPMENT && !TARGET_OS_SIMULATOR
    const char *shared=getenv("VETA_PERF165_SHARED_GL");
    // Device-validated GC/Wii path. Explicit 0 retains CPU readback for diagnosis;
    // pool creation/publication failure also falls back for the current frame.
    sharedVideoRequested=(activeConsole==17 || activeConsole==18) && (!shared || !strcmp(shared,"1"));
#endif
    veta_hw_shared_configure(sharedVideoRequested);
    videoReadbackHybrid=activeConsole==17 || activeConsole==18;
    videoReadback.enabled=videoReadbackHybrid;
    videoReadbackNextFinal=videoReadbackRunFinal=true;
#if DEBUG
    const char *mode=getenv("VETA_PERF165_DEFER_GC_READBACK");
    if(videoReadbackHybrid && mode) {
        if(!strcmp(mode,"0") || !strcmp(mode,"profile")) {
            videoReadbackHybrid=false;videoReadback.enabled=false;
            videoReadback.profiling=!strcmp(mode,"profile");
        } else if(!strcmp(mode,"1") || !strcmp(mode,"hybrid")) {
            videoReadbackHybrid=!strcmp(mode,"hybrid");
            videoReadback.profiling=true;
        }
    }
#endif
}
void veta_video_readback_hint(bool final_frame) {
    // Prediction only: a missing/incorrect hint cannot suppress materialization.
    // Consumed by the next run; unrelated lifecycle callbacks stay immediate.
    if(videoReadbackHybrid)videoReadbackNextFinal=final_frame;
}
static bool read_hardware_video(unsigned w,unsigned h) {
    uint64_t start=videoReadback.profiling?run_profile_clock():0;
    // Retain an exact CPU image before replacing a differently sized shared
    // publication; a failed new-size allocation/read must preserve the old one.
    if(sharedVideoImage && (w!=width || h!=height)) {
        if(!veta_hw_shared_copy(pixels,width,height,&sharedPixelsGeneration,&sharedPixelsSequence))return false;
        sharedVideoImage=false;
    }
    if(sharedVideoRequested && veta_hw_shared_publish(w,h)) {
        sharedVideoImage=true;videoReadbackHasImage=true;return true;
    }
    bool ok=veta_hw_read(pixels,w,h);
    if(ok)sharedVideoImage=false;
    if(videoReadback.profiling) {
        uint64_t end=run_profile_clock();videoReadback.reads++;
        if(start && end>=start)videoReadback.read_ns+=end-start;
        if(!ok)videoReadback.failures++;
    }
    if(ok)videoReadbackHasImage=true;
    return ok;
}
static void flush_pending_video(void) {
    if(!videoReadback.pending)return;
    videoReadback.pending=false;
    // Dimensions were already validated by a successful synchronous frame.
    // On read failure pixels still hold the last successfully captured image.
    read_hardware_video(width,height);
}
static void invalidate_deferred_video(void) {
    flush_pending_video();
    if(sharedVideoImage)veta_hw_shared_copy(pixels,width,height,&sharedPixelsGeneration,&sharedPixelsSequence);
    sharedVideoImage=false;videoReadbackHasImage=false;
    videoReadbackNextFinal=videoReadbackRunFinal=true;
}
VetaVideoReadbackProfile veta_video_readback_profile(void) {return videoReadback;}
static void video(const void *data,unsigned w,unsigned h,size_t pitch) {
    if(!data || w>2048 || h>2048) return;
    if(data==RETRO_HW_FRAME_BUFFER_VALID){
        if(videoReadback.profiling)videoReadback.callbacks++;
        if(!w || !h)return;
        if(videoReadback.enabled && (!videoReadbackHybrid || !videoReadbackRunFinal) &&
           !veta_vk_active() && videoReadbackHasImage &&
           w && h && w==width && h==height) {
            if(videoReadback.profiling) {
                if(videoReadback.pending)videoReadback.superseded++;
                videoReadback.deferred++;
            }
            videoReadback.pending=true;return;
        }
        // The first image and size transitions keep the original synchronous
        // success/failure contract. An older pending image is superseded here.
        if(videoReadback.pending && videoReadback.profiling)videoReadback.superseded++;
        videoReadback.pending=false;
        if(read_hardware_video(w,h)){width=w;height=h;}return;
    }
    if(videoReadback.pending && videoReadback.profiling)videoReadback.superseded++;
    videoReadback.pending=false;videoReadbackHasImage=false;sharedVideoImage=false;
    width=w;height=h;
    for(unsigned y=0;y<h;y++) for(unsigned x=0;x<w;x++) {
        const uint8_t *row=(const uint8_t*)data+y*pitch; uint32_t rgb;
        if(pixelFormat==RETRO_PIXEL_FORMAT_XRGB8888) rgb=((const uint32_t*)row)[x];
        else { uint16_t p=((const uint16_t*)row)[x];
            unsigned r,g,b;
            if(pixelFormat==RETRO_PIXEL_FORMAT_RGB565) {r=(p>>11)*255/31;g=((p>>5)&63)*255/63;b=(p&31)*255/31;}
            else {r=((p>>10)&31)*255/31;g=((p>>5)&31)*255/31;b=(p&31)*255/31;}
            rgb=(r<<16)|(g<<8)|b;
        } pixels[y*w+x]=rgb|0xFF000000; // BGRA on little-endian iOS.
    }
}
// VETA165_DEFERRED_VIDEO_END
static size_t audio_batch(const int16_t *data,size_t count) {
    unsigned w=atomic_load_explicit(&audioWrite,memory_order_relaxed);
    unsigned r=atomic_load_explicit(&audioRead,memory_order_acquire);
    size_t dropped=0,nonzero=0;
    for(size_t i=0;i<count;i++) {
        if(data[i*2] || data[i*2+1]) nonzero++;
        if(w-r<AUDIO_CAPACITY) {audioRing[w&(AUDIO_CAPACITY-1)][0]=data[i*2];audioRing[w&(AUDIO_CAPACITY-1)][1]=data[i*2+1];w++;}
        else dropped++;
    }
    atomic_fetch_add_explicit(&audioDropped,dropped,memory_order_relaxed);
    atomic_store_explicit(&audioWrite,w,memory_order_release);
    atomic_fetch_add_explicit(&audioNonzero,nonzero,memory_order_relaxed);
    atomic_fetch_add_explicit(&audioFrames,count,memory_order_relaxed);return count;
}
static void audio_sample(int16_t l,int16_t r) {int16_t pair[]={l,r};audio_batch(pair,1);}
static void input_poll(void) {}
static int16_t input_state(unsigned port,unsigned device,unsigned index,unsigned id) {
    if(port>=veta_max_players(activeConsole)) return 0;
    if(device==RETRO_DEVICE_ANALOG && index<2 && id<2) {
        uint64_t pointer=atomic_load_explicit(&pointerState,memory_order_relaxed);
        if(activeConsole==18 && port==0 && index==1 && (pointer&(1ull<<32)))
            return (int16_t)(uint16_t)(pointer>>(id*16));
        uint32_t pair=atomic_load_explicit(&analogPairs[port][index],memory_order_relaxed);
        return (int16_t)(uint16_t)(pair>>(id*16));
    }
    if(device==RETRO_DEVICE_POINTER && port==0 && index==0) {
        uint64_t pointer=atomic_load_explicit(&pointerState,memory_order_relaxed);
        if(id==RETRO_DEVICE_ID_POINTER_X)return (int16_t)(uint16_t)pointer;
        if(id==RETRO_DEVICE_ID_POINTER_Y)return (int16_t)(uint16_t)(pointer>>16);
        if(id==RETRO_DEVICE_ID_POINTER_PRESSED)return (pointer>>32)&1;
    }
    if(device!=RETRO_DEVICE_JOYPAD)return 0;
    uint16_t mask=(uint16_t)atomic_load_explicit(&inputMasks[port],memory_order_relaxed);
    if(id==RETRO_DEVICE_ID_JOYPAD_MASK) return mask;
    return id<16 && (mask&(1u<<id)) ? 1:0;
}
bool veta_load(const char *path,const char *dir,const char *reg) {return veta_load_console(path,dir,reg,0);}
bool veta_load_console(const char *path,const char *dir,const char *reg,unsigned console) {return veta_load_system(path,dir,dir,reg,console);}
bool veta_load_system(const char *path,const char *dir,const char *system,const char *reg,unsigned console) {return veta_load_system_mode(path,dir,system,reg,console,false);}
bool veta_load_system_mode(const char *path,const char *dir,const char *system,const char *reg,unsigned console,bool interpreter) {
    if(interpreter && console!=15 && console!=16 && console!=17 && console!=18)return false;
    veta_unload();shutdownRequested=false;interpreterExecution=interpreter;
    runProfile=(VetaRunProfile){.enabled=runProfileRequested && console==16};
    veta_vk_profile_reset(runProfile.enabled);
    guestFPUValid=false;GUEST_FPU_SCOPE;activeConsole=console;configure_video_readback();
    activeOptionCount=pendingOptionCount;memcpy(activeOptions,pendingOptions,sizeof(activeOptions));veta_options_clear();optionsChanged=activeOptionCount>0;
    const char *extension=strrchr(path,'.');
    gameCubeExecutable=console==17 && extension && (!strcmp(extension,".dol") || !strcmp(extension,".elf"));
    #ifdef VETA_JIT_LAB
    const VetaCoreAPI *selected=veta_external_core_mode(console,interpreterExecution);
#else
    const VetaCoreAPI *selected=console==0 ? &nesAPI:console>=2 && console<=4 ? &mgbaAPI:veta_external_core_mode(console,interpreterExecution);
#endif
    if(!selected)return false;core=selected;
    pixelFormat=RETRO_PIXEL_FORMAT_0RGB1555;width=256;height=240;snprintf(directory,sizeof(directory),"%s",dir);snprintf(systemDirectory,sizeof(systemDirectory),"%s",system);snprintf(region,sizeof(region),"%s",reg);
    memset(pixels,0,sizeof(pixels));frames=audioFrames=audioNonzero=0;defaultCount=0;
    atomic_store(&audioDelivered,0);atomic_store(&audioUnderruns,0);atomic_store(&audioDropped,0);
    core->set_environment(environment);core->set_video_refresh(video);core->set_audio_sample(audio_sample);
    core->set_audio_sample_batch(audio_batch);core->set_input_poll(input_poll);core->set_input_state(input_state);
    core->init();initialized=true;
    struct retro_system_info systemInfo={0};core->get_system_info(&systemInfo);
    struct retro_game_info game={.path=path};void *bytes=NULL;
    if(!systemInfo.need_fullpath) {
        FILE *f=fopen(path,"rb");if(!f){veta_unload();return false;}
        fseek(f,0,SEEK_END);long length=ftell(f);rewind(f);
        if(length<16 || length>256*1024*1024){fclose(f);veta_unload();return false;}
        bytes=malloc(length);if(!bytes){fclose(f);veta_unload();return false;}
        bool readOK=fread(bytes,1,length,f)==(size_t)length;fclose(f);
        if(!readOK){free(bytes);veta_unload();return false;}
        game.data=bytes;game.size=(size_t)length;
    }
    loaded=core->load_game(&game);free(bytes);
    if(!loaded){veta_unload();return false;}
    // FCEUmm retains its cheat linked list across unload/deinit. The frontend
    // owns per-game persistence and applies its validated list after loading.
    if(activeConsole==0 && core->cheat_reset)core->cheat_reset();
    for(unsigned port=0;port<veta_max_players(console);port++)core->set_controller_port_device(port,console==18 ? ((3<<8)|RETRO_DEVICE_JOYPAD):RETRO_DEVICE_JOYPAD);
    if(console==18)core->set_controller_port_device(1,RETRO_DEVICE_NONE);
    struct retro_system_av_info info;core->get_system_av_info(&info);
    fps=info.timing.fps;sampleRate=info.timing.sample_rate;veta_hw_size(info.geometry.base_width,info.geometry.base_height);return true;
}
void veta_unload(void) {
    GUEST_FPU_SCOPE;
    veta_hw_make_current();
    flush_pending_video();
    // PSP joins its loader; Dolphin stops and joins its CPU thread here, before
    // context_destroy can release resources that the worker still references.
    if(loaded && core->prepare_unload){
        // Cancellation can precede the first retro_run. Complete context_reset
        // first so a pending GPU initialization has a valid draw context.
        veta_hw_begin();
        core->prepare_unload();
    }
    invalidate_deferred_video();
    // Mupen's deinit resumes its core coroutine to stop GLideN64. Play! also
    // drains GL during deinit; Vulkan cores own resources until unload.
    bool deferredHardware=activeConsole==12 || activeConsole==19 || veta_vk_active();
    if(veta_vk_active())veta_vk_release_core();
    if(!deferredHardware)veta_hw_destroy();
    if(loaded){if(activeConsole==0 && core->cheat_reset)core->cheat_reset();core->unload_game();}
    if(initialized)core->deinit();
    if(deferredHardware)veta_hw_destroy();
    loaded=initialized=false;activeOptionCount=0;optionsChanged=false;
    for(unsigned port=0;port<4;port++) {
        veta_set_input(port,0);
        for(unsigned stick=0;stick<2;stick++)veta_set_analog(port,stick,0,0);
    }
    veta_set_pointer(0,0,false);veta_rumble_clear();veta_audio_clear();
}
void veta_run(void) {
    videoReadbackRunFinal=videoReadbackNextFinal;videoReadbackNextFinal=true;
    if(loaded && !shutdownRequested){
        GUEST_FPU_SCOPE;
        if(runProfile.enabled) {
            uint64_t start=run_profile_clock();veta_hw_begin();uint64_t end=run_profile_clock();
            if(start && end>=start)runProfile.hardware_begin_ns+=end-start;
            start=run_profile_clock();core->run();end=run_profile_clock();
            if(start && end>=start)runProfile.core_run_ns+=end-start;
            runProfile.core_run_count++;
        } else {veta_hw_begin();core->run();}
        // PPSSPP returns immediately while its asynchronous loader is active.
        // Those polls are not emulated frames. Its first PCM callback marks
        // completed boot, including legitimately silent introductory screens.
        if(!shutdownRequested && (activeConsole!=14 || audioFrames>0))frames++;
        if(frames==1)refresh_dolphin_timing();
    }
    videoReadbackRunFinal=true;
}
void veta_reset(void) {GUEST_FPU_SCOPE;if(loaded){flush_pending_video();shutdownRequested=false;core->reset();invalidate_deferred_video();}}
void veta_set_input(unsigned port,uint16_t mask) {if(port<4)atomic_store_explicit(&inputMasks[port],mask,memory_order_relaxed);}
uint16_t veta_input_mask(unsigned port){return port<4?(uint16_t)atomic_load_explicit(&inputMasks[port],memory_order_relaxed):0;}
const uint32_t *veta_video(void){
    if(videoReadback.pending || sharedVideoImage){
        GUEST_FPU_SCOPE;flush_pending_video();
        if(sharedVideoImage && !veta_hw_shared_copy(pixels,width,height,&sharedPixelsGeneration,&sharedPixelsSequence)) {
            // The current publication is the completed output FBO on this owner
            // thread. If its lease cannot be read, materialize this same frame.
            if(veta_hw_read(pixels,width,height))sharedVideoImage=false;
        }
    }
    return pixels;
}
VetaSharedFrame veta_shared_frame_acquire(void *metalDevice) {
    VetaSharedFrame result={.width=width,.height=height};
    if(!sharedVideoRequested)return result; // Default/other consoles: no GL/CV work.
    GUEST_FPU_SCOPE;
    bool sameDevice=veta_hw_shared_set_device(metalDevice);
    flush_pending_video();result.width=width;result.height=height;
    if(sharedVideoImage && sameDevice){
        VetaSharedFrame shared=veta_hw_shared_acquire();
        if(shared.lease)return shared;
    }
    return result; // Caller uses veta_video(), which materializes the same frame.
}
unsigned veta_width(void){return width;} unsigned veta_height(void){return height;}
double veta_fps(void){return fps;} double veta_sample_rate(void){return sampleRate;}
uint64_t veta_frame_count(void){return frames;} uint64_t veta_audio_count(void){return atomic_load_explicit(&audioFrames,memory_order_relaxed);}
uint64_t veta_audio_nonzero(void){return atomic_load_explicit(&audioNonzero,memory_order_relaxed);}
uint64_t veta_audio_delivered(void){return atomic_load_explicit(&audioDelivered,memory_order_relaxed);}
uint64_t veta_audio_underruns(void){return atomic_load_explicit(&audioUnderruns,memory_order_relaxed);}
uint64_t veta_audio_dropped(void){return atomic_load_explicit(&audioDropped,memory_order_relaxed);}
unsigned veta_audio_queued(void){
    unsigned r=atomic_load_explicit(&audioRead,memory_order_acquire),w=atomic_load_explicit(&audioWrite,memory_order_acquire);
    unsigned queued=w-r;return queued>AUDIO_CAPACITY ? AUDIO_CAPACITY:queued;
}
size_t veta_state_size(void){GUEST_FPU_SCOPE;flush_pending_video();return loaded?core->serialize_size():0;}
bool veta_save_state(void *data,size_t size){GUEST_FPU_SCOPE;flush_pending_video();return loaded && core->serialize(data,size);}
bool veta_load_state(const void *data,size_t size){GUEST_FPU_SCOPE;flush_pending_video();bool ok=loaded && core->unserialize(data,size);invalidate_deferred_video();if(ok)refresh_dolphin_timing();return ok;}
size_t veta_ram_size(void){return loaded?core->get_memory_size(RETRO_MEMORY_SAVE_RAM):0;}
void veta_read_ram(void *data,size_t size){size_t n=veta_ram_size();void*p=core->get_memory_data(RETRO_MEMORY_SAVE_RAM);if(p && size==n)memcpy(data,p,n);}
bool veta_write_ram(const void *data,size_t size){size_t n=veta_ram_size();void*p=core->get_memory_data(RETRO_MEMORY_SAVE_RAM);if(!p)return false;
    if(size!=n) {
        // GBA autodetection reserves 128 KiB before the cartridge selects SRAM,
        // EEPROM or Flash. Restore the previous save into that same backing store.
        if(activeConsole!=4 || n!=131072 || !(size==512 || size==8192 || size==32768 || size==65536))return false;
        memset(p,0xff,n);
    }
    memcpy(p,data,size);return true;}
void veta_audio_read(float *left,float *right,unsigned count,float volume){
    unsigned r=atomic_load_explicit(&audioRead,memory_order_relaxed),w=atomic_load_explicit(&audioWrite,memory_order_acquire);
    unsigned available=w-r,delivered=available<count ? available:count;
    for(unsigned i=0;i<count;i++){float l=0,rr=0;if(r!=w){l=audioRing[r&(AUDIO_CAPACITY-1)][0]/32768.0f;rr=audioRing[r&(AUDIO_CAPACITY-1)][1]/32768.0f;r++;}left[i]=l*volume;right[i]=rr*volume;}
    atomic_store_explicit(&audioRead,r,memory_order_release);
    atomic_fetch_add_explicit(&audioDelivered,delivered,memory_order_relaxed);
    atomic_fetch_add_explicit(&audioUnderruns,count-delivered,memory_order_relaxed);
}
// Call only when the audio engine is stopped (consumer not running).
void veta_audio_clear(void){atomic_store(&audioRead,0);atomic_store(&audioWrite,0);}

size_t veta_rtc_size(void){return loaded?core->get_memory_size(RETRO_MEMORY_RTC):0;}
void veta_read_rtc(void *data,size_t size){if(!loaded)return;void *p=core->get_memory_data(RETRO_MEMORY_RTC);if(p && size==veta_rtc_size())memcpy(data,p,size);}
bool veta_write_rtc(const void *data,size_t size){if(!loaded)return false;void *p=core->get_memory_data(RETRO_MEMORY_RTC);if(!p || size!=veta_rtc_size())return false;memcpy(p,data,size);return true;}

void veta_set_pointer(int16_t x,int16_t y,bool pressed){
    uint64_t value=(uint16_t)x|((uint64_t)(uint16_t)y<<16)|((uint64_t)pressed<<32);
    atomic_store_explicit(&pointerState,value,memory_order_relaxed);
}
void veta_set_analog(unsigned port,unsigned stick,int16_t x,int16_t y){
    if(port<4 && stick<2) {
        uint32_t value=(uint16_t)x|((uint32_t)(uint16_t)y<<16);
        atomic_store_explicit(&analogPairs[port][stick],value,memory_order_relaxed);
    }
}

static bool cheat_hex(char c) {return (c>='0'&&c<='9')||(c>='A'&&c<='F');}
bool veta_nes_cheat_valid(const char *code) {
    if(!code)return false;
    size_t n=strnlen(code,11);
    if(n==7&&code[4]==':') {for(size_t i=0;i<n;i++)if(i!=4&&!cheat_hex(code[i]))return false;return true;}
    if(n!=6&&n!=8)return false;
    for(size_t i=0;i<n;i++)if(!strchr("APZLGITYEOXUKSVN",code[i]))return false;
    return true;
}
bool veta_nes_cheats_replace(const char *const *codes,size_t count) {
    if(!loaded||activeConsole!=0||!core->cheat_reset||!core->cheat_set||count>16||(!codes&&count))return false;
    for(size_t i=0;i<count;i++)if(!veta_nes_cheat_valid(codes[i]))return false;
    GUEST_FPU_SCOPE;core->cheat_reset();
    for(size_t i=0;i<count;i++)core->cheat_set((unsigned)i,true,codes[i]);
    return true;
}
