import XCTest
import UIKit
@testable import VetaNative

@MainActor final class GameplayToolsTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("Gameplay-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {veta_unload();try? FileManager.default.removeItem(at:root)}
    private func frame()->Data {Data(bytes:veta_video(),count:Int(veta_width()*veta_height()*4))}
    private func runFrames(_ count:Int=90){for _ in 0..<count {veta_run();veta_audio_clear()}}
    /// Original minimal NROM test program: writes RAM[0] to backdrop palette.
    /// Game Genie patches the immediate byte at CPU800E; no third-party ROM.
    private func paletteROM()throws->URL {
        var rom=Data(repeating:0,count:16+16384+8192)
        rom.replaceSubrange(0..<6,with:[0x4e,0x45,0x53,0x1a,1,1])
        let program:[UInt8]=[0x78,0xd8,0xa2,0xff,0x9a,0xa9,0,0x8d,0,0x20,0x8d,1,0x20,0xa9,0x0f,0x85,0,0x2c,2,0x20,0x10,0xfb,0xa9,0x3f,0x8d,6,0x20,0xa9,0,0x8d,6,0x20,0xa5,0,0x8d,7,0x20,0x4c,0x11,0x80]
        rom.replaceSubrange(16..<16+program.count,with:program)
        for vector in [0x3ffa,0x3ffc,0x3ffe] {rom[16+vector]=0;rom[16+vector+1]=0x80}
        let url=root.appendingPathComponent("palette.nes");try rom.write(to:url);return url
    }
    private func load(_ url:URL,console:GameConsole = .nes)throws {
        XCTAssertTrue(veta_load_console(url.path,root.path,"NTSC",console.coreIndex));runFrames()
    }
    func testRealNESCheatsGameGenieRawDisableAndRejectedListPreservesActiveCode()throws {
        let rom=try paletteROM();try load(rom);let original=frame()
        let six=NESCheat(name:"Patch palette",code:"ZZAETE",enabled:true)
        try NESCheat.install([six]);veta_reset();runFrames();let changed=frame()
        XCTAssertNotEqual(changed,original,"Game Genie must modify the real CPU ROM read, not just a UI flag")
        let eight=NESCheat(name:"Compare palette",code:"ZZAETEYE",enabled:true)
        try NESCheat.install([eight]);veta_reset();runFrames();XCTAssertEqual(frame(),changed)
        let mismatch=NESCheat(name:"Wrong compare",code:"ZZAETETE",enabled:true)
        try NESCheat.install([mismatch]);veta_reset();runFrames();XCTAssertEqual(frame(),original,"Eight-letter compare must be honored by real core")
        let raw=NESCheat(name:"RAM palette",code:"0000:2A",enabled:true)
        try NESCheat.install([raw]);veta_reset();runFrames();XCTAssertEqual(frame(),changed)
        "0000:2A".withCString { first in
            "AAAA:GG".withCString { second in
                let pointers:[UnsafePointer<CChar>?]=[first,second]
                XCTAssertFalse(pointers.withUnsafeBufferPointer{veta_nes_cheats_replace($0.baseAddress,$0.count)})
            }
        }
        veta_reset();runFrames();XCTAssertEqual(frame(),changed,"Invalid list must not clear a currently working cheat")
        try NESCheat.install([NESCheat(name:"Disabled",code:"0000:2A",enabled:false)]);veta_reset();runFrames();XCTAssertEqual(frame(),original)
        try NESCheat.install([six]);veta_unload();try load(rom);XCTAssertEqual(frame(),original,"Cheats must not leak to reopened sessions")
    }
    func testScreenshotIsLosslessFullResolutionOfRealFrame()throws {
        try load(paletteROM());try NESCheat.install([NESCheat(name:"Color",code:"0000:2A",enabled:true)]);runFrames()
        let png=try XCTUnwrap(GameplayScreenshot.png())
        XCTAssertEqual(Array(png.prefix(8)),[137,80,78,71,13,10,26,10])
        let decoded=try XCTUnwrap(UIImage(data:png)?.cgImage)
        let width=Int(veta_width()),height=Int(veta_height())
        XCTAssertEqual(decoded.width,width);XCTAssertEqual(decoded.height,height)
        var pixels=[UInt32](repeating:0,count:width*height)
        try pixels.withUnsafeMutableBytes {bytes in
            let context=try XCTUnwrap(CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(decoded,in:CGRect(x:0,y:0,width:width,height:height))
        }
        let actual=UnsafeBufferPointer(start:veta_video(),count:width*height)
        XCTAssertEqual(pixels.map{$0&0xffffff},actual.map{$0&0xffffff})
    }
    func testCheatStorageRejectsInvalidAndDoesNotRewriteExistingList()throws {
        let store=NESCheatStore(url:root.appendingPathComponent("cheats.json"))
        let valid=NESCheat(name:"Palette",code:" zzaete ",enabled:false)
        try store.write([valid]);let bytes=try Data(contentsOf:store.url)
        XCTAssertEqual(try store.read().first?.code,"ZZAETE")
        for code in ["", "AAAA:GG", "ZZAETE+ZZAETE", "0000:2A;0001:2A", "BBBBBB", "0000?FF:2A", "ZZAETE\0X"] {
            XCTAssertThrowsError(try store.write([NESCheat(name:"Rejected",code:code,enabled:true)]))
            XCTAssertEqual(try Data(contentsOf:store.url),bytes)
        }
        XCTAssertThrowsError(try store.write([valid,valid]))
        XCTAssertEqual(try Data(contentsOf:store.url),bytes)
    }
    func testBackupPreservesCheatsAndDeletionRemovesTheirStorage()throws {
        let source=Library(root:root.appendingPathComponent("source"))
        let game=try source.add(data:Data(contentsOf:paletteROM()),name:"Original palette test")
        let cheats=[NESCheat(name:"Enabled palette",code:"ZZAETE",enabled:true),NESCheat(name:"Disabled RAM",code:"0000:2A",enabled:false)]
        try NESCheatStore(url:source.file(game,"cheats-nes.json")).write(cheats)
        let backup=try source.export();defer{try? FileManager.default.removeItem(at:backup)}
        let destination=Library(root:root.appendingPathComponent("destination"))
        try destination.importURL(backup)
        let restored=try XCTUnwrap(destination.games.first)
        let restoredFile=destination.file(restored,"cheats-nes.json")
        XCTAssertEqual(try NESCheatStore(url:restoredFile).read(),cheats)
        try destination.remove(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath:restoredFile.path))
        XCTAssertTrue(destination.games.isEmpty)
        try destination.importURL(backup)
        XCTAssertEqual(try NESCheatStore(url:restoredFile).read(),cheats,"A removed entry must remain restorable from a complete backup")
        let decoded=try JSONDecoder().decode(NativeBackup.self,from:Data(contentsOf:backup))
        var entry=try XCTUnwrap(decoded.entries.first)
        entry.nesCheats=[NESCheat(name:"Invalid",code:"AAAA:GG",enabled:true)]
        let invalid=NativeBackup(format:decoded.format,version:decoded.version,entries:[entry])
        let invalidURL=root.appendingPathComponent("invalid.vetaretro")
        try JSONEncoder().encode(invalid).write(to:invalidURL)
        let rejected=Library(root:root.appendingPathComponent("rejected"))
        XCTAssertThrowsError(try rejected.importURL(invalidURL))
        XCTAssertTrue(rejected.games.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:rejected.directory(game.id).path),"Validate all cheat codes before creating any game files")
    }
    func testBoundedDoubleSpeedRunsRealClassicCoresWithoutChangingClockOrQueuedAudio()throws {
        let docs=PhysicalFixturePaths.root
        var fixtures:[(GameConsole,URL)]=[]
        for (console,name) in [(GameConsole.nes,"thwaite"),(.gb,"sushi-gb"),(.gbc,"gluf-gbc"),(.gba,"space-game")] {
            fixtures.append((console,try XCTUnwrap(Bundle.main.url(forResource:name,withExtension:console.romExtension,subdirectory:"Content/"+name))))
        }
        let snes=docs.appendingPathComponent("SNES/Space Rescue Squad Demo v1.1.sfc")
        XCTAssertTrue(FileManager.default.fileExists(atPath:snes.path),"Supply the existing licensed SNES fixture to validate all advertised cores")
        if FileManager.default.fileExists(atPath:snes.path){fixtures.append((.snes,snes))}
        for (console,url) in fixtures {
            try load(url,console:console);let fps=veta_fps(),rate=veta_sample_rate(),start=veta_frame_count(),dropped=veta_audio_dropped(),missing=veta_audio_underruns()
            var clock=FastForwardClock();var executed=0
            for _ in 0..<60 {executed+=clock.advance(elapsed:1/60,fps:fps){veta_run();veta_audio_clear()}}
            XCTAssertEqual(Int(veta_frame_count()-start),executed);XCTAssertEqual(Double(executed),floor(fps*2),accuracy:1,console.rawValue)
            XCTAssertEqual(veta_fps(),fps);XCTAssertEqual(veta_sample_rate(),rate);XCTAssertEqual(veta_audio_queued(),0)
            XCTAssertEqual(veta_audio_dropped(),dropped);XCTAssertEqual(veta_audio_underruns(),missing)
            XCTAssertEqual(clock.advance(elapsed:30,fps:fps){veta_run();veta_audio_clear()},4,"A stall must never start an unbounded catch-up loop")
            clock.reset();NativeAudio.prefill();XCTAssertGreaterThan(veta_audio_queued(),0)
            let queued=veta_audio_queued();var l=[Float](repeating:0,count:Int(queued)),r=l
            veta_audio_read(&l,&r,queued,1);XCTAssertEqual(veta_audio_queued(),0);XCTAssertEqual(veta_audio_underruns(),missing)
            XCTAssertEqual(veta_fps(),fps);XCTAssertEqual(veta_sample_rate(),rate)
            print("GAMEPLAY_FAST_CORE \(console.rawValue) frames=\(executed) rate=\(rate) target=\(fps)")
            veta_unload()
        }
    }
    func testHeldButtonsPauseCloseAndInterruptReleaseInputs()throws {
        let library=Library(root:root.appendingPathComponent("library")),game=try library.add(data:Data(contentsOf:paletteROM()),name:"Original palette test")
        let session=Emulation(game:game,library:library),screen=MetalScreen();session.open(screen:screen)
        XCTAssertTrue(session.ready)
        session.setHeldButtons(.max)
        XCTAssertEqual(session.heldButtons,0x0101,"Never hold directions, Start or Select")
        session.pause();XCTAssertEqual(session.heldButtons,0);XCTAssertFalse(session.fastForward);XCTAssertEqual(veta_input_mask(0),0)
        session.setHeldButtons(256)
        NotificationCenter.default.post(name:UIApplication.willResignActiveNotification,object:nil)
        XCTAssertEqual(session.heldButtons,0);XCTAssertEqual(veta_input_mask(0),0)
        session.setHeldButtons(1);session.close()
        XCTAssertEqual(session.heldButtons,0);XCTAssertFalse(session.fastForward);XCTAssertEqual(veta_input_mask(0),0)
    }
}
