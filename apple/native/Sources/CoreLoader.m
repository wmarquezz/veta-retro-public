#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include "CoreAPI.h"

#if defined(VETA_JIT_LAB) || defined(VETA_JIT_DEVELOPMENT)
extern bool veta_execution_allows_jit(void);
extern bool veta_jit_pool_alloc(size_t,void**,void**);
static bool execution_pool_alloc(size_t size,void **rw,void **rx) {
    return veta_execution_allows_jit() && veta_jit_pool_alloc(size,rw,rx);
}
#endif

// Bundled, signed frameworks only. RTLD_FIRST isolates each engine's global C
// symbols from both the app and the other engines; never load user-supplied code.
const VetaCoreAPI *veta_external_core(unsigned console) {return veta_external_core_mode(console,false);}
const VetaCoreAPI *veta_external_core_mode(unsigned console,bool interpreter) {
    unsigned index;
    switch (console) {
        case 1:index=14;break;
        case 5: case 6: case 7:index=0;break;
        case 8:index=1;break;case 9:index=2;break;case 10:index=3;break;
        case 11:index=4;break;case 12:index=5;break;case 13:index=6;break;case 14:index=7;break;
        case 15:index=8;break;case 16:index=9;break;case 17:case 18:index=10;break;case 19:index=11;break;case 20:index=12;break;
        default:return NULL;
    }
    static void *handles[15];static VetaCoreAPI apis[15];
    static NSString *names[]={@"JGenesisCore",@"StellaCore",@"PCECore",@"PlayStationCore",@"DSCore",@"N64NextCore",@"SaturnCore",@"PSPCore",@"DreamcastCore",@"ThreeDSCore",@"DolphinCore",@"PS2Core",@"MelonDSCore",@"DreamcastInterpreterCore",@"BSNESCore"};
    if(console==15 && interpreter)index=13;
    if(handles[index])return &apis[index];
    NSString *name=names[index];
#if defined(VETA_ATARI_TIA)
    if(console==8)name=@"TIACore";
#endif
    NSString *path=[[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.framework/%@",name,name]];
    void *handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    if(!handle){NSLog(@"VETA core %@: %s",name,dlerror());return NULL;}
#if defined(VETA_JIT_LAB) || defined(VETA_JIT_DEVELOPMENT)
    extern bool veta_jit_pool_alloc(size_t,void**,void**);
    extern bool veta_jit_pool_free(void*);
    void (*setAllocator)(bool(*)(size_t,void**,void**),bool(*)(void*))=dlsym(handle,"veta_set_jit_allocator");
    if(setAllocator)setAllocator(execution_pool_alloc,veta_jit_pool_free);
#endif
    VetaCoreAPI *api=&apis[index];
#define LOAD(field) api->field=dlsym(handle,"retro_" #field);if(!api->field){dlclose(handle);return NULL;}
    LOAD(init);LOAD(deinit);LOAD(set_environment);LOAD(set_video_refresh);
    LOAD(set_audio_sample);LOAD(set_audio_sample_batch);LOAD(set_input_poll);LOAD(set_input_state);
    LOAD(load_game);LOAD(unload_game);LOAD(set_controller_port_device);LOAD(get_system_av_info);LOAD(get_system_info);
    LOAD(run);LOAD(reset);LOAD(serialize_size);LOAD(serialize);LOAD(unserialize);LOAD(get_memory_size);LOAD(get_memory_data);
#undef LOAD
    // Optional upstream callbacks do not imply verified cheat support.
    api->cheat_reset=dlsym(handle,"retro_cheat_reset");api->cheat_set=dlsym(handle,"retro_cheat_set");
    api->prepare_unload=dlsym(handle,"veta_prepare_unload");
    handles[index]=handle;return api;
}
