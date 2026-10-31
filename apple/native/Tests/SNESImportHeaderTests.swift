import XCTest
@testable import VetaNative
@MainActor final class SNESImportHeaderTests: XCTestCase {
    func rom(copier:Bool=false) -> Data {
        let o=copier ? 512:0
        var d=Data(repeating:0,count:65536+o)
        d[o]=0x78;d[o+0x7fd5]=0x53;d[o+0x7ffc]=0;d[o+0x7ffd]=0x80
        d[o+0x7fdc]=0xcb;d[o+0x7fdd]=0xed;d[o+0x7fde]=0x34;d[o+0x7fdf]=0x12
        return d
    }
    func testLegacyTitleMapperWithIndependentEvidence() throws {
        try Library.validateROM(rom(),console:.snes)
        try Library.validateROM(rom(copier:true),console:.snes)
    }
    func testMalformedLegacyHeaderRejected() {
        var d=rom();d[0x7fde]=0;XCTAssertThrowsError(try Library.validateROM(d,console:.snes))
        d=rom();d[0]=0xff;XCTAssertThrowsError(try Library.validateROM(d,console:.snes))
        XCTAssertThrowsError(try Library.validateROM(Data(repeating:0,count:65536),console:.snes))
    }
    func testHeaderlessNativeTrampolineHasBoundedDestination() throws {
        var d=Data(repeating:0,count:65536)
        d[0xfffc]=0xb7;d[0xfffd]=0xff
        d.replaceSubrange(0xffb7..<0xffbd,with:[0x18,0xfb,0x5c,0x00,0x80,0xc0]);d[0x8000]=0x78
        try Library.validateROM(d,console:.snes)
        d[0xffbc]=0xff;XCTAssertThrowsError(try Library.validateROM(d,console:.snes))
    }
}
