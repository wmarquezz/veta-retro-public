#if VETA_JIT_DEVELOPMENT
import UIKit

@MainActor protocol ExternalSurfaceRouting:AnyObject {
    var aspect:CGFloat {get}
    var televisionPixelLimit:CGSize {get set}
    var televisionScale:CGFloat {get set}
    func route(to:UIView?)
    func layout()
}

/// Moves one existing surface between hosts. The emulator keeps its original
/// CAMetalLayer; no second session, framebuffer copy or video stream is created.
@MainActor final class NativeSurfaceRouter:ExternalSurfaceRouting {
    let surface:NativeMetalSurface
    private weak var localHost:UIView?
    private weak var externalHost:UIView?
    var televisionPixelLimit=CGSize(width:1280,height:720)
    var televisionScale:CGFloat = 1
    let aspect:CGFloat
    var onRoutingChanged:((Bool)->Void)?
    var isExternal:Bool {externalHost != nil}
    init(surface:NativeMetalSurface,localHost:UIView,aspect:CGFloat) {
        self.surface=surface;self.localHost=localHost;self.aspect=max(0.1,aspect)
        route(to:nil)
    }
    func route(to external:UIView?) {
        let changed=externalHost !== external
        externalHost=external
        guard let destination=external ?? localHost else{return}
        if surface.superview !== destination {surface.removeFromSuperview();destination.addSubview(surface)}
        // A connected 4K TV must not silently quadruple the emulator workload.
        surface.drawablePixelLimit=external == nil ? nil:televisionPixelLimit
        layout()
        if changed {onRoutingChanged?(external != nil)}
    }
    func layout() {
        guard let host=externalHost ?? localHost else{return}
        let bounds=host.bounds
        // UIKit can attach a scene before its first nonzero layout. Keep the
        // current render dimensions until the destination has real bounds.
        guard bounds.width>0,bounds.height>0 else{return}
        surface.frame=TVImageGeometry.frame(in:bounds,aspect:aspect,scale:isExternal ? televisionScale:1)
        surface.contentScaleFactor=host.window?.screen.scale ?? UIScreen.main.scale
        surface.setNeedsLayout();surface.layoutIfNeeded()
    }
}
#endif
