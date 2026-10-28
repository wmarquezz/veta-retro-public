#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#include <dlfcn.h>
#include <string.h>
#include <fenv.h>
#include "CoreAPI.h"
#include "HardwareVulkan.h"
#include "NESBridge.h"
#if VETA_JIT_DEVELOPMENT
#import "SharedFrame.h"
#endif

static EAGLContext *context;
static struct retro_hw_render_callback callback;
static GLuint framebuffer,color,depth;
static bool reset;
static uint8_t readback[2048*2048*4];
// VETA165_SHARED_GL_BEGIN: owner/main thread; completion only releases leases.
#if VETA_JIT_DEVELOPMENT
static bool sharedRequested;
static id<MTLDevice> sharedDevice;
static VetaSharedFramePool *sharedPool, *retiredSharedPool;
static EAGLContext *retiredSharedContext;
static unsigned sharedWidth, sharedHeight;
static uint64_t sharedGeneration, sharedSequence;
static bool sharedCollectionScheduled;
static VetaSharedVideoProfile sharedProfile;
static void collect_retired_shared_pool(void);
static void schedule_shared_collection(void) {
    if(!retiredSharedPool || sharedCollectionScheduled)return;
    sharedCollectionScheduled=true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        sharedCollectionScheduled=false;collect_retired_shared_pool();schedule_shared_collection();
    });
}
static void collect_retired_shared_pool(void) {
    if(!retiredSharedPool || ![NSThread isMainThread])return;
    // This also runs from a dispatch timer, outside the bridge guest scope.
    // Retiring GL resources must not leak driver FP modes into UIKit.
    fenv_t hostFPU;fegetenv(&hostFPU);
    EAGLContext *previous=EAGLContext.currentContext;
    [EAGLContext setCurrentContext:retiredSharedContext];
    if([retiredSharedPool retire]){retiredSharedPool=nil;retiredSharedContext=nil;}
    [EAGLContext setCurrentContext:previous];fesetenv(&hostFPU);
}
static void retire_shared_pool(void) {
    if(!sharedPool)return;
    // No new pool may allocate while a retired one remains, so total live CV
    // backing stays within one pool's 64MiB bound, even across context reloads.
    NSCAssert(!retiredSharedPool,@"Only one shared pool may remain outstanding");
    if(![sharedPool retire]){retiredSharedPool=sharedPool;retiredSharedContext=context;schedule_shared_collection();}
    sharedPool=nil;sharedWidth=sharedHeight=0;sharedProfile.generation=sharedProfile.sequence=0;
}
#endif
void veta_hw_shared_configure(bool requested) {
#if VETA_JIT_DEVELOPMENT
    sharedRequested=requested && [NSThread isMainThread];
    sharedProfile=(VetaSharedVideoProfile){.requested=sharedRequested};
    collect_retired_shared_pool();
#else
    (void)requested;
#endif
}
bool veta_hw_shared_active(void) {
#if VETA_JIT_DEVELOPMENT
    return sharedRequested && context && context.API==kEAGLRenderingAPIOpenGLES3 && [NSThread isMainThread];
#else
    return false;
#endif
}
bool veta_hw_shared_set_device(void *device) {
#if VETA_JIT_DEVELOPMENT
    if(!veta_hw_shared_active() || !device)return false;
    id<MTLDevice> candidate=(__bridge id<MTLDevice>)device;
    if(sharedDevice && sharedDevice!=candidate)return false;
    sharedDevice=candidate;return true;
#else
    (void)device;return false;
#endif
}
bool veta_hw_shared_publish(unsigned width,unsigned height) {
#if VETA_JIT_DEVELOPMENT
    if(!veta_hw_shared_active() || !sharedDevice || !width || !height || width>2048 || height>2048)return false;
    [EAGLContext setCurrentContext:context];collect_retired_shared_pool();
    if(sharedPool && (sharedWidth!=width || sharedHeight!=height))retire_shared_pool();
    if(retiredSharedPool){sharedProfile.fallbacks++;return false;}
    if(!sharedPool){
        NSUInteger count=MIN((NSUInteger)8,(NSUInteger)(64*1024*1024)/((NSUInteger)width*height*4));
        if(count<2){sharedProfile.fallbacks++;return false;}
        sharedPool=[[VetaSharedFramePool alloc] initWithContext:context device:sharedDevice width:width height:height slots:count generation:++sharedGeneration];
        if(!sharedPool){sharedProfile.fallbacks++;return false;}
        sharedWidth=width;sharedHeight=height;
    }
    if(![sharedPool publishFramebuffer:framebuffer bottomLeftOrigin:callback.bottom_left_origin sequence:++sharedSequence]){sharedProfile.fallbacks++;return false;}
    sharedProfile.publications++;sharedProfile.generation=sharedGeneration;sharedProfile.sequence=sharedSequence;return true;
#else
    (void)width;(void)height;return false;
#endif
}
VetaSharedFrame veta_hw_shared_acquire(void) {
    VetaSharedFrame result={0};
#if VETA_JIT_DEVELOPMENT
    if(!veta_hw_shared_active() || !sharedPool)return result;
    [EAGLContext setCurrentContext:context];
    VetaSharedFrameLease *lease=[sharedPool acquireForDevice:sharedDevice];
    if(!lease)return result;
    result.width=(unsigned)lease.texture.width;result.height=(unsigned)lease.texture.height;
    result.texture=(__bridge void *)lease.texture;result.generation=lease.generation;result.sequence=lease.sequence;
    result.lease=(__bridge_retained void *)lease;sharedProfile.acquisitions++;
#endif
    return result;
}
void veta_shared_frame_release(void *opaque) {
#if VETA_JIT_DEVELOPMENT
    if(opaque){VetaSharedFrameLease *lease=CFBridgingRelease(opaque);[lease finish];}
#else
    (void)opaque;
#endif
}
bool veta_hw_shared_copy(uint32_t *pixels,unsigned width,unsigned height,uint64_t *generation,uint64_t *sequence) {
#if VETA_JIT_DEVELOPMENT
    if(!veta_hw_shared_active() || !sharedPool)return false;
    [EAGLContext setCurrentContext:context];
    VetaSharedFrameLease *lease=[sharedPool acquireForDevice:sharedDevice];if(!lease)return false;
    bool ok=lease.texture.width==width && lease.texture.height==height;
    if(ok && (*generation!=lease.generation || *sequence!=lease.sequence)){
        NSData *data=[sharedPool copyBGRA:lease];ok=data && data.length==(NSUInteger)width*height*4;
        if(ok){memcpy(pixels,data.bytes,data.length);*generation=lease.generation;*sequence=lease.sequence;sharedProfile.snapshots++;}
    }
    [lease finish];return ok;
#else
    (void)pixels;(void)width;(void)height;(void)generation;(void)sequence;return false;
#endif
}
VetaSharedVideoProfile veta_shared_video_profile(void) {
#if VETA_JIT_DEVELOPMENT
    VetaSharedVideoProfile result=sharedProfile;result.active=veta_hw_shared_active();
    result.allocated_bytes=sharedPool.allocatedBytes;result.retired_bytes=retiredSharedPool.allocatedBytes;return result;
#else
    return (VetaSharedVideoProfile){0};
#endif
}
// VETA165_SHARED_GL_END
static uintptr_t get_framebuffer(void){return framebuffer;}
static retro_proc_address_t get_proc(const char *symbol){return (retro_proc_address_t)dlsym(RTLD_DEFAULT,symbol);}
bool veta_hw_setup(struct retro_hw_render_callback *request) {
    if(context || veta_vk_active())return false;
    if(request->context_type==RETRO_HW_CONTEXT_VULKAN)return veta_vk_setup(request);
    EAGLRenderingAPI api;
    switch(request->context_type){
        case RETRO_HW_CONTEXT_OPENGLES2:api=kEAGLRenderingAPIOpenGLES3;break;
        case RETRO_HW_CONTEXT_OPENGLES3:api=kEAGLRenderingAPIOpenGLES3;break;
        case RETRO_HW_CONTEXT_OPENGLES_VERSION:
            if(request->version_major>3 || request->version_minor>0)return false;
            api=request->version_major>=3?kEAGLRenderingAPIOpenGLES3:kEAGLRenderingAPIOpenGLES2;break;
        default:return false;
    }
    context=[[EAGLContext alloc] initWithAPI:api];if(!context)return false;
    [EAGLContext setCurrentContext:context];
    glGenFramebuffers(1,&framebuffer);glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);
    glGenTextures(1,&color);glBindTexture(GL_TEXTURE_2D,color);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,2048,2048,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,color,0);
    if(request->depth || request->stencil){
        glGenRenderbuffers(1,&depth);glBindRenderbuffer(GL_RENDERBUFFER,depth);
        glRenderbufferStorage(GL_RENDERBUFFER,request->stencil?GL_DEPTH24_STENCIL8:GL_DEPTH_COMPONENT16,2048,2048);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_RENDERBUFFER,depth);
        if(request->stencil)glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_STENCIL_ATTACHMENT,GL_RENDERBUFFER,depth);
    }
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){
        glDeleteTextures(1,&color);glDeleteRenderbuffers(1,&depth);glDeleteFramebuffers(1,&framebuffer);
        color=depth=framebuffer=0;[EAGLContext setCurrentContext:nil];context=nil;return false;
    }
    request->get_current_framebuffer=get_framebuffer;request->get_proc_address=get_proc;
    callback=*request;reset=false;return true;
}
void veta_hw_size(unsigned width,unsigned height){
    if(!context || !width || !height || width>2048 || height>2048)return;
    [EAGLContext setCurrentContext:context];
#if VETA_JIT_DEVELOPMENT
    if(sharedPool && (sharedWidth!=width || sharedHeight!=height))retire_shared_pool();
#endif
    glBindTexture(GL_TEXTURE_2D,color);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,width,height,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
    if(depth){glBindRenderbuffer(GL_RENDERBUFFER,depth);glRenderbufferStorage(GL_RENDERBUFFER,callback.stencil?GL_DEPTH24_STENCIL8:GL_DEPTH_COMPONENT16,width,height);}
    glViewport(0,0,width,height);
}
// Teardown may follow a UI pause without another frame. Keep the existing
// context current without invoking context_reset or starting an unrun core.
void veta_hw_make_current(void){if(context)[EAGLContext setCurrentContext:context];}
void veta_hw_begin(void){
    if(veta_vk_active()){veta_vk_begin();return;}
    if(!context)return;
    [EAGLContext setCurrentContext:context];
    // Cores cache their GL bindings. Do not replace the core's draw target
    // between frames without informing that cache (Dolphin keeps its EFB).
    if(!reset){glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);reset=true;if(callback.context_reset)callback.context_reset();}
}
bool veta_hw_read(uint32_t *pixels,unsigned width,unsigned height){
    if(veta_vk_active())return veta_vk_read(pixels,width,height);
    if(!context || !width || !height || width>2048 || height>2048)return false;
    [EAGLContext setCurrentContext:context];
    const bool es3=context.API==kEAGLRenderingAPIOpenGLES3;
    const GLenum readTarget=es3?GL_READ_FRAMEBUFFER:GL_FRAMEBUFFER;
    GLint previousRead=0,alignment=0,rowLength=0,skipRows=0,skipPixels=0;
    glGetIntegerv(es3?GL_READ_FRAMEBUFFER_BINDING:GL_FRAMEBUFFER_BINDING,&previousRead);
    glGetIntegerv(GL_PACK_ALIGNMENT,&alignment);
    if(es3){glGetIntegerv(GL_PACK_ROW_LENGTH,&rowLength);glGetIntegerv(GL_PACK_SKIP_ROWS,&skipRows);glGetIntegerv(GL_PACK_SKIP_PIXELS,&skipPixels);}
    glBindFramebuffer(readTarget,framebuffer);
    while(glGetError()!=GL_NO_ERROR){}
    glPixelStorei(GL_PACK_ALIGNMENT,1);
    if(es3){glPixelStorei(GL_PACK_ROW_LENGTH,0);glPixelStorei(GL_PACK_SKIP_ROWS,0);glPixelStorei(GL_PACK_SKIP_PIXELS,0);}
    glReadPixels(0,0,width,height,GL_RGBA,GL_UNSIGNED_BYTE,readback);
    GLenum error=glGetError();
    glBindFramebuffer(readTarget,(GLuint)previousRead);glPixelStorei(GL_PACK_ALIGNMENT,alignment);
    if(es3){glPixelStorei(GL_PACK_ROW_LENGTH,rowLength);glPixelStorei(GL_PACK_SKIP_ROWS,skipRows);glPixelStorei(GL_PACK_SKIP_PIXELS,skipPixels);}
    if(error!=GL_NO_ERROR)return false;
    for(unsigned y=0;y<height;y++){
        unsigned sourceY=callback.bottom_left_origin?height-1-y:y;
        for(unsigned x=0;x<width;x++) {uint8_t *p=readback+(sourceY*width+x)*4;pixels[y*width+x]=0xff000000u|((uint32_t)p[0]<<16)|((uint32_t)p[1]<<8)|p[2];}
    }
    return true;
}
void veta_hw_destroy(void){
    if(veta_vk_active()){veta_vk_destroy();return;}
    if(!context)return;[EAGLContext setCurrentContext:context];
    if(reset && callback.context_destroy)callback.context_destroy();
#if VETA_JIT_DEVELOPMENT
    retire_shared_pool();sharedDevice=nil;sharedRequested=false;
#endif
    glDeleteTextures(1,&color);glDeleteRenderbuffers(1,&depth);glDeleteFramebuffers(1,&framebuffer);
    color=depth=framebuffer=0;reset=false;memset(&callback,0,sizeof(callback));
    [EAGLContext setCurrentContext:nil];context=nil;
}
