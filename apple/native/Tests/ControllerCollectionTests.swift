import XCTest
import GameController
@testable import VetaNative

@MainActor final class ControllerCollectionTests: XCTestCase {
    func testEveryConsoleAvailableButOnlyPopulatedVisibleAndChronological() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Set([GameConsole.nes])).write(to: root.appendingPathComponent("consoles.json"))
        let library = Library(root: root)
        XCTAssertEqual(library.consoles, Set(GameConsole.allCases))
        XCTAssertTrue(library.populatedConsoles.isEmpty)
        library.games = [.init(id:"one",name:"GB",console:.gb), .init(id:"two",name:"Atari",console:.atari2600),.init(id:"three",name:"GB2",console:.gb),.init(id:"retired",name:"OldPS2",console:.ps2)]
        XCTAssertEqual(library.populatedConsoles, [.atari2600,.gb])
        library.games.removeAll { $0.console == .gb }
        XCTAssertEqual(library.populatedConsoles, [.atari2600])
        XCTAssertEqual(library.consoles.count, GameConsole.allCases.count)
    }
    func testFullscreenNeedsPlayerOneAndReturnsTouchWhenDisconnected() {
        XCTAssertTrue(ControllerDisplayPolicy.fullscreen(ports:[0,1],maximumPlayers:2,enabled:true,phoneIsControl:false))
        XCTAssertFalse(ControllerDisplayPolicy.fullscreen(ports:[1],maximumPlayers:2,enabled:true,phoneIsControl:false))
        XCTAssertFalse(ControllerDisplayPolicy.fullscreen(ports:[],maximumPlayers:4,enabled:true,phoneIsControl:false))
        XCTAssertFalse(ControllerDisplayPolicy.fullscreen(ports:[0],maximumPlayers:2,enabled:false,phoneIsControl:false))
        XCTAssertFalse(ControllerDisplayPolicy.fullscreen(ports:[0],maximumPlayers:2,enabled:true,phoneIsControl:true))
    }
    func testLargestAspectFitInBothOrientationsForEveryConsole() {
        for safe in [CGRect(x:0,y:60,width:393,height:750),CGRect(x:59,y:0,width:734,height:372)] {
            for console in GameConsole.allCases {
                let frame = ControllerDisplayPolicy.frame(safe:safe,aspect:console.aspect)
                XCTAssertTrue(safe.insetBy(dx:-0.001,dy:-0.001).contains(frame),console.name)
                XCTAssertEqual(frame.width/frame.height,console.aspect,accuracy:0.0001)
                XCTAssertTrue(abs(frame.width-safe.width)<0.001 || abs(frame.height-safe.height)<0.001)
            }
        }
    }
    func testAppleSoftwareControllerMapsInputForEveryPublicConsole() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try XCTUnwrap(controller.extendedGamepad)
        for console in GameConsole.allCases {
            let mapping = ControllerHub.defaults(for:console)
            pad.buttonA.setValue(1); pad.dpad.setValueForXAxis(0,yAxis:1)
            let pressed = ControllerHub.input(pad:pad,console:console,mapping:mapping)
            XCTAssertEqual(pressed.mask, console.buttonMask(mapping[0]) | (1<<4),console.name)
            pad.buttonA.setValue(0); pad.dpad.setValueForXAxis(0,yAxis:0)
            XCTAssertEqual(ControllerHub.input(pad:pad,console:console,mapping:mapping),ControllerInputState(),console.name)
            pad.leftThumbstick.setValueForXAxis(1,yAxis:0)
            let moved = ControllerHub.input(pad:pad,console:console,mapping:mapping)
            if console.analogSticks > 0 { XCTAssertEqual(moved.axes[0].x,1,accuracy:0.001) }
            else { XCTAssertEqual(moved.mask,1<<7) }
            pad.leftThumbstick.setValueForXAxis(0,yAxis:0)
        }
    }
    func testNintendo64RightStickHasAllFourCButtons() throws {
        let controller = GCController.withExtendedGamepad(), console = GameConsole.n64
        let pad = try XCTUnwrap(controller.extendedGamepad)
        for (x,y,action):(Float,Float,String) in [(1,0,"C→"),(-1,0,"C←"),(0,1,"C↑"),(0,-1,"C↓")] {
            pad.rightThumbstick.setValueForXAxis(x,yAxis:y)
            XCTAssertEqual(ControllerHub.input(pad:pad,console:console,mapping:ControllerHub.defaults(for:console)).mask,console.buttonMask(action))
        }
    }
    func testFourPlayersRemainStableAfterDisconnectAndReplacement() {
        var slots = PlayerSlots()
        for i in 0..<4 { XCTAssertEqual(slots.assign("pad\(i)",maximum:4),i) }
        XCTAssertNil(slots.assign("extra",maximum:4))
        slots.remove("pad1")
        XCTAssertEqual(slots.owners["pad0"],0); XCTAssertEqual(slots.owners["pad2"],2); XCTAssertEqual(slots.owners["pad3"],3)
        XCTAssertEqual(slots.assign("new",maximum:4),1)
        XCTAssertFalse(slots.move("new",to:2,maximum:4))
    }
}
