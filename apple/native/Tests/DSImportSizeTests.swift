import XCTest
@testable import VetaNative

@MainActor final class DSImportSizeTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func sparseROM(bytes: Int, ext: String = "nds", validSections: Bool = true) throws -> URL {
        let url = root.appendingPathComponent("SizeBoundary." + ext)
        var header = Data(repeating:0,count:512)
        func word(_ offset:Int,_ value:UInt32) { for i in 0..<4 { header[offset+i] = UInt8(truncatingIfNeeded:value >> (8*i)) } }
        word(0x20,512);word(0x2c,4);word(0x30,516);word(0x3c,validSections ? 4:UInt32.max)
        try header.write(to:url)
        let handle = try FileHandle(forWritingTo:url);defer { try? handle.close() }
        try handle.truncate(atOffset:UInt64(bytes));return url
    }
    func testDSAt512MiBBoundaryImportsWithoutPreferredConsole() throws {
        let file = try sparseROM(bytes:512*1024*1024,ext:"NDS")
        let library = Library(root:root.appendingPathComponent("library"))
        let game = try XCTUnwrap(library.importURL(file))
        XCTAssertEqual(game.console,.ds)
        XCTAssertEqual(try library.romURL(game).resourceValues(forKeys:[.fileSizeKey]).fileSize,512*1024*1024)
    }
    func testDSAbove512MiBIsRejectedWithoutCreatingGame() throws {
        let file = try sparseROM(bytes:512*1024*1024+1)
        let library = Library(root:root.appendingPathComponent("library"))
        XCTAssertThrowsError(try library.importURL(file,console:.ds));XCTAssertTrue(library.games.isEmpty)
    }
    func testLargeDSStillRejectsOutOfBoundsARMSections() throws {
        let file = try sparseROM(bytes:257*1024*1024,validSections:false)
        let library = Library(root:root.appendingPathComponent("library"))
        XCTAssertThrowsError(try library.importURL(file));XCTAssertTrue(library.games.isEmpty)
    }
    func testSelectingDSDoesNotRaiseOtherFormatsOrBackupLimits() throws {
        for ext in ["nes","sfc","gba","vetaretro"] {
            let file = try sparseROM(bytes:256*1024*1024+1,ext:ext)
            let library = Library(root:root.appendingPathComponent(ext))
            XCTAssertThrowsError(try library.importURL(file,console:.ds));XCTAssertTrue(library.games.isEmpty)
        }
    }
}
