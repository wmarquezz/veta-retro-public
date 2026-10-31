import XCTest
@testable import VetaNative
@MainActor final class SNESChipStartupTests:XCTestCase {
 func testDSPCartridgeInitializesWithoutExternalFirmware() throws {
  // Original synthetic cartridge: SEI; CLC; XCE; JMP $8003. No game assets.
  var rom=Data(repeating:0,count:65536)
  rom.replaceSubrange(0..<6,with:[0x78,0x18,0xfb,0x4c,0x03,0x80])
  rom.replaceSubrange(0x7fc0..<0x7fd5,with:Data("VETA DSP STARTUP TEST ".utf8))
  rom[0x7fd5]=0x20;rom[0x7fd6]=0x03;rom[0x7fd7]=6
  rom[0x7fd9]=1;rom[0x7fda]=0x33
  rom[0x7fdc]=0xcb;rom[0x7fdd]=0xed;rom[0x7fde]=0x34;rom[0x7fdf]=0x12
  rom[0x7ffc]=0;rom[0x7ffd]=0x80
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  defer{veta_unload();try? fm.removeItem(at:root)}
  let file=root.appendingPathComponent("synthetic.sfc");try rom.write(to:file)
  XCTAssertTrue(veta_load_system_mode(file.path,root.path,root.path,"Auto",GameConsole.snes.coreIndex,false))
  for _ in 0..<5 {veta_run();veta_audio_clear()}
  XCTAssertGreaterThan(veta_width(),0)
 }
}
