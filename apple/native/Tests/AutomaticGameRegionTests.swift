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
 func testEuropeanMegaDriveUsesPALAndExplicitSettingWins() throws {
  let profile=try CoreProfile.resolved(console:.megaDrive,consoleProfile:.init(),gameProfile:.init())
  let game=Game(id:"8c254d82237eba38a22d8d434ddd99b9187e408c6eb0393579f864f8c5e882ba",name:"Unknown filename",console:.megaDrive)
  XCTAssertEqual(profile.forLaunch(game:game).values[CoreOptionID.segaRegion.rawValue],"pal")
  let explicit=CoreProfile(values:[CoreOptionID.segaRegion.rawValue:"ntsc-u"])
  XCTAssertEqual(explicit.forLaunch(game:game),explicit)
  XCTAssertEqual(profile.forLaunch(game:Game(id:"test",name:"Example (USA, Europe)",console:.megaDrive)),profile)
 }
 func testNESHeaderDecisionAndExplicitOverrideArePreserved() throws {
  let profile=try CoreProfile.resolved(console:.nes,consoleProfile:.init(),gameProfile:.init())
  XCTAssertEqual(profile.forLaunch(game:Game(id:"test",name:"Example"),nesRegion:"PAL").values[CoreOptionID.nesRegion.rawValue],"PAL")
  let explicit=CoreProfile(values:[CoreOptionID.nesRegion.rawValue:"NTSC"])
  XCTAssertEqual(explicit.forLaunch(game:Game(id:"test",name:"Example"),nesRegion:"PAL"),explicit)
 }
}
