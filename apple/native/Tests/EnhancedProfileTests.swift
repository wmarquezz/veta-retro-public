import XCTest
@testable import VetaNative

@MainActor final class EnhancedProfileTests:XCTestCase {
    func testNewSettingsAreExplicitAndDoNotInvalidateInheritedOldStates()throws {
        let ps2=try CoreProfile.resolved(console:.ps2,consoleProfile:.init(),gameProfile:.init())
        XCTAssertEqual(ps2.fingerprint,CoreProfile().fingerprint)
        let psp=try CoreProfile.resolved(console:.psp,consoleProfile:.init(),gameProfile:.init())
        XCTAssertEqual(psp.values,["ppsspp_internal_resolution":"480x272"])
        let chosen=try CoreProfile.resolved(console:.ps2,consoleProfile:.init(values:["play_res_multi":"2x"]),gameProfile:.init(values:["play_res_multi":"1x","play_bilinear_filtering":"true"]))
        XCTAssertEqual(chosen.values,["play_res_multi":"1x","play_bilinear_filtering":"true"])
        XCTAssertThrowsError(try CoreProfile(values:["play_res_multi":"8x"]).validated(for:.ps2))
        XCTAssertThrowsError(try CoreProfile(values:["play_res_multi":"2x"]).validated(for:.psp))
        XCTAssertFalse(veta_option_set("play_res_multi","8x"))
        XCTAssertFalse(veta_option_set("ppsspp_texture_filtering","Fake"))
    }
    func testPlayResolutionProfilesRenderRealXumpWithAudio()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{veta_unload();veta_options_clear();try? FileManager.default.removeItem(at:root)}
        let fixture=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/xump-ps2.iso")
        XCTAssertTrue(FileManager.default.fileExists(atPath:fixture.path))
        let library=Library(root:root),game=try library.importNativeFile(fixture,console:.ps2)
        let system=try library.prepareSystem(for:.ps2),saves=try library.prepareCoreSaves(for:game)
        var baseline:(UInt32,UInt32)?
        for scale in ["1x","2x"] {
            let profile=try CoreProfile(values:["play_res_multi":scale,"play_bilinear_filtering":scale=="2x" ? "true":"false"]).validated(for:.ps2)
            try profile.installForNextLoad()
            XCTAssertTrue(veta_load_system(library.romURL(game).path,saves.path,system.path,"Auto",19))
            for _ in 0..<1800{veta_run();veta_audio_clear()}
            let width=veta_width(),height=veta_height()
            XCTAssertGreaterThan(width,0);XCTAssertGreaterThan(height,0)
            XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(width*height))).count,8)
            XCTAssertGreaterThan(veta_audio_nonzero(),1000)
            if let baseline {XCTAssertEqual(width,baseline.0*2);XCTAssertEqual(height,baseline.1*2)}else{baseline=(width,height)}
            print("PLAY_PROFILE scale=\(scale) size=\(width)x\(height) audio=\(veta_audio_nonzero())")
            veta_unload()
        }
    }
    func testPSPTextureAndResolutionProfilesRenderRealCube()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{veta_unload();veta_options_clear();try? FileManager.default.removeItem(at:root)}
        let fixture=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/cubevfpu.prx")
        XCTAssertTrue(FileManager.default.fileExists(atPath:fixture.path))
        let library=Library(root:root),system=try library.prepareSystem(for:.psp)
        for (resolution,filter) in [("480x272","Nearest"),("960x544","Linear")] {
            try CoreProfile(values:["ppsspp_internal_resolution":resolution,"ppsspp_texture_filtering":filter]).installForNextLoad()
            XCTAssertTrue(veta_load_system(fixture.path,root.path,system.path,"Auto",14))
            let deadline=Date().addingTimeInterval(15)
            repeat{veta_run();veta_audio_clear();Thread.sleep(forTimeInterval:0.001)}while veta_audio_count()==0 && Date()<deadline
            for _ in 0..<180{veta_run();veta_audio_clear()}
            XCTAssertEqual(veta_width(),resolution=="480x272" ? 480:960)
            // PPSSPP keeps its existing crop-to-16:9 default: GetSystemAVInfo removes two rows per scale.
            XCTAssertEqual(veta_height(),resolution=="480x272" ? 270:540)
            XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2)
            print("PSP_PROFILE resolution=\(resolution) filter=\(filter) size=\(veta_width())x\(veta_height())")
            veta_unload()
        }
    }
}
