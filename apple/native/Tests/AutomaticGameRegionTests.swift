import XCTest
@testable import VetaNative
final class AutomaticGameRegionTests:XCTestCase {
 func testEuropeanSMSUsesPALWithoutChangingSavedProfile() throws {
  let saved=try CoreProfile.resolved(console:.masterSystem,consoleProfile:.init(),gameProfile:.init())
  let launch=saved.forLaunch(game:Game(id:"test",name:"Example (Europe)",console:.masterSystem))
  XCTAssertEqual(saved.values[CoreOptionID.segaRegion.rawValue],"auto")
  XCTAssertEqual(launch.values[CoreOptionID.segaRegion.rawValue],"pal")
  XCTAssertNotEqual(saved.fingerprint,launch.fingerprint)
 }
 func testExplicitChoiceWinsOverFilename() throws {
  let saved=try CoreProfile.resolved(console:.masterSystem,consoleProfile:.init(),gameProfile:.init(values:[CoreOptionID.segaRegion.rawValue:"ntsc-u"]))
  XCTAssertEqual(saved.forLaunch(game:Game(id:"test",name:"Example (Europe)",console:.masterSystem)).values[CoreOptionID.segaRegion.rawValue],"ntsc-u")
 }
 func testMixedUnknownAndWorldReleasesKeepAutomatic() throws {
  let profile=try CoreProfile.resolved(console:.masterSystem,consoleProfile:.init(),gameProfile:.init())
  for name in ["Example (USA, Europe)","Example (World)","Example","Example (Japan)"] {
   XCTAssertEqual(profile.forLaunch(game:Game(id:"test",name:name,console:.masterSystem)),profile)
  }
 }
 func testOtherSegaConsolesKeepTheirOwnDetection() throws {
  for console in [GameConsole.gameGear,.megaDrive] {
   let profile=try CoreProfile.resolved(console:console,consoleProfile:.init(),gameProfile:.init())
   XCTAssertEqual(profile.forLaunch(game:Game(id:"test",name:"Example (Europe)",console:console)),profile)
  }
 }
 func testNESHeaderDecisionAndExplicitOverrideArePreserved() throws {
  let profile=try CoreProfile.resolved(console:.nes,consoleProfile:.init(),gameProfile:.init())
  XCTAssertEqual(profile.forLaunch(game:Game(id:"test",name:"Example"),nesRegion:"PAL").values[CoreOptionID.nesRegion.rawValue],"PAL")
  let explicit=CoreProfile(values:[CoreOptionID.nesRegion.rawValue:"NTSC"])
  XCTAssertEqual(explicit.forLaunch(game:Game(id:"test",name:"Example"),nesRegion:"PAL"),explicit)
 }
}
