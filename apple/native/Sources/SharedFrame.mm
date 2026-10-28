#if VETA_JIT_DEVELOPMENT
#import "SharedFrame.h"
#import <CoreVideo/CoreVideo.h>
#include <atomic>
#if TARGET_OS_OSX
typedef CVOpenGLTextureCacheRef GLCache;
typedef CVOpenGLTextureRef GLImage;
#else
#import <OpenGLES/ES2/glext.h>
typedef CVOpenGLESTextureCacheRef GLCache;
typedef CVOpenGLESTextureRef GLImage;
#endif

@interface VetaPrototypeSlot : NSObject {
@public
 CVPixelBufferRef pixel;
 GLImage glImage;
 CVMetalTextureRef metalImage;
 GLuint fbo;
 std::atomic_uint readers;
 uint64_t sequence;
}
@property(nonatomic,strong) id<MTLTexture> texture;
@end
@implementation VetaPrototypeSlot
- (instancetype)init {if((self=[super init]))readers.store(0);return self;}
@end

@interface VetaSharedFrameLease () {
@public VetaPrototypeSlot *_slot;
 std::atomic_bool _finished;
}
- (instancetype)initWithSlot:(VetaPrototypeSlot *)slot generation:(uint64_t)generation;
@end
@implementation VetaSharedFrameLease
- (instancetype)initWithSlot:(VetaPrototypeSlot *)slot generation:(uint64_t)generation {
 if((self=[super init])) {_slot=slot;_generation=generation;_sequence=slot->sequence;_finished.store(false);slot->readers.fetch_add(1);}
 return self;
}
- (id<MTLTexture>)texture {NSAssert(!_finished.load(),@"finished lease");return _slot.texture;}
- (void)finish {if(!_finished.exchange(true))_slot->readers.fetch_sub(1);}
- (void)dealloc {[self finish];}
@end

// Save every state this component changes. It never changes core program/VAO,
// buffer bindings, viewport, depth/stencil, EFB attachment or source read buffer.
struct GLState {
 GLint read,draw,active,tex2D;
#if TARGET_OS_OSX
 GLint rectangle;GLboolean srgb;
#endif
 GLboolean scissor,mask[4];GLfloat clear[4];
 GLState() {
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&read);glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&draw);
  glGetIntegerv(GL_ACTIVE_TEXTURE,&active);glGetIntegerv(GL_TEXTURE_BINDING_2D,&tex2D);
#if TARGET_OS_OSX
  glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE,&rectangle);srgb=glIsEnabled(GL_FRAMEBUFFER_SRGB);
#endif
  scissor=glIsEnabled(GL_SCISSOR_TEST);glGetBooleanv(GL_COLOR_WRITEMASK,mask);glGetFloatv(GL_COLOR_CLEAR_VALUE,clear);
 }
 ~GLState() {
  glBindFramebuffer(GL_READ_FRAMEBUFFER,read);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,draw);
  glActiveTexture(active);glBindTexture(GL_TEXTURE_2D,tex2D);
#if TARGET_OS_OSX
  glBindTexture(GL_TEXTURE_RECTANGLE,rectangle);if(srgb)glEnable(GL_FRAMEBUFFER_SRGB);else glDisable(GL_FRAMEBUFFER_SRGB);
#endif
  if(scissor)glEnable(GL_SCISSOR_TEST);else glDisable(GL_SCISSOR_TEST);
  glColorMask(mask[0],mask[1],mask[2],mask[3]);glClearColor(clear[0],clear[1],clear[2],clear[3]);
 }
};

@implementation VetaSharedFramePool {
 VetaPrototypeGLContext *_context;
 id<MTLDevice> _device;
 NSThread *_owner;
 GLCache _glCache;
 CVMetalTextureCacheRef _metalCache;
 NSMutableArray<VetaPrototypeSlot *> *_slots;
 VetaPrototypeSlot *_latest;
 NSUInteger _width,_height,_allocationBytes;
 uint64_t _generation;
 BOOL _retired,_closed;
}
- (BOOL)ownerCurrent {
#if TARGET_OS_OSX
 return [NSThread currentThread]==_owner && NSOpenGLContext.currentContext==_context;
#else
 return [NSThread currentThread]==_owner && EAGLContext.currentContext==_context;
#endif
}
- (instancetype)initWithContext:(VetaPrototypeGLContext *)context device:(id<MTLDevice>)device width:(NSUInteger)width height:(NSUInteger)height slots:(NSUInteger)count generation:(uint64_t)generation {
 if(!(self=[super init]))return nil;
 _context=context;_device=device;_owner=NSThread.currentThread;_slots=[NSMutableArray array];
 _width=width;_height=height;_generation=generation;
 if(![self ownerCurrent] || !width || !height || width>2048 || height>2048 || !count || count>8 || width*height*4*count>64*1024*1024) {_closed=YES;return nil;}
 GLState saved;
 NSDictionary *attributes=@{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{},
   (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey:@YES,
#if TARGET_OS_OSX
   (__bridge NSString *)kCVPixelBufferOpenGLCompatibilityKey:@YES};
 CVReturn status=CVOpenGLTextureCacheCreate(kCFAllocatorDefault,NULL,context.CGLContextObj,context.pixelFormat.CGLPixelFormatObj,NULL,&_glCache);
#else
   (__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey:@YES};
 CVReturn status=CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,NULL,context,NULL,&_glCache);
#endif
 if(status!=kCVReturnSuccess || CVMetalTextureCacheCreate(kCFAllocatorDefault,NULL,device,NULL,&_metalCache)!=kCVReturnSuccess){[self retire];return nil;}
 for(NSUInteger i=0;i<count;i++) {
  VetaPrototypeSlot *slot=[VetaPrototypeSlot new];[_slots addObject:slot];
  if(CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&slot->pixel)!=kCVReturnSuccess){[self retire];return nil;}
  _allocationBytes += MAX(CVPixelBufferGetDataSize(slot->pixel),CVPixelBufferGetBytesPerRow(slot->pixel)*height);
  if(_allocationBytes>64*1024*1024){[self retire];return nil;}
  GLenum target;
#if TARGET_OS_OSX
  status=CVOpenGLTextureCacheCreateTextureFromImage(kCFAllocatorDefault,_glCache,slot->pixel,NULL,&slot->glImage);
  target=status==kCVReturnSuccess?CVOpenGLTextureGetTarget(slot->glImage):0;
  GLuint name=status==kCVReturnSuccess?CVOpenGLTextureGetName(slot->glImage):0;
#else
  status=CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,_glCache,slot->pixel,NULL,GL_TEXTURE_2D,GL_RGBA,(GLsizei)width,(GLsizei)height,GL_BGRA,GL_UNSIGNED_BYTE,0,&slot->glImage);
  target=status==kCVReturnSuccess?CVOpenGLESTextureGetTarget(slot->glImage):0;
  GLuint name=status==kCVReturnSuccess?CVOpenGLESTextureGetName(slot->glImage):0;
#endif
  if(status!=kCVReturnSuccess || !name){[self retire];return nil;}
  if(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,_metalCache,slot->pixel,NULL,MTLPixelFormatBGRA8Unorm,width,height,0,&slot->metalImage)!=kCVReturnSuccess){[self retire];return nil;}
  slot.texture=CVMetalTextureGetTexture(slot->metalImage);
  if(!slot.texture || slot.texture.device!=device){[self retire];return nil;}
  glGenFramebuffers(1,&slot->fbo);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,slot->fbo);
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,target,name,0);
  if(glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){[self retire];return nil;}
 }
 return self;
}
- (NSUInteger)allocatedBytes {return _allocationBytes;}
- (BOOL)publishFramebuffer:(GLuint)source bottomLeftOrigin:(BOOL)flip sequence:(uint64_t)sequence {
 if(![self ownerCurrent] || _retired || !source)return NO;
 VetaPrototypeSlot *slot=nil;
 for(VetaPrototypeSlot *candidate in _slots)if(candidate!=_latest && candidate->readers.load()==0){slot=candidate;break;}
 if(!slot)return NO; // Explicit caller fallback, never overwrite a lease.
 GLState saved;
 glDisable(GL_SCISSOR_TEST);
#if TARGET_OS_OSX
 glDisable(GL_FRAMEBUFFER_SRGB);
#endif
 glBindFramebuffer(GL_READ_FRAMEBUFFER,source);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,slot->fbo);
 if(glCheckFramebufferStatus(GL_READ_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)return NO;
 glBlitFramebuffer(0,0,(GLint)_width,(GLint)_height,0,flip?(GLint)_height:0,(GLint)_width,flip?0:(GLint)_height,GL_COLOR_BUFFER_BIT,GL_NEAREST);
 // Match veta_hw_read: opaque BGRA, row zero is the image's top row.
 glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_TRUE);glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
 glFlush(); // Apple's supported CV/GL-to-Metal publication sequence.
 // Caller owns a clean GL error boundary; do not drain unrelated errors.
 if(glGetError()!=GL_NO_ERROR)return NO;
 slot->sequence=sequence;_latest=slot;return YES;
}
- (VetaSharedFrameLease *)acquireForDevice:(id<MTLDevice>)device {
 if(![self ownerCurrent] || _retired || !_latest || device!=_device)return nil;
 return [[VetaSharedFrameLease alloc]initWithSlot:_latest generation:_generation];
}
- (NSData *)copyBGRA:(VetaSharedFrameLease *)lease {
 if(![self ownerCurrent] || _closed || lease.generation!=_generation || lease->_finished.load() || ![_slots containsObject:lease->_slot])return nil;
 GLState saved;GLint alignment,rowLength,skipRows,skipPixels,packBuffer;
 glGetIntegerv(GL_PACK_ALIGNMENT,&alignment);glGetIntegerv(GL_PACK_ROW_LENGTH,&rowLength);glGetIntegerv(GL_PACK_SKIP_ROWS,&skipRows);glGetIntegerv(GL_PACK_SKIP_PIXELS,&skipPixels);glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING,&packBuffer);
 glBindBuffer(GL_PIXEL_PACK_BUFFER,0);glPixelStorei(GL_PACK_ALIGNMENT,1);glPixelStorei(GL_PACK_ROW_LENGTH,0);glPixelStorei(GL_PACK_SKIP_ROWS,0);glPixelStorei(GL_PACK_SKIP_PIXELS,0);
 NSMutableData *data=[NSMutableData dataWithLength:_width*_height*4];
 glBindFramebuffer(GL_READ_FRAMEBUFFER,lease->_slot->fbo);glReadPixels(0,0,(GLsizei)_width,(GLsizei)_height,GL_RGBA,GL_UNSIGNED_BYTE,data.mutableBytes);
 GLenum error=glGetError();
 glBindBuffer(GL_PIXEL_PACK_BUFFER,packBuffer);glPixelStorei(GL_PACK_ALIGNMENT,alignment);glPixelStorei(GL_PACK_ROW_LENGTH,rowLength);glPixelStorei(GL_PACK_SKIP_ROWS,skipRows);glPixelStorei(GL_PACK_SKIP_PIXELS,skipPixels);
 if(error!=GL_NO_ERROR)return nil;
 uint8_t *p=(uint8_t *)data.mutableBytes;
 for(NSUInteger i=0;i<_width*_height;i++){uint8_t r=p[i*4];p[i*4]=p[i*4+2];p[i*4+2]=r;p[i*4+3]=255;}
 return data;
}
- (BOOL)retire {
 if(_closed)return YES;
 if(![self ownerCurrent])return NO;
 _retired=YES;_latest=nil;
 for(VetaPrototypeSlot *slot in _slots)if(slot->readers.load())return NO;
 // Drain outstanding producer commands only during retirement, never per frame.
 glFinish();
 // Only the owner thread frees CV/GL resources after all consumer completions.
 for(VetaPrototypeSlot *slot in _slots){if(slot->fbo)glDeleteFramebuffers(1,&slot->fbo);slot->fbo=0;slot.texture=nil;if(slot->metalImage)CFRelease(slot->metalImage);slot->metalImage=NULL;if(slot->glImage)CFRelease(slot->glImage);slot->glImage=NULL;if(slot->pixel)CFRelease(slot->pixel);slot->pixel=NULL;}
 [_slots removeAllObjects];_allocationBytes=0;if(_glCache)CFRelease(_glCache);_glCache=NULL;if(_metalCache)CFRelease(_metalCache);_metalCache=NULL;_closed=YES;return YES;
}
- (void)dealloc {NSAssert(_closed,@"Owner must retire and collect pool before releasing it");}
@end

#endif // VETA_JIT_DEVELOPMENT
