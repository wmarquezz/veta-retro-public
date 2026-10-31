import XCTest
@testable import VetaNative

final class CartridgeCompatibilityTests: XCTestCase {
    func testCompatibilityEngineAndStateIdentityAreScopedToVerifiedContent() {
        for id in CartridgeCompatibility.gameGear {
            let game=Game(id:id,name:"Renamed",console:.gameGear)
            XCTAssertEqual(game.coreID,"gearsystem-d18766b3-v1")
            XCTAssertNil(CartridgeCompatibility.coreID(id:id,console:.masterSystem))
        }
        for id in CartridgeCompatibility.superGrafx {
            XCTAssertEqual(Game(id:id,name:"Renamed",console:.pcEngine).coreID,"supergrafx-9c11dcd2-v1")
        }
        for console in [GameConsole.gameGear,.pcEngine,.gbc] {
            XCTAssertEqual(Game(id:"unknown",name:"Known-looking title",console:console).coreID,console.coreID)
        }
    }
    func testUnknownHeaderlessCartridgesAndBadN64BackupAreNotWhitelisted() {
        let bytes=Data(repeating:0,count:262144)
        XCTAssertFalse(CartridgeCompatibility.isKnownHeaderlessGameGear(bytes,console:.gameGear))
        XCTAssertFalse(CartridgeCompatibility.isKnownHeaderlessGameGear(bytes,console:.masterSystem))
        XCTAssertFalse(N64ImportNormalization.matchesOriginalIdentity(Data(repeating:0,count:16*1024*1024),id:N64ImportNormalization.originalID))
    }
    func testUnknownFourMegabyteCartridgeIsNeverTrimmed() throws {
        var bytes=Data(repeating:0,count:4*1024*1024)
        bytes.replaceSubrange(0x100..<0x104,with:Data("SEGA".utf8))
        XCTAssertEqual(try MegaDriveROM.normalize(bytes,extension:"bin"),bytes)
    }
    func testUnknownNESHeaderRemainsUntouched() {
        var bytes=Data(repeating:0,count:98320)
        bytes.replaceSubrange(0..<4,with:Data([0x4e,0x45,0x53,0x1a]))
        XCTAssertEqual(NESROM.normalize(bytes),bytes)
    }
}
