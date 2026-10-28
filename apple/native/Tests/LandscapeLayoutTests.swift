import XCTest
import UIKit
@testable import VetaNative

@MainActor final class LandscapeLayoutTests:XCTestCase {
    func testLandscapeUsesFullAvailablePictureWithoutStretching() {
        let safe=CGRect(x:59,y:0,width:734,height:372)
        let aspects:[CGFloat]=[4.0/3.0,3.0/2.0,16.0/9.0,8.0/3.0,3]
        for aspect in aspects {
            let value=ConsoleLayout(safe:safe,aspect:aspect,overlayLandscape:true)
            let previous=ConsoleLayout(safe:safe,aspect:aspect)
            XCTAssertEqual(value.screen.width/value.screen.height,aspect,accuracy:0.0001)
            XCTAssertTrue(safe.contains(value.screen))
            XCTAssertGreaterThan(value.screen.width*value.screen.height,previous.screen.width*previous.screen.height)
            XCTAssertEqual(value.deck,safe)
            XCTAssertEqual(value.screen.midX,safe.midX,accuracy:0.001)
            XCTAssertTrue(abs(value.screen.height-safe.height)<0.001 || abs(value.screen.width-safe.width)<0.001)
        }
        let portrait=CGRect(x:0,y:59,width:393,height:759)
        XCTAssertEqual(ConsoleLayout(safe:portrait).screen,ConsoleLayout(safe:portrait,overlayLandscape:true).screen)
    }
    func testAllAutomaticLandscapesHaveReachableDistinctControls()throws {
        for console in GameConsole.allCases {
            for size in [CGSize(width:568,height:320),CGSize(width:734,height:372),CGSize(width:844,height:320),CGSize(width:1024,height:748)] {
                let deck=TouchDeck(frame:CGRect(origin:.zero,size:size))
                deck.style=ControlStyle(console:console,defaults:nil);deck.landscape=true;deck.layoutIfNeeded()
                XCTAssertTrue(deck.usesLandscapeOverlay)
                try ControllerSkinGeometry.validate(deck.zones,size:size,orientation:.landscape,overlay:true)
                XCTAssertEqual(Set(deck.zones.keys),Set(TouchDeck.baseZones(style:deck.style,size:size,landscape:true).keys))
                for (name,zone) in deck.zones where name != "dpad" && !name.hasPrefix("stick") {
                    let point=CGPoint(x:zone.midX,y:zone.midY)
                    XCTAssertTrue(deck.point(inside:point,with:nil))
                    // Select is an existing pulse emitted on touchesEnded,
                    // not a held bit from inputMask(at:).
                    XCTAssertEqual(deck.inputMask(at:point),name == "SELECT" ? 0:console.buttonMask(name),"\(console) / \(name)")
                }
                XCTAssertFalse(deck.point(inside:CGPoint(x:size.width/2,y:size.height/2),with:nil),"The empty centre must pass touches to the game")
                XCTAssertFalse(deck.point(inside:CGPoint(x:size.width/2,y:22),with:nil),"The pause menu must remain reachable")
                let a=try XCTUnwrap(deck.zones["A"])
                XCTAssertTrue(deck.point(inside:CGPoint(x:a.midX,y:a.midY),with:nil))
            }
        }
    }
    func testNewLandscapeLayoutRoundTripsAndLegacyKeepsItsRails()throws {
        for console in GameConsole.allCases {
            let modern=ControllerSkinLayout.makeDefault(console:console,orientation:.landscape,palette:.classic)
            XCTAssertEqual(modern.version,3)
            let decoded=try ControllerSkinLayout.decode(modern.encoded(),console:console,orientation:.landscape)
            XCTAssertEqual(decoded,modern)
            for width:CGFloat in [568,700,844,1024] {
                let zones=try decoded.resolved(console:console,orientation:.landscape,size:CGSize(width:width,height:320))
                try ControllerSkinGeometry.validate(zones,size:CGSize(width:width,height:320),orientation:.landscape,overlay:true)
            }
            let size=ControllerSkinOrientation.landscape.canvas
            let old=ControllerSkinGeometry.fitted(TouchDeck.baseZones(style:ControlStyle(console:console,defaults:nil),size:size,landscape:true),size:size,orientation:.landscape)
            let legacy=ControllerSkinLayout(console:console.rawValue,orientation:.landscape,palette:.classic,controls:old.keys.sorted().map{ControllerSkinControl(id:$0,rect:old[$0]!,canvas:size)})
            let restored=try ControllerSkinLayout.decode(legacy.encoded(),console:console,orientation:.landscape)
            XCTAssertEqual(restored.version,1)
            XCTAssertFalse(restored.usesLandscapeOverlay)
            let deck=TouchDeck(frame:CGRect(origin:.zero,size:size));deck.landscape=true;deck.style=ControlStyle(console:console,defaults:nil);deck.customLayout=restored;deck.layoutIfNeeded()
            XCTAssertFalse(deck.usesLandscapeOverlay)
            XCTAssertEqual(deck.zones,try restored.resolved(console:console,orientation:.landscape,size:size))
            XCTAssertTrue(deck.zones.values.allSatisfy{$0.maxX<=188.001 || $0.minX>=size.width-188.001})
        }
    }
    func testLandscapeEditorRejectsControlsOverPauseMenu()throws {
        var value=ControllerSkinLayout.makeDefault(console:.nes,orientation:.landscape,palette:.veta)
        let original=value
        XCTAssertThrowsError(try value.move("A",to:CGPoint(x:value.canvas.width/2,y:22)))
        XCTAssertEqual(value,original)
        var invalid=value;invalid.orientation = .portrait
        XCTAssertThrowsError(try invalid.validated(console:.nes,orientation:.portrait))
    }
    func testRotationReleasesPressedInputsAndRestoresPortrait() {
        let deck=TouchDeck(frame:CGRect(x:0,y:0,width:393,height:276))
        deck.style=ControlStyle(console:.gba,defaults:nil);deck.layoutIfNeeded()
        let original=deck.zones
        var releases=0;deck.onInput={if $0==0 {releases+=1}}
        deck.frame=CGRect(x:0,y:0,width:734,height:372);deck.landscape=true;deck.layoutIfNeeded()
        XCTAssertGreaterThan(releases,0)
        deck.frame=CGRect(x:0,y:0,width:393,height:276);deck.landscape=false;deck.layoutIfNeeded()
        XCTAssertEqual(deck.zones,original)
    }
    func testLandscapePreviewUsesPlayableDrawingAndTargets()throws {
        let size=CGSize(width:734,height:372),safe=CGRect(origin:.zero,size:size)
        for console in [GameConsole.nes,.gba,.ds,.threeDS,.psp,.ps2] {
            let aspect:CGFloat=console == .ds ? 8.0/3.0:console == .threeDS ? 3:console.aspect
            let layout=ConsoleLayout(safe:safe,aspect:aspect,overlayLandscape:true)
            let deck=TouchDeck(frame:safe);deck.style=ControlStyle(console:console,defaults:nil);deck.landscape=true;deck.layoutIfNeeded()
            let image=UIGraphicsImageRenderer(size:size).image {context in
                UIColor.black.setFill();context.fill(safe)
                UIColor(hex:0x395a63).setFill();context.fill(layout.screen)
                for x in stride(from:layout.screen.minX,through:layout.screen.maxX,by:24) {
                    UIColor.white.withAlphaComponent(0.08).setFill();context.fill(CGRect(x:x,y:layout.screen.minY,width:1,height:layout.screen.height))
                }
                for y in stride(from:layout.screen.minY,through:layout.screen.maxY,by:24) {
                    UIColor.white.withAlphaComponent(0.08).setFill();context.fill(CGRect(x:layout.screen.minX,y:y,width:layout.screen.width,height:1))
                }
                SkinDrawing.text(console.shortName+" · LAYOUT PREVIEW",in:layout.screen,size:20,color:.white)
                deck.layer.render(in:context.cgContext)
                UIColor.black.withAlphaComponent(0.4).setFill();UIBezierPath(roundedRect:layout.toolbar,cornerRadius:8).fill()
                SkinDrawing.text("Menú",in:layout.toolbar,size:14,color:.white)
            }
            let path=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("landscape151-"+console.rawValue+".png")
            try XCTUnwrap(image.pngData()).write(to:path)
            if ProcessInfo.processInfo.environment["VETA_HEADLESS_HOME"] == nil {
                let attachment=XCTAttachment(image:image);attachment.name="landscape151-"+console.rawValue;attachment.lifetime = .keepAlways;add(attachment)
            }
        }
    }

    func testLandscapeGeneralSlidersMoveThumbGroupsWithinSafeTargets()throws {
        let size=CGSize(width:734,height:372)
        var style=ControlStyle(console:.gba,defaults:nil)
        let original=TouchDeck.overlayZones(style:style,size:size)
        style.height = -0.1
        let higher=TouchDeck.overlayZones(style:style,size:size)
        XCTAssertLessThan(try XCTUnwrap(higher["dpad"]).midY,try XCTUnwrap(original["dpad"]).midY)
        XCTAssertLessThan(try XCTUnwrap(higher["A"]).midY,try XCTUnwrap(original["A"]).midY)
        style.height=0;style.spacing=0.8
        let closer=TouchDeck.overlayZones(style:style,size:size)
        XCTAssertGreaterThan(try XCTUnwrap(closer["dpad"]).midX,try XCTUnwrap(original["dpad"]).midX)
        XCTAssertLessThan(try XCTUnwrap(closer["A"]).midX,try XCTUnwrap(original["A"]).midX)
        for console in GameConsole.allCases {
            for height in [-0.12,0.12] {for spacing in [0.8,1.2] {
                var adjusted=ControlStyle(console:console,defaults:nil);adjusted.height=height;adjusted.spacing=spacing
                let zones=ControllerSkinGeometry.fitted(TouchDeck.overlayZones(style:adjusted,size:size),size:size,orientation:.landscape,overlay:true)
                try ControllerSkinGeometry.validate(zones,size:size,orientation:.landscape,overlay:true)
            }}
        }
    }

}
