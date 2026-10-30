import XCTest
import UIKit
@testable import VetaNative

@MainActor final class ManualAutoSaveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        veta_options_clear()
    }
    override func tearDownWithError() throws {
        veta_unload(); veta_options_clear(); try? FileManager.default.removeItem(at: root)
    }
    func testManualPointsSurviveRepeatedAutosavesAndCanBeReadIndependently() throws {
        let store = NativeSaveStore(directory: root, rom: "fixture", core: StateFile.coreID)
        let one = try StateFile.encode(Data([1,2,3]), rom: "fixture", thumbnail: Data([4]))
        let two = try StateFile.encode(Data([7,8,9]), rom: "fixture", thumbnail: Data([5]))
        try store.write(one, slot: store.nextManualSlot())
        try store.write(two, slot: store.nextManualSlot())
        for index in 0..<20 {
            try store.write(StateFile.encode(Data([UInt8(index)]), rom: "fixture"), slot: "auto")
        }
        XCTAssertEqual(try store.read("slot1"), one)
        XCTAssertEqual(try store.read("slot2"), two)
        XCTAssertEqual(try StateFile.decode(store.read("auto"), rom: "fixture", core: StateFile.coreID), Data([19]))
        XCTAssertEqual(try StateFile.decode(store.read("previous-auto"), rom: "fixture", core: StateFile.coreID), Data([18]))
        XCTAssertEqual(try store.nextManualSlot(), "slot3")
    }
    func testFullOrCorruptSlotsNeverCauseImplicitReplacement() throws {
        let store = NativeSaveStore(directory: root, rom: "fixture", core: StateFile.coreID)
        let corrupt = Data("legacy-unreadable".utf8)
        try corrupt.write(to: store.url("slot1"))
        XCTAssertEqual(try store.nextManualSlot(), "slot2")
        for slot in NativeSaveStore.manualSlots.dropFirst() {
            try store.write(StateFile.encode(Data([3]), rom: "fixture"), slot: slot)
        }
        XCTAssertThrowsError(try store.nextManualSlot())
        XCTAssertEqual(try store.read("slot1"), corrupt)
        try store.delete("slot5")
        XCTAssertEqual(try store.nextManualSlot(), "slot5")
    }
    func testNESManualPointsLoadAfterLaterAutomaticState() throws {
        let fixture = try XCTUnwrap(Bundle(for: ManualAutoSaveTests.self).url(forResource: "thwaite", withExtension: "nes"))
        XCTAssertTrue(veta_load(fixture.path, root.path, "NTSC"))
        let store = NativeSaveStore(directory: root, rom: "fixture", core: StateFile.coreID)
        func capture() throws -> Data {
            var bytes = Data(count: veta_state_size()); XCTAssertFalse(bytes.isEmpty)
            XCTAssertTrue(bytes.withUnsafeMutableBytes { veta_save_state($0.baseAddress, $0.count) })
            return try StateFile.encode(bytes, rom: "fixture", thumbnail: XCTUnwrap(NativeSaveStore.thumbnail()))
        }
        func frameHash() throws -> String {
            let pixels = try XCTUnwrap(veta_video())
            return sha256(Data(bytes: pixels, count: Int(veta_width()) * Int(veta_height()) * 4))
        }
        for _ in 0..<120 { veta_run() }
        try store.write(capture(), slot: store.nextManualSlot())
        for _ in 0..<5 { veta_run() }
        let expectedOne = try frameHash()
        veta_set_input(0, 8)
        for _ in 0..<5 { veta_run() }; veta_set_input(0, 0)
        for _ in 0..<180 { veta_run() }
        try store.write(capture(), slot: store.nextManualSlot())
        for _ in 0..<5 { veta_run() }
        let expectedTwo = try frameHash()
        for _ in 0..<120 { veta_run() }
        try store.write(capture(), slot: "auto")
        for (slot, expected) in [("slot1", expectedOne), ("slot2", expectedTwo)] {
            let bytes = try StateFile.decode(store.read(slot), rom: "fixture", core: StateFile.coreID)
            XCTAssertTrue(bytes.withUnsafeBytes { veta_load_state($0.baseAddress, $0.count) })
            for _ in 0..<5 { veta_run() }
            XCTAssertEqual(try frameHash(), expected)
            XCTAssertNotNil(store.list().first { $0.id == slot }?.state?.thumbnail)
        }
    }
}
