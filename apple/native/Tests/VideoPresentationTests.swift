import XCTest
import Metal
import UIKit
import AVFoundation
#if VETA_JIT_DEVELOPMENT
@testable import VetaJITLab
#else
@testable import VetaNative
#endif

@MainActor final class VideoPresentationTests:XCTestCase {
    #if VETA_JIT_DEVELOPMENT
    func testXboxFilterDefaultsAndInheritanceKeepUnsupportedFiltersOut()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let library=Library(root:root),game=Game(id:"xbox-filter",name:"Filter",console:.xbox)
        library.games=[game]
        let store=VideoProfileStore(library:library,game:game)
        XCTAssertEqual(store.resolved().filter,.spatial)
        try store.save(.init(filter:.xbr),forConsole:true)
        XCTAssertEqual(store.resolved().filter,.xbr)
        try store.save(.init(filter:.spatial),forConsole:false)
        XCTAssertEqual(store.resolved().filter,.spatial)
        try store.save(nil,forConsole:false)
        XCTAssertEqual(store.resolved().filter,.xbr)
        for filter in VideoFilter.allCases where filter != .xbr {
            XCTAssertEqual(VideoPresentation(filter:filter).validated(for:.xbox).filter,.spatial)
        }
        XCTAssertEqual(VideoPresentation(filter:.xbr).validated(for:.ps3).filter,.pixels)
        XCTAssertEqual(VideoPresentation(filter:.crt).validated(for:.nes).filter,.crt)
    }
    #endif
    func testTVPresentationPreservesAspectBoundsAndPhoneFilter() {
        let bounds=CGRect(x:0,y:0,width:3840,height:2160)
        for scale:CGFloat in [1,0.85,0.7,0.5] {
            let frame=TVImageGeometry.frame(in:bounds,aspect:4.0/3.0,scale:scale)
            XCTAssertEqual(frame.width/frame.height,4.0/3.0,accuracy:0.0001)
            XCTAssertEqual(frame.height,2160*scale,accuracy:0.0001)
            XCTAssertEqual(frame.midX,bounds.midX);XCTAssertEqual(frame.midY,bounds.midY)
            XCTAssertTrue(bounds.contains(frame))
        }
        XCTAssertEqual(TVImageGeometry.frame(in:bounds,aspect:4.0/3.0,scale:.nan),TVImageGeometry.frame(in:bounds,aspect:4.0/3.0,scale:1))
        XCTAssertEqual(TVImageGeometry.frame(in:bounds,aspect:0,scale:1),.zero)
        XCTAssertEqual(TVImageMode.automatic.filter(for:.n64,inherited:.pixels),.spatial)
        XCTAssertEqual(TVImageMode.automatic.filter(for:.nes,inherited:.pixels),.xbr)
        XCTAssertEqual(TVImageMode.pixels.filter(for:.n64,inherited:.smooth),.pixels)
        XCTAssertEqual(VideoFilter.crt.shaderValue,2);XCTAssertEqual(VideoFilter.lcd.shaderValue,3)
    }
    func testEnhancementCoversEveryFrameConsoleAndSeparatesDualScreens() {
        for console in GameConsole.allCases where !console.isStandaloneEngine {
            let filter=TVImageMode.automatic.filter(for:console,inherited:.pixels)
            XCTAssertTrue([VideoFilter.xbr,.spatial].contains(filter),console.rawValue)
        }
        for layout in DSScreenLayout.allCases {
            let regions=SpatialVideoScaler.regions(width:256,height:384,outputWidth:1024,outputHeight:1536,layout:layout,dual:true,threeDSSideBySide:false)
            XCTAssertFalse(regions.isEmpty)
            for region in regions {
                XCTAssertTrue(region.source.maxY <= 192 || region.source.minY >= 192,"A scaler must not cross the DS seam")
                XCTAssertTrue(CGRect(x:0,y:0,width:256,height:384).contains(region.source))
                XCTAssertTrue(CGRect(x:0,y:0,width:1024,height:1536).contains(region.destination))
            }
        }
        let threeDS=SpatialVideoScaler.regions(width:400,height:480,outputWidth:2160,outputHeight:720,layout:.stacked,dual:true,threeDSSideBySide:true)
        XCTAssertEqual(threeDS.map(\.source),[CGRect(x:0,y:0,width:400,height:240),CGRect(x:40,y:240,width:320,height:240)])
        XCTAssertEqual(threeDS.map(\.destination),[CGRect(x:0,y:0,width:1200,height:720),CGRect(x:1200,y:0,width:960,height:720)])
        XCTAssertEqual(VideoFilter.sharpSmooth.shaderValue,4);XCTAssertEqual(VideoFilter.xbr.shaderValue,5)
    }
    func testSpatialScalerGPUKeepsDualScreensSeparateAndReusesResources()throws {
        #if canImport(MetalFX)
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()),library=try XCTUnwrap(device.makeDefaultLibrary())
        let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:"veta_vertex");d.fragmentFunction=library.makeFunction(name:"veta_fragment");d.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline=try device.makeRenderPipelineState(descriptor:d),queue=try XCTUnwrap(device.makeCommandQueue())
        func texture(_ w:Int,_ h:Int,_ usage:MTLTextureUsage)->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false);d.storageMode = .shared;d.usage=usage
            return device.makeTexture(descriptor:d)!
        }
        let source=texture(64,96,.shaderRead),target=texture(256,384,[.shaderRead,.renderTarget])
        let pixels:[UInt8]=(0..<64*96).flatMap{$0<64*48 ? [UInt8(0),0,255,255]:[UInt8(0),255,0,255]}
        pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,64,96),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256)}
        let scaler=SpatialVideoScaler()
        for _ in 0..<3 {
            let cmd=try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(scaler.encode(source:source,target:target,buffer:cmd,pipeline:pipeline,layout:.stacked,dual:true,threeDSSideBySide:false),scaler.status)
            cmd.commit();cmd.waitUntilCompleted();XCTAssertEqual(cmd.status,.completed,cmd.error?.localizedDescription ?? "")
        }
        XCTAssertEqual(scaler.resourceGeneration,1)
        var bytes=[UInt8](repeating:0,count:256*384*4)
        bytes.withUnsafeMutableBytes{target.getBytes($0.baseAddress!,bytesPerRow:1024,from:MTLRegionMake2D(0,0,256,384),mipmapLevel:0)}
        for y in [0,190,191,192,193,383] {
            let p=(y*256+128)*4
            XCTAssertLessThanOrEqual(bytes[p],3)
            XCTAssertGreaterThanOrEqual(bytes[p+(y<192 ? 2:1)],252)
            XCTAssertLessThanOrEqual(bytes[p+(y<192 ? 1:2)],3)
        }
        #else
        throw XCTSkip("MetalFX is not shipped in the iOS Simulator SDK; run on device or Mac GPU")
        #endif
    }
    func testLiveMetalScreenUploadsCoreFramesAndPresentsBothEnhancements()async throws {
        let rom=try XCTUnwrap(Bundle.main.url(forResource:"thwaite",withExtension:"nes",subdirectory:"Content/thwaite"))
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer {veta_unload();try? FileManager.default.removeItem(at:temp)}
        XCTAssertTrue(veta_load(rom.path,temp.path,"NTSC"))
        for _ in 0..<60 {veta_run()}
        guard let scene=UIApplication.shared.connectedScenes.compactMap({$0 as? UIWindowScene}).first(where:{$0.screen == UIScreen.main}) else {throw XCTSkip("Live MTKView requires an application scene; headless runner covers the offscreen shaders separately") }
        let prior=scene.windows.first{$0.isKeyWindow}
        let window=UIWindow(windowScene:scene),controller=UIViewController(),screen=MetalScreen()
        window.rootViewController=controller;controller.view.addSubview(screen)
        screen.isPrimaryDisplay=false;screen.frame=CGRect(x:0,y:0,width:256,height:240)
        screen.autoResizeDrawable=false;screen.drawableSize=CGSize(width:1024,height:960)
        window.makeKeyAndVisible();window.layoutIfNeeded()
        defer {window.isHidden=true;prior?.makeKey()}
        for filter in [VideoFilter.xbr,.spatial] {
            let completed=screen.completedFrames
            screen.applyPresentation(.init(filter:filter,dsLayout:.stacked));screen.presentFrame()
            let deadline=Date().addingTimeInterval(5)
            while screen.completedFrames==completed && Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
            XCTAssertGreaterThan(screen.completedFrames,completed,screen.enhancementStatus)
            XCTAssertNil(screen.lastGPUError)
            if filter == .xbr {XCTAssertTrue(screen.enhancementStatus.hasPrefix("xbr"))}
            #if canImport(MetalFX)
            if filter == .spatial {XCTAssertTrue(screen.enhancementStatus.hasPrefix("MetalFX espacial"),screen.enhancementStatus)}
            #endif
            print("VETA158_LIVE_RENDER \(screen.enhancementStatus) completed=\(screen.completedFrames)")
        }
    }
    #if VETA_JIT_DEVELOPMENT
    func testConsoleRenderProbeWritesOnlyIsolatedStatesAndKeepsROMPath()throws {
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library=Library(root:root),game=Game(id:"tv158-isolation-"+UUID().uuidString,name:"Render isolation",console:.nes)
        try fm.createDirectory(at:library.directory(game.id),withIntermediateDirectories:true)
        let original=library.file(game,"auto.vstate"),rom=library.romURL(game)
        try Data("original progress".utf8).write(to:original)
        let old=ProcessInfo.processInfo.environment["VETA_TV158_QA_PRIMARY"]
        setenv("VETA_TV158_QA_PRIMARY","1",1)
        let isolated=library.stateDirectory(game)
        defer {
            if let old {setenv("VETA_TV158_QA_PRIMARY",old,1)}else{unsetenv("VETA_TV158_QA_PRIMARY")}
            try? fm.removeItem(at:isolated);try? fm.removeItem(at:root)
        }
        XCTAssertNotEqual(isolated,library.directory(game.id))
        XCTAssertEqual(library.romURL(game),rom)
        XCTAssertEqual(try library.prepareSessionSaves(for:game),isolated,"Battery saves written by the core must also stay isolated")
        try fm.createDirectory(at:isolated,withIntermediateDirectories:true)
        try Data("probe progress".utf8).write(to:library.file(game,"auto.vstate"))
        XCTAssertEqual(try Data(contentsOf:original),Data("original progress".utf8))
        unsetenv("VETA_TV158_QA_PRIMARY")
        XCTAssertEqual(library.file(game,"auto.vstate"),original)
    }
    #endif
    #if VETA_JIT_DEVELOPMENT
    func test158VisualProbeDoesNotActivateAudioSession()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_TV158_QA_PRIMARY"] == "1")
        let session=AVAudioSession.sharedInstance(),category=session.category,mode=session.mode,options=session.categoryOptions
        let audio=NativeAudio();try audio.start(rate:48000,volume:0)
        defer {audio.stop()}
        XCTAssertTrue(NativeAudio.visualRenderProbe)
        XCTAssertEqual(session.category,category);XCTAssertEqual(session.mode,mode);XCTAssertEqual(session.categoryOptions,options)
        print("VETA158_SILENT_PROBE no audio session activation; route=\(session.currentRoute.outputs.map(\.portType.rawValue))")
    }
    #endif
    func test158ReadOnlyAudioAndScreenCaptureAudit() {
        let outputs=AVAudioSession.sharedInstance().currentRoute.outputs.map{["type":$0.portType.rawValue,"name":$0.portName]}
        print("VETA158_ROUTE_AUDIT outputs=\(outputs) screens=\(UIScreen.screens.count) captured=\(UIScreen.main.isCaptured) externalConnected=\(ExternalDisplayHub.shared.connected)")
    }
    func testAutomaticRotationPreservesExplicitProfilesAndThreeDSTouchMapping()throws {
        let automatic=VideoPresentation()
        XCTAssertEqual(automatic.resolved(for:.ds,landscape:false).dsLayout,.stacked)
        XCTAssertEqual(automatic.resolved(for:.ds,landscape:true).dsLayout,.sideBySide)
        for layout in [DSScreenLayout.stacked,.sideBySide,.swapped,.topOnly,.bottomOnly] {
            let saved=VideoPresentation(filter:.crt,dsLayout:layout)
            let decoded=try JSONDecoder().decode(VideoPresentation.self,from:JSONEncoder().encode(saved))
            XCTAssertEqual(decoded.resolved(for:.ds,landscape:true),saved)
            XCTAssertEqual(decoded.resolved(for:.ds,landscape:false),saved)
        }
        XCTAssertEqual(automatic.dsLayout,.automatic)
        XCTAssertNil(ThreeDSScreenGeometry.touchPoint(CGPoint(x:0.25,y:0.5)))
        let center=try XCTUnwrap(ThreeDSScreenGeometry.touchPoint(CGPoint(x:7.0/9.0,y:0.5)))
        XCTAssertEqual(center.x,0.5,accuracy:0.00001);XCTAssertEqual(center.y,0.75,accuracy:0.00001)
        for point in [CGPoint(x:-1,y:0),CGPoint(x:1.1,y:0),CGPoint(x:1,y:1.1),CGPoint(x:CGFloat.nan,y:0)] {XCTAssertNil(ThreeDSScreenGeometry.touchPoint(point))}
    }
    func testDSTouchMappingFollowsLowerScreenAndRejectsUpperOrInvalidPoints() {
        XCTAssertEqual(DSScreenLayout.stacked.touchPoint(CGPoint(x:0.2,y:0.8)),CGPoint(x:0.2,y:0.8))
        XCTAssertNil(DSScreenLayout.stacked.touchPoint(CGPoint(x:0.2,y:0.2)))
        XCTAssertEqual(DSScreenLayout.sideBySide.touchPoint(CGPoint(x:0.75,y:0.5)),CGPoint(x:0.5,y:0.75))
        XCTAssertNil(DSScreenLayout.sideBySide.touchPoint(CGPoint(x:0.25,y:0.5)))
        XCTAssertEqual(DSScreenLayout.bottomOnly.touchPoint(CGPoint(x:0.2,y:0.2)),CGPoint(x:0.2,y:0.6))
        XCTAssertNil(DSScreenLayout.topOnly.touchPoint(CGPoint(x:0.2,y:1)))
        XCTAssertEqual(DSScreenLayout.swapped.touchPoint(CGPoint(x:0.3,y:0.25)),CGPoint(x:0.3,y:0.75))
        XCTAssertNil(DSScreenLayout.swapped.touchPoint(CGPoint(x:0.3,y:0.75)))
        for layout in DSScreenLayout.allCases {
            XCTAssertNil(layout.touchPoint(CGPoint(x:CGFloat.nan,y:0.8)))
            XCTAssertNil(layout.touchPoint(CGPoint(x:-1,y:0.8)))
        }
    }
    func testVideoProfilesInheritWithoutChangingCoreStatesAndSurviveGameBackup()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let library=Library(root:root)
        let rom=try Data(contentsOf:XCTUnwrap(Bundle.main.url(forResource:"thwaite",withExtension:"nes",subdirectory:"Content/thwaite")))
        let game=try library.add(data:rom,name:"Thwaite"),store=VideoProfileStore(library:library,game:game)
        let before=try GameProfileStore(library:library,game:game).resolved().fingerprint
        try store.save(.init(filter:.crt,dsLayout:.sideBySide),forConsole:true)
        XCTAssertEqual(store.resolved(),.init(filter:.crt,dsLayout:.stacked))
        try store.save(.init(filter:.lcd),forConsole:false)
        XCTAssertEqual(store.resolved().filter,.lcd)
        XCTAssertEqual(try GameProfileStore(library:library,game:game).resolved().fingerprint,before)
        let archive=try library.export();defer{try? FileManager.default.removeItem(at:archive)}
        let restored=Library(root:root.appendingPathComponent("restored"));try restored.importURL(archive)
        XCTAssertEqual(restored.games.first?.videoPresentation?.filter,.lcd)
        try store.save(nil,forConsole:false);XCTAssertEqual(store.resolved().filter,.crt)
        let inheritedArchive=try library.export();defer{try? FileManager.default.removeItem(at:inheritedArchive)}
        let inherited=Library(root:root.appendingPathComponent("inherited"));try inherited.importURL(inheritedArchive)
        let inheritedGame=try XCTUnwrap(inherited.games.first)
        XCTAssertEqual(VideoProfileStore(library:inherited,game:inheritedGame).resolved().filter,.crt)
    }
    func testConsoleProfileRejectsOversizedCorruptAndSymlinkFiles()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let library=Library(root:root),game=Game(id:"profile-test",name:"Test",console:.nes),store=VideoProfileStore(library:library,game:game)
        let path=root.appendingPathComponent("display-nes.json")
        try Data(repeating:32,count:4097).write(to:path);XCTAssertEqual(store.consoleProfile(),.init())
        try Data("{broken".utf8).write(to:path);XCTAssertEqual(store.consoleProfile(),.init())
        let target=root.appendingPathComponent("other.json");try JSONEncoder().encode(VideoPresentation(filter:.lcd)).write(to:target)
        try FileManager.default.removeItem(at:path);try FileManager.default.createSymbolicLink(at:path,withDestinationURL:target)
        XCTAssertEqual(store.consoleProfile(),.init())
    }
    func testActualMetalShaderMapsBothScreensAndAppliesFilters()throws {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library=try XCTUnwrap(device.makeDefaultLibrary())
        let descriptor=MTLRenderPipelineDescriptor();descriptor.vertexFunction=library.makeFunction(name:"veta_vertex");descriptor.fragmentFunction=library.makeFunction(name:"veta_fragment");descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline=try device.makeRenderPipelineState(descriptor:descriptor),queue=try XCTUnwrap(device.makeCommandQueue())
        let sourceDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:4,height:4,mipmapped:false);sourceDescriptor.usage = .shaderRead;sourceDescriptor.storageMode = .shared
        let source=try XCTUnwrap(device.makeTexture(descriptor:sourceDescriptor))
        let pixels:[UInt8]=(0..<16).flatMap { $0<8 ? [UInt8(255),0,0,255]:[UInt8(0),255,0,255] }
        pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,4,4),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:16)}
        func render(_ filter:VideoFilter,_ layout:DSScreenLayout,size:Int=8,isDS:Bool=true,threeDS:Bool=false)throws->[UInt8] {
            let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:size,height:size,mipmapped:false);outputDescriptor.storageMode = .shared;outputDescriptor.usage = [.renderTarget,.shaderRead]
            let output=try XCTUnwrap(device.makeTexture(descriptor:outputDescriptor)),pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            let buffer=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor:pass))
            encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(source,index:0)
            var settings=SIMD2<UInt32>(filter.shaderValue,layout.shaderValue | (isDS ? 0x100:0) | (threeDS ? 0x200:0));encoder.setFragmentBytes(&settings,length:MemoryLayout<SIMD2<UInt32>>.size,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding();buffer.commit();buffer.waitUntilCompleted()
            XCTAssertEqual(buffer.status,.completed)
            var bytes=[UInt8](repeating:0,count:size*size*4);bytes.withUnsafeMutableBytes{output.getBytes($0.baseAddress!,bytesPerRow:size*4,from:MTLRegionMake2D(0,0,size,size),mipmapLevel:0)}
            return bytes
        }
        func rgb(_ bytes:[UInt8],_ x:Int,_ y:Int)->[UInt8]{Array(bytes[((y*8+x)*4)..<((y*8+x)*4+3)])}
        let stacked=try render(.pixels,.stacked)
        XCTAssertEqual(rgb(stacked,2,1),[255,0,0]);XCTAssertEqual(rgb(stacked,2,6),[0,255,0])
        let side=try render(.pixels,.sideBySide)
        XCTAssertEqual(rgb(side,1,3),[255,0,0]);XCTAssertEqual(rgb(side,6,3),[0,255,0])
        let threeDS=try render(.pixels,.stacked,threeDS:true)
        XCTAssertEqual(rgb(threeDS,3,1),[255,0,0]);XCTAssertEqual(rgb(threeDS,5,1),[0,255,0])
        XCTAssertEqual(rgb(threeDS,3,6),[255,0,0]);XCTAssertEqual(rgb(threeDS,5,6),[0,255,0])
        XCTAssertEqual(rgb(try render(.pixels,.bottomOnly),2,1),[0,255,0])
        XCTAssertEqual(rgb(try render(.pixels,.topOnly),2,6),[255,0,0])
        XCTAssertEqual(rgb(try render(.pixels,.swapped),2,1),[0,255,0])
        let crt=try render(.crt,.stacked);XCTAssertLessThan(rgb(crt,2,1)[0],rgb(stacked,2,1)[0]);XCTAssertEqual(rgb(crt,2,0),[255,0,0])
        // LCD grid needs enough output samples per source pixel to reach its thin grid.
        let xbr=try render(.xbr,.stacked)
        XCTAssertEqual(rgb(xbr,2,3),[255,0,0]);XCTAssertEqual(rgb(xbr,2,4),[0,255,0])
        let sharp=try render(.sharpSmooth,.stacked)
        XCTAssertEqual(rgb(sharp,2,3),[255,0,0]);XCTAssertEqual(rgb(sharp,2,4),[0,255,0])
        let sharpSingle=try render(.sharpSmooth,.stacked,isDS:false)
        let linearSingle=try render(.smooth,.stacked,isDS:false)
        XCTAssertGreaterThan(rgb(sharpSingle,2,3)[0],rgb(linearSingle,2,3)[0])
        XCTAssertGreaterThan(rgb(sharpSingle,2,4)[1],rgb(linearSingle,2,4)[1])
        let smooth=try render(.smooth,.stacked);XCTAssertEqual(rgb(smooth,2,3),[255,0,0]);XCTAssertEqual(rgb(smooth,2,4),[0,255,0])
        XCTAssertEqual(rgb(try render(.smooth,.bottomOnly),2,0),[0,255,0]);XCTAssertEqual(rgb(try render(.smooth,.topOnly),2,7),[255,0,0])
        let single=try render(.smooth,.stacked,isDS:false);XCTAssertGreaterThan(rgb(single,2,3)[1],0);XCTAssertLessThan(rgb(single,2,3)[0],255)
        let lcd=try render(.lcd,.stacked,size:32),plain=try render(.pixels,.stacked,size:32)
        XCTAssertEqual(lcd[0],plain[0]);XCTAssertLessThan(lcd[7*4],plain[7*4]);XCTAssertEqual(lcd[7*4+3],255)
        // A synthetic diagonal exercises edge detection rather than only solid colors.
        let diagonal:[UInt8]=(0..<16).flatMap { i in let c:UInt8=(i%4 >= i/4) ? 255:0;return [c,c,c,255] }
        diagonal.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,4,4),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:16)}
        let edge=try render(.xbr,.stacked,size:32,isDS:false),nearest=try render(.pixels,.stacked,size:32,isDS:false)
        XCTAssertNotEqual(edge,nearest)
        XCTAssertGreaterThan(Set(stride(from:0,to:edge.count,by:4).map{edge[$0]}).count,2)
        XCTAssertTrue(stride(from:3,to:edge.count,by:4).allSatisfy{edge[$0]==255})

    }
}
