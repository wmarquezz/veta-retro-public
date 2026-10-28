#if VETA_JIT_DEVELOPMENT
import XCTest
import UIKit
import QuartzCore
@testable import VetaJITLab
@MainActor final class NativeSurfaceRoutingTests:XCTestCase {
    func testTVQualityAndSizeChangeTheSameLayerAndRestorePhone() {
        let local=UIView(frame:CGRect(x:0,y:0,width:390,height:240))
        let tv=UIView(frame:CGRect(x:0,y:0,width:3840,height:2160))
        let surface=NativeMetalSurface(),layer=surface.metalLayer
        let route=NativeSurfaceRouter(surface:surface,localHost:local,aspect:16/9)
        route.televisionPixelLimit=TVRenderQuality.fullHD.pixelLimit
        route.route(to:tv)
        XCTAssertEqual(layer.drawableSize,CGSize(width:1920,height:1080))
        route.televisionPixelLimit=TVRenderQuality.maximum.pixelLimit
        route.route(to:tv)
        XCTAssertEqual(layer.drawableSize,CGSize(width:3840,height:2160))
        route.televisionScale=0.5;route.layout()
        XCTAssertEqual(surface.frame,CGRect(x:960,y:540,width:1920,height:1080))
        XCTAssertTrue(layer === surface.metalLayer);XCTAssertEqual(tv.subviews.count,1)
        route.route(to:nil)
        XCTAssertNil(surface.drawablePixelLimit);XCTAssertEqual(surface.frame.width,390)
        XCTAssertTrue(surface.superview === local);XCTAssertTrue(tv.subviews.isEmpty)
    }
    func testOneLayerRoutesToTVAndReturnsWithoutLosingAspect() {
        let local=UIView(frame:CGRect(x:0,y:0,width:390,height:240))
        let tv=UIView(frame:CGRect(x:0,y:0,width:1920,height:1080))
        let surface=NativeMetalSurface(),layer=surface.metalLayer
        let route=NativeSurfaceRouter(surface:surface,localHost:local,aspect:16/9)
        var events:[Bool]=[];route.onRoutingChanged={events.append($0)}
        var sizes:[CGSize]=[];surface.onDrawableSizeChanged={size,_ in XCTAssertTrue(Thread.isMainThread);sizes.append(size)}
        XCTAssertTrue(surface.superview === local)
        XCTAssertEqual(surface.bounds.width/surface.bounds.height,16/9,accuracy:0.0001)
        route.route(to:tv)
        XCTAssertTrue(surface.superview === tv);XCTAssertTrue(surface.metalLayer === layer)
        XCTAssertEqual(surface.frame,tv.bounds);XCTAssertEqual(surface.metalLayer.drawableSize,CGSize(width:1280,height:720))
        // Local phone layout changes must not resize the external render target.
        local.frame.size=CGSize(width:844,height:300);route.layout()
        XCTAssertEqual(surface.frame,tv.bounds);XCTAssertEqual(tv.subviews.count,1)
        route.route(to:nil)
        XCTAssertTrue(surface.superview === local);XCTAssertTrue(surface.metalLayer === layer)
        XCTAssertEqual(surface.bounds.width/surface.bounds.height,16/9,accuracy:0.0001)
        XCTAssertTrue(tv.subviews.isEmpty);XCTAssertEqual(events,[true,false]);XCTAssertFalse(sizes.isEmpty)
        XCTAssertNil(surface.drawablePixelLimit)
    }
    func testUnlaidOutExternalHostKeepsLastDrawableUntilReady() {
        let local=UIView(frame:CGRect(x:0,y:0,width:390,height:240)),pending=UIView()
        let surface=NativeMetalSurface(),route=NativeSurfaceRouter(surface:surface,localHost:local,aspect:16/9)
        let prior=surface.metalLayer.drawableSize
        route.route(to:pending)
        XCTAssertEqual(surface.metalLayer.drawableSize,prior)
        pending.frame=CGRect(x:0,y:0,width:1920,height:1080);route.layout()
        XCTAssertEqual(surface.metalLayer.drawableSize,CGSize(width:1280,height:720))
        route.route(to:nil);XCTAssertEqual(surface.metalLayer.drawableSize,prior)
    }
    func testRepeatedAndReplacedTVHostsNeverDuplicateSurface() {
        let local=UIView(frame:CGRect(x:0,y:0,width:390,height:240)),first=UIView(frame:CGRect(x:0,y:0,width:1024,height:768)),second=UIView(frame:CGRect(x:0,y:0,width:2000,height:1000))
        let surface=NativeMetalSurface(),layer=surface.metalLayer,route=NativeSurfaceRouter(surface:surface,localHost:local,aspect:4/3)
        route.route(to:first);route.route(to:first);XCTAssertEqual(first.subviews.count,1)
        route.route(to:second);XCTAssertTrue(first.subviews.isEmpty);XCTAssertEqual(second.subviews.count,1)
        XCTAssertTrue(surface.metalLayer === layer);XCTAssertEqual(surface.frame.width/surface.frame.height,4/3,accuracy:0.0001)
        XCTAssertLessThanOrEqual(surface.metalLayer.drawableSize.width,1280);XCTAssertLessThanOrEqual(surface.metalLayer.drawableSize.height,720)
        route.route(to:nil);XCTAssertTrue(second.subviews.isEmpty);XCTAssertEqual(local.subviews.count,1)
    }
}
#endif
