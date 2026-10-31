import XCTest
@testable import VetaNative
@MainActor final class CoreLoadRecoveryTests:XCTestCase {
 func testGBRejectedCartridgeDoesNotPoisonNextLoad() throws {
  let source=try XCTUnwrap(Bundle.main.url(forResource:"akanoid-gb",withExtension:"gb",subdirectory:"Content/akanoid-gb"))
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  defer{veta_unload();try? fm.removeItem(at:root)}
  let invalid=root.appendingPathComponent("invalid.gb")
  try Data(repeating:0,count:32768).write(to:invalid)
  for _ in 0..<3 {
   XCTAssertTrue(veta_load_system_mode(source.path,root.path,root.path,"Auto",GameConsole.gb.coreIndex,false))
   for _ in 0..<60 {veta_run();veta_audio_clear()}
   veta_unload()
   XCTAssertFalse(veta_load_system_mode(invalid.path,root.path,root.path,"Auto",GameConsole.gbc.coreIndex,false))
   veta_unload()
  }
  XCTAssertTrue(veta_load_system_mode(source.path,root.path,root.path,"Auto",GameConsole.gb.coreIndex,false))
  for _ in 0..<60 {veta_run();veta_audio_clear()}
  XCTAssertGreaterThan(veta_width(),0)
 }
}
