#if VETA_JIT_DEVELOPMENT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <OpenGL/gl3.h>
typedef NSOpenGLContext VetaPrototypeGLContext;
#else
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
typedef EAGLContext VetaPrototypeGLContext;
#endif
NS_ASSUME_NONNULL_BEGIN
@class VetaSharedFrameLease;
/// Isolated, opt-in prototype. All pool methods run on the creating GL thread.
/// Keep the pool alive until retire returns YES. Metal completion only releases
/// leases; it never deletes GL objects or calls back to the main thread.
@interface VetaSharedFramePool : NSObject
- (nullable instancetype)initWithContext:(VetaPrototypeGLContext *)context
                                 device:(id<MTLDevice>)device width:(NSUInteger)width
                                 height:(NSUInteger)height slots:(NSUInteger)count
                             generation:(uint64_t)generation;
/// Copies and normalizes the source with one GPU blit. NO CPU pixel transfer.
/// Failure/exhaustion requires the caller's ordinary CPU publication fallback.
- (BOOL)publishFramebuffer:(GLuint)source bottomLeftOrigin:(BOOL)flip sequence:(uint64_t)sequence;
- (nullable VetaSharedFrameLease *)acquireForDevice:(id<MTLDevice>)device;
/// Lazy CPU snapshot of THIS lease, not the current core output framebuffer.
- (nullable NSData *)copyBGRA:(VetaSharedFrameLease *)lease;
/// Retires publication and clears latest; returns NO while consumers remain.
- (BOOL)retire;
@property(nonatomic,readonly) NSUInteger allocatedBytes;
@end
@interface VetaSharedFrameLease : NSObject
@property(nonatomic,readonly) id<MTLTexture> texture;
@property(nonatomic,readonly) uint64_t sequence;
@property(nonatomic,readonly) uint64_t generation;
/// Call from command-buffer completion or immediately after an unsubmitted path.
/// Idempotent; texture must never be used after this call.
- (void)finish;
@end
NS_ASSUME_NONNULL_END

#endif // VETA_JIT_DEVELOPMENT
