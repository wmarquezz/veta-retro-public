import XCTest
import UIKit
@testable import VetaNative

@MainActor final class ControllerSkinTests:XCTestCase {
    private var suite:String!
    private var defaults:UserDefaults!
    private var store:ControllerSkinStore!
    override func setUpWithError()throws {suite="VetaSkinTests."+UUID().uuidString;defaults=try XCTUnwrap(UserDefaults(suiteName:suite));store=ControllerSkinStore(defaults:defaults)}
    override func tearDownWithError()throws {defaults.removePersistentDomain(forName:suite)}
    private func example()->ControllerSkinLayout {.makeDefault(console:.nes,orientation:.portrait,palette:.veta)}
    func testEveryConsoleHasCompleteValidIndependentReferenceLayouts()throws {
        for console in GameConsole.allCases {for orientation in ControllerSkinOrientation.allCases {
            let value=ControllerSkinLayout.makeDefault(console:console,orientation:orientation,palette:.classic)
            try value.validated(console:console,orientation:orientation)
            XCTAssertEqual(try ControllerSkinLayout.decode(value.encoded(),console:console,orientation:orientation),value)
            let zones=try value.resolved(console:console,orientation:orientation,size:value.canvas)
            XCTAssertTrue(zones.values.allSatisfy{$0.width>=43.999 && $0.height>=43.999})
            XCTAssertEqual(Set(zones.keys),Set(TouchDeck.baseZones(style:ControlStyle(console:console,defaults:nil),size:value.canvas,landscape:orientation == .landscape).keys))
        }}
    }
    func testLandscapeKeepsControlsBesideTheImageOnWiderDisplays()throws {
        let canvas=ControllerSkinOrientation.landscape.canvas
        let zones=ControllerSkinGeometry.fitted(TouchDeck.baseZones(style:ControlStyle(console:.ps2,defaults:nil),size:canvas,landscape:true),size:canvas,orientation:.landscape)
        let layout=ControllerSkinLayout(console:GameConsole.ps2.rawValue,orientation:.landscape,palette:.veta,controls:zones.keys.sorted().map{ControllerSkinControl(id:$0,rect:zones[$0]!,canvas:canvas)})
        for width:CGFloat in [700,844,1024,1366] {
            let zones=try layout.resolved(console:.ps2,orientation:.landscape,size:CGSize(width:width,height:320))
            XCTAssertTrue(zones.values.allSatisfy{$0.maxX<=188.001 || $0.minX>=width-188.001})
        }
    }
    func testPreferencesAreScopedByConsoleAndOrientationAndRespectLegacy()throws {
        defaults.set("Noche",forKey:"native.skin")
        XCTAssertEqual(store.palette(console:.nes,orientation:.portrait),.night)
        XCTAssertEqual(store.palette(console:.nes,orientation:.landscape),.night)
        try store.save(example(),console:.nes)
        XCTAssertEqual(store.palette(console:.nes,orientation:.portrait),.veta)
        XCTAssertEqual(store.palette(console:.nes,orientation:.landscape),.night)
        XCTAssertNil(store.layout(console:.nes,orientation:.landscape))
        XCTAssertNil(store.layout(console:.gb,orientation:.portrait))
        XCTAssertEqual(store.palette(console:.gb,orientation:.portrait),.classic)
        store.setPalette(.transparent,console:.nes,orientation:.portrait)
        XCTAssertEqual(store.layout(console:.nes,orientation:.portrait)?.palette,.transparent)
        store.reset(console:.nes,orientation:.portrait)
        XCTAssertNil(store.layout(console:.nes,orientation:.portrait))
        XCTAssertEqual(defaults.string(forKey:"native.skin"),"Noche")
    }
    func testMalformedOrForeignImportsCannotReplaceStoredLayout()throws {
        let good=example();try store.save(good,console:.nes)
        var invalid=good;invalid.controls[0].x = .nan
        XCTAssertThrowsError(try store.save(invalid,console:.nes))
        XCTAssertEqual(store.layout(console:.nes,orientation:.portrait),good)
        XCTAssertThrowsError(try ControllerSkinLayout.decode(good.encoded(),console:.snes,orientation:.portrait))
        XCTAssertThrowsError(try ControllerSkinLayout.decode(good.encoded(),console:.nes,orientation:.landscape))
        invalid=good;invalid.version=2;XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.format="deltaskin";XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.controls.append(invalid.controls[0]);XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.controls.removeLast();XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.controls[0].id="../../Documents";XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.controls[0].width = .infinity;XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.controls[0].height = -0.1;XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.controls[0].width=0.001;XCTAssertThrowsError(try invalid.encoded())
        invalid=good;invalid.controls[0].x=1;XCTAssertThrowsError(try invalid.encoded())
    }
    func testStrictSchemaAndBoundedFileReads()throws {
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:example().encoded()) as? [String:Any])
        json["imagePath"]="/private/image.png"
        XCTAssertThrowsError(try ControllerSkinLayout.decode(JSONSerialization.data(withJSONObject:json),console:.nes,orientation:.portrait))
        XCTAssertThrowsError(try ControllerSkinLayout.decode(Data(repeating:32,count:ControllerSkinLayout.byteLimit+1),console:.nes,orientation:.portrait))
        XCTAssertThrowsError(try ControllerSkinLayout.decode(Data("{broken".utf8),console:.nes,orientation:.portrait))
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer {try? FileManager.default.removeItem(at:file)}
        try Data(repeating:32,count:ControllerSkinLayout.byteLimit+4096).write(to:file)
        XCTAssertThrowsError(try ControllerSkinLayout.read(file,console:.nes,orientation:.portrait))
        XCTAssertThrowsError(try ControllerSkinLayout.read(URL(string:"https://example.invalid/design.json")!,console:.nes,orientation:.portrait))
    }
    func testDraggingIsTransactionalAndCannotOverlapOtherControls()throws {
        var layout=example();let before=layout
        let a=try XCTUnwrap(layout.controls.first{$0.id=="A"}),b=try XCTUnwrap(layout.controls.first{$0.id=="B"})
        let target=b.rect(in:layout.canvas)
        XCTAssertThrowsError(try layout.move("A",to:CGPoint(x:target.midX,y:target.midY)))
        XCTAssertEqual(layout,before)
        let r=a.rect(in:layout.canvas)
        try layout.move("A",to:CGPoint(x:r.midX,y:r.midY+8))
        XCTAssertNotEqual(layout,before)
        XCTAssertEqual(layout.controls.first{$0.id=="B"},b)
        XCTAssertThrowsError(try layout.move("A",to:CGPoint(x:CGFloat.nan,y:0)))
    }
    func testPreviewAndPlayableHitTargetsUseSameCustomGeometryAndReleaseOnChange()throws {
        let deck=TouchDeck(frame:CGRect(origin:.zero,size:example().canvas))
        deck.style=ControlStyle(console:.nes,defaults:nil)
        var layout=example();let a=try XCTUnwrap(layout.controls.first{$0.id=="A"}).rect(in:layout.canvas)
        try layout.move("A",to:CGPoint(x:a.midX,y:a.midY+50))
        deck.customLayout=layout;deck.layoutIfNeeded()
        let expected=try layout.resolved(console:.nes,orientation:.portrait,size:deck.bounds.size)
        XCTAssertEqual(deck.zones,expected)
        let moved=try XCTUnwrap(deck.zones["A"])
        XCTAssertEqual(deck.inputMask(at:CGPoint(x:moved.midX,y:moved.midY)),GameConsole.nes.buttonMask("A"))
        XCTAssertEqual(deck.inputMask(at:CGPoint(x:a.midX,y:a.midY)),0)
        var releases=0;deck.onInput={if $0==0 {releases+=1}}
        deck.landscape=true;XCTAssertGreaterThan(releases,0)
        deck.customLayout=layout;deck.layoutIfNeeded()
        XCTAssertNotNil(deck.layoutIssue) // foreign orientation falls back, never reused.
    }
    func testAccessibleControlsSurviveStatusRelayoutAndTrackGeometryChanges()throws {
        let deck=TouchDeck(frame:CGRect(x:20,y:50,width:390,height:320))
        deck.style=ControlStyle(console:.nes,defaults:nil)
        deck.layoutIfNeeded()
        func elements()->[UIAccessibilityElement] {deck.accessibilityElements as? [UIAccessibilityElement] ?? []}
        let original=elements()
        let a=try XCTUnwrap(original.first{$0.accessibilityIdentifier=="control-A"})
        let initialFrame=a.accessibilityFrameInContainerSpace
        XCTAssertEqual(initialFrame,deck.zones["A"])
        XCTAssertGreaterThan(initialFrame.width,0)
        for _ in 0..<40 {
            deck.setNeedsLayout();deck.layoutIfNeeded()
            let current=elements()
            XCTAssertEqual(current.count,original.count)
            for (before,after) in zip(original,current) {XCTAssertTrue(before === after)}
            XCTAssertEqual(a.accessibilityFrameInContainerSpace,initialFrame)
        }
        // Resize/move the real deck while a caller still retains its AX object.
        deck.frame=CGRect(x:40,y:75,width:430,height:380)
        a.accessibilityLabel="stale label"
        deck.setNeedsLayout();deck.layoutIfNeeded()
        XCTAssertTrue(elements().first{$0.accessibilityIdentifier=="control-A"} === a)
        XCTAssertNotEqual(a.accessibilityFrameInContainerSpace,initialFrame)
        XCTAssertEqual(a.accessibilityFrameInContainerSpace,deck.zones["A"])
        XCTAssertEqual(a.accessibilityLabel,L10n.text("A"))
        deck.style=ControlStyle(console:.snes,defaults:nil);deck.layoutIfNeeded()
        XCTAssertNotNil(elements().first{$0.accessibilityIdentifier=="control-X"})
        XCTAssertTrue(elements().first{$0.accessibilityIdentifier=="control-A"} === a)
        deck.style=ControlStyle(console:.nes,defaults:nil);deck.layoutIfNeeded()
        XCTAssertNil(elements().first{$0.accessibilityIdentifier=="control-X"})
        XCTAssertTrue(elements().first{$0.accessibilityIdentifier=="control-A"} === a)
        XCTAssertEqual(Set(elements().compactMap{$0.accessibilityIdentifier}),Set(deck.zones.keys.map{"control-"+$0}))
    }
    func testThreeDSAutomaticSkinPrioritizesScreensAndKeepsEveryTargetReachable()throws {
        for size in [CGSize(width:320,height:548),CGSize(width:375,height:724),CGSize(width:393,height:759),CGSize(width:430,height:839)] {
            let safe=CGRect(origin:.zero,size:size)
            let layout=ConsoleLayout(safe:safe,aspect:400/480,minimumDeck:320,compactDualScreen:true)
            XCTAssertEqual(layout.deck.height,240,accuracy:0.001)
            XCTAssertEqual(layout.screen.width/layout.screen.height,400/480,accuracy:0.000001)
            XCTAssertLessThanOrEqual(layout.screen.maxY,layout.toolbar.minY+0.001)
            XCTAssertLessThanOrEqual(layout.toolbar.maxY,layout.deck.minY+0.001)
            if size.height>=size.width*1.2+284 {XCTAssertEqual(layout.screen.width,size.width,accuracy:0.001)}
            let deck=TouchDeck(frame:layout.deck);deck.style=ControlStyle(console:.threeDS,defaults:nil);deck.layoutIfNeeded()
            try ControllerSkinGeometry.validate(deck.zones,size:layout.deck.size,orientation:.portrait)
            XCTAssertEqual(Set(deck.zones.keys),Set(["stick0","dpad","A","B","X","Y","L","R","SELECT","START"]))
            XCTAssertLessThan(try XCTUnwrap(deck.zones["stick0"]).maxY,try XCTUnwrap(deck.zones["dpad"]).minY)
            for name in ["A","B","X","Y","L","R","START"] {
                let r=try XCTUnwrap(deck.zones[name])
                XCTAssertEqual(deck.inputMask(at:CGPoint(x:r.midX,y:r.midY)),GameConsole.threeDS.buttonMask(name))
            }
        }
        // Portrait changes must not silently reposition an existing saved skin
        // or alter other consoles' established layout.
        let safe=CGRect(x:0,y:0,width:393,height:759)
        let saved=ConsoleLayout(safe:safe,aspect:400/480,minimumDeck:320)
        XCTAssertEqual(saved.deck.height,320)
    }
    func testThreeDSNewEditsRoundTripCompactCanvasWhileLegacyExportsKeepTheirCanvas()throws {
        let fresh=ControllerSkinLayout.makeDefault(console:.threeDS,orientation:.portrait,palette:.classic)
        XCTAssertEqual(fresh.version,2);XCTAssertTrue(fresh.usesCompactThreeDSCanvas)
        XCTAssertEqual(fresh.canvas,CGSize(width:400,height:240))
        try store.save(fresh,console:.threeDS)
        let restored=try XCTUnwrap(store.layout(console:.threeDS,orientation:.portrait))
        XCTAssertEqual(restored,fresh)
        XCTAssertEqual(try ControllerSkinLayout.decode(fresh.encoded(),console:.threeDS,orientation:.portrait),fresh)
        let safe=CGRect(x:0,y:0,width:393,height:759)
        let edited=ConsoleLayout(safe:safe,aspect:400/480,minimumDeck:320,compactDualScreen:restored.usesCompactThreeDSCanvas)
        XCTAssertEqual(edited.deck.height,240)
        XCTAssertEqual(edited.screen.width,393,accuracy:0.001)
        // Legacy files remain byte-semantically identical after decode/save.
        let oldCanvas=CGSize(width:400,height:320)
        let oldZones=ControllerSkinGeometry.fitted(TouchDeck.baseZones(style:ControlStyle(console:.threeDS,defaults:nil),size:oldCanvas,landscape:false),size:oldCanvas,orientation:.portrait)
        let legacy=ControllerSkinLayout(version:1,console:"threeDS",orientation:.portrait,palette:.night,controls:oldZones.keys.sorted().map{ControllerSkinControl(id:$0,rect:oldZones[$0]!,canvas:oldCanvas)})
        let decoded=try ControllerSkinLayout.decode(legacy.encoded(),console:.threeDS,orientation:.portrait)
        XCTAssertEqual(decoded,legacy);XCTAssertEqual(decoded.canvas,oldCanvas)
        XCTAssertFalse(decoded.usesCompactThreeDSCanvas)
        try store.save(decoded,console:.threeDS)
        XCTAssertEqual(store.layout(console:.threeDS,orientation:.portrait),legacy)
        let resolved=try decoded.resolved(console:.threeDS,orientation:.portrait,size:oldCanvas)
        XCTAssertEqual(Set(resolved.keys),Set(oldZones.keys))
        for (key,before) in oldZones {
            let after=try XCTUnwrap(resolved[key])
            XCTAssertEqual(after.minX,before.minX,accuracy:0.000001)
            XCTAssertEqual(after.minY,before.minY,accuracy:0.000001)
            XCTAssertEqual(after.width,before.width,accuracy:0.000001)
            XCTAssertEqual(after.height,before.height,accuracy:0.000001)
        }
        var unsupported=ControllerSkinLayout.makeDefault(console:.nes,orientation:.portrait,palette:.classic);unsupported.version=2
        XCTAssertThrowsError(try unsupported.validated(console:.nes,orientation:.portrait))
        XCTAssertThrowsError(try ControllerSkinLayout.decode(JSONEncoder().encode(unsupported),console:.nes,orientation:.portrait))
        unsupported = .makeDefault(console:.threeDS,orientation:.landscape,palette:.classic);unsupported.version=2
        XCTAssertThrowsError(try ControllerSkinLayout.decode(JSONEncoder().encode(unsupported),console:.threeDS,orientation:.landscape))
        unsupported=fresh;unsupported.version=3
        XCTAssertThrowsError(try ControllerSkinLayout.decode(JSONEncoder().encode(unsupported),console:.threeDS,orientation:.portrait))
    }
    func testThreeDSHeightAndSpacingSlidersChangeGeometryWithinSafeTargets()throws {
        let size=CGSize(width:393,height:240)
        let original=TouchDeck.baseZones(style:ControlStyle(console:.threeDS,defaults:nil),size:size,landscape:false)
        var adjusted=ControlStyle(console:.threeDS,defaults:nil);adjusted.height=0.12
        let lowered=TouchDeck.baseZones(style:adjusted,size:size,landscape:false)
        XCTAssertGreaterThan(try XCTUnwrap(lowered["A"]).midY,try XCTUnwrap(original["A"]).midY)
        adjusted.height = -0.12
        XCTAssertLessThan(try XCTUnwrap(TouchDeck.baseZones(style:adjusted,size:size,landscape:false)["A"]).midY,try XCTUnwrap(original["A"]).midY)
        adjusted.height=0;adjusted.spacing=1.2
        let separated=TouchDeck.baseZones(style:adjusted,size:size,landscape:false)
        XCTAssertLessThan(try XCTUnwrap(separated["stick0"]).midX,try XCTUnwrap(original["stick0"]).midX)
        XCTAssertGreaterThan(try XCTUnwrap(separated["A"]).midX,try XCTUnwrap(original["A"]).midX)
        for width:CGFloat in [320,375,393,430] {for scale in [0.85,1,1.2] {for height in [-0.12,0,0.12] {for spacing in [0.8,1,1.2] {
            var style=ControlStyle(console:.threeDS,defaults:nil);style.size=scale;style.height=height;style.spacing=spacing
            let bounds=CGSize(width:width,height:240)
            let zones=ControllerSkinGeometry.fitted(TouchDeck.baseZones(style:style,size:bounds,landscape:false),size:bounds,orientation:.portrait)
            try ControllerSkinGeometry.validate(zones,size:bounds,orientation:.portrait)
            XCTAssertEqual(zones.count,10)
        }}}}
    }
    func testThreeDSCompactSkinRender()throws {
        let safe=CGRect(x:0,y:0,width:393,height:759)
        let layout=ConsoleLayout(safe:safe,aspect:400/480,minimumDeck:320,compactDualScreen:true)
        let shell=ConsoleShellView(frame:safe);shell.style=ControlStyle(console:.threeDS,defaults:nil)
        shell.screenRect=layout.screen;shell.portraitSkinTop=layout.toolbar.minY
        let deck=TouchDeck(frame:layout.deck);deck.style=shell.style;deck.layoutIfNeeded()
        let image=UIGraphicsImageRenderer(size:safe.size).image {context in
            shell.layer.render(in:context.cgContext)
            // Synthetic screen guides for layout inspection, not gameplay proof.
            UIColor.systemIndigo.setFill();context.fill(CGRect(x:layout.screen.minX,y:layout.screen.minY,width:layout.screen.width,height:layout.screen.height/2))
            UIColor.systemTeal.setFill();context.fill(CGRect(x:layout.screen.minX+layout.screen.width*0.1,y:layout.screen.midY,width:layout.screen.width*0.8,height:layout.screen.height/2))
            SkinDrawing.text("400 × 240",in:CGRect(x:layout.screen.minX,y:layout.screen.minY,width:layout.screen.width,height:layout.screen.height/2),size:24,color:.white)
            SkinDrawing.text("320 × 240 · TOUCH",in:CGRect(x:layout.screen.minX,y:layout.screen.midY,width:layout.screen.width,height:layout.screen.height/2),size:20,color:.black)
            SkinDrawing.text("VETA / 3DS",in:layout.toolbar,size:16,color:shell.style.headerInk)
            context.cgContext.translateBy(x:layout.deck.minX,y:layout.deck.minY);deck.layer.render(in:context.cgContext)
        }
        let data=try XCTUnwrap(image.pngData())
        let destination=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("threeDS-compact-skin-147.png")
        try data.write(to:destination)
        if ProcessInfo.processInfo.environment["VETA_HEADLESS_HOME"] == nil {
            let attachment=XCTAttachment(image:image);attachment.name="147-3DS-skin-geometry-preview";attachment.lifetime = .keepAlways;add(attachment)
        }
    }
    func testThreeDSLargerControlsKeepPortraitClearAndReflowInLandscape()throws {
        for (index,size) in [CGSize(width:393,height:759),CGSize(width:734,height:372),CGSize(width:430,height:839),CGSize(width:844,height:320)].enumerated() {
            let safe=CGRect(origin:.zero,size:size),landscape=size.width>size.height
            let layout=ConsoleLayout(safe:safe,aspect:landscape ? 3:400/480,minimumDeck:320,compactDualScreen:true,overlayLandscape:landscape)
            let deck=TouchDeck(frame:layout.deck);deck.style=ControlStyle(console:.threeDS,defaults:nil);deck.landscape=landscape;deck.layoutIfNeeded()
            try ControllerSkinGeometry.validate(deck.zones,size:layout.deck.size,orientation:landscape ? .landscape:.portrait,overlay:landscape)
            for name in ["A","B","X","Y"] {
                let target=try XCTUnwrap(deck.zones[name])
                XCTAssertGreaterThanOrEqual(target.width,55.9)
                XCTAssertEqual(deck.inputMask(at:CGPoint(x:target.midX,y:target.midY)),GameConsole.threeDS.buttonMask(name))
            }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(deck.zones["L"]).width,110)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(deck.zones["stick0"]).width,90)
            for target in deck.zones.values {
                let frame=target.offsetBy(dx:layout.deck.minX,dy:layout.deck.minY)
                if !landscape {XCTAssertTrue(frame.intersection(layout.screen).isNull,"A control covers the portrait picture")}
            }
            if !landscape {XCTAssertEqual(layout.screen.width,size.width,accuracy:0.001)}
            let image=UIGraphicsImageRenderer(size:size).image {context in
                deck.style.background.setFill();context.fill(safe)
                UIColor.systemIndigo.setFill();context.fill(layout.screen.withHeight(layout.screen.height/2))
                let lower=CGRect(x:layout.screen.minX+layout.screen.width*0.1,y:layout.screen.midY,width:layout.screen.width*0.8,height:layout.screen.height/2)
                UIColor.systemTeal.setFill();context.fill(lower)
                SkinDrawing.text("400 × 240",in:layout.screen.withHeight(layout.screen.height/2),size:22,color:.white)
                SkinDrawing.text("320 × 240",in:lower,size:22,color:.black)
                SkinDrawing.text("VETA / 3DS",in:layout.toolbar,size:16,color:.white)
                context.cgContext.translateBy(x:layout.deck.minX,y:layout.deck.minY);deck.layer.render(in:context.cgContext)
            }
            let path=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("threeDS-large-148-\(index).png")
            try XCTUnwrap(image.pngData()).write(to:path)
        }
    }
    func testDeterministicPreviewStyleIgnoresPreferenceStore() {
        defaults.set(1.2,forKey:"native.controlSize");defaults.set("Noche",forKey:"native.skin")
        XCTAssertEqual(ControlStyle(console:.nes,defaults:defaults).size,1.2)
        XCTAssertEqual(ControlStyle(console:.nes,defaults:nil).size,1)
        XCTAssertEqual(ControlStyle(console:.nes,defaults:nil).skin,"VETA")
    }
}
