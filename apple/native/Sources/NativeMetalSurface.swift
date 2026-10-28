#if VETA_JIT_DEVELOPMENT
import UIKit
import Metal
import QuartzCore

final class NativeMetalSurface:UIView {
    override class var layerClass:AnyClass {CAMetalLayer.self}
    var metalLayer:CAMetalLayer {layer as! CAMetalLayer}
    var drawablePixelLimit:CGSize?
    var onDrawableSizeChanged:((CGSize,Float)->Void)?
    private var lastDrawableSize=CGSize.zero
    override init(frame:CGRect) {
        super.init(frame:frame);backgroundColor = .black
        metalLayer.device=MTLCreateSystemDefaultDevice();metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly=true;metalLayer.contentsScale=UIScreen.main.scale
        accessibilityIdentifier="standalone-game-screen"
    }
    required init?(coder:NSCoder) {fatalError()}
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width>0,bounds.height>0 else{return}
        var scale=contentScaleFactor
        if let limit=drawablePixelLimit,bounds.width>0,bounds.height>0 {scale=min(scale,limit.width/bounds.width,limit.height/bounds.height)}
        let size=CGSize(width:max(1,(bounds.width*scale).rounded(.down)),height:max(1,(bounds.height*scale).rounded(.down)))
        metalLayer.contentsScale=scale;metalLayer.drawableSize=size
        if size != lastDrawableSize {lastDrawableSize=size;onDrawableSizeChanged?(size,Float(min(60,window?.screen.maximumFramesPerSecond ?? 60)))}
    }
}
#endif
