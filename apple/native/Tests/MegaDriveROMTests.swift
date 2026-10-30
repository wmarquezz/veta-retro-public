import XCTest
import UIKit
@testable import VetaNative

@MainActor final class MegaDriveROMTests: XCTestCase {
    func rom() -> Data {
        var data=Data((0..<32768).map{UInt8(truncatingIfNeeded:$0 / 3)})
        data.replaceSubrange(0x100..<0x104,with:Data("SEGA".utf8));return data
    }
    func smd(_ raw:Data)->Data {
        var output=Data(repeating:0,count:512+raw.count)
        output[8]=0xaa;output[9]=0xbb;output[10]=6
        for b in stride(from:0,to:raw.count,by:16384) {
            for i in 0..<8192 {output[512+b+i]=raw[b+2*i+1];output[512+b+8192+i]=raw[b+2*i]}
        };return output
    }
    func testSMDAndMislabeledBINNormalizeEveryByteWithoutChangingRaw() throws {
        let raw=rom(),interleaved=smd(raw)
        for ext in ["smd","SMD","bin","md","gen"] {
            XCTAssertEqual(try MegaDriveROM.normalize(interleaved,extension:ext),raw)
            XCTAssertEqual(try MegaDriveROM.normalize(raw,extension:ext),raw)
        }
        XCTAssertEqual(try MegaDriveROM.normalize(interleaved,extension:"sfc"),interleaved)
    }
    func testInvalidOrTruncatedSMDRejected() throws {
        for data in [Data(),Data(repeating:0,count:512+16384),Data(smd(rom()).dropLast())] {
            XCTAssertThrowsError(try MegaDriveROM.normalize(data,extension:"smd"))
        }
        XCTAssertFalse(MegaDriveROM.isCartridge(Data(repeating:0xff,count:32768)))
    }
    func testLegacyHeadersAndResetVectors() {
        var raw=rom();raw.replaceSubrange(0x100..<0x120,with:Data(repeating:32,count:32))
        raw.replaceSubrange(0x108..<0x10c,with:Data("SEGA".utf8));XCTAssertTrue(MegaDriveROM.isCartridge(raw))
        raw.replaceSubrange(0x100..<0x120,with:Data(repeating:0,count:32))
        raw.replaceSubrange(0..<8,with:Data([0xff,0xff,0xff,0xf8,0,0,2,0]));XCTAssertTrue(MegaDriveROM.isCartridge(raw))
        raw[7]=1;XCTAssertFalse(MegaDriveROM.isCartridge(raw))
    }
    func testZIPWithCoverThenRawDeduplicatesAndPreservesSave() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let raw=rom(),payload=smd(raw),zip=root.appendingPathComponent("My Game.zip")
        let builder=ZIPGameImportTests();try builder.stored("Original.SMD",payload:payload).write(to:zip)
        let cover=root.appendingPathComponent("My Game.png")
        try UIGraphicsImageRenderer(size:CGSize(width:20,height:20)).pngData { c in UIColor.orange.setFill();c.fill(CGRect(x:0,y:0,width:20,height:20)) }.write(to:cover)
        let library=Library(root:root.appendingPathComponent("library")),suite=UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!;defer{defaults.removePersistentDomain(forName:suite)}
        let artwork=ArtworkStore(root:library.root,defaults:defaults)
        let summary=try library.importURLs([zip,cover],console:nil,artwork:artwork)
        XCTAssertEqual(summary.games,1);XCTAssertEqual(summary.covers,1)
        let game=try XCTUnwrap(library.games.first);XCTAssertEqual(game.console,.megaDrive)
        XCTAssertEqual(try Data(contentsOf:library.romURL(game)),raw)
        let save=library.file(game,"battery.sav");try FileManager.default.createDirectory(at:save.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data([7,8,9]).write(to:save)
        let bin=root.appendingPathComponent("Other.bin");try raw.write(to:bin)
        XCTAssertEqual(try library.importURL(bin)?.id,game.id);XCTAssertEqual(library.games.count,1)
        XCTAssertEqual(try Data(contentsOf:save),Data([7,8,9]))
        XCTAssertEqual(try Data(contentsOf:zip),try builder.stored("Original.SMD",payload:payload))
    }
}
