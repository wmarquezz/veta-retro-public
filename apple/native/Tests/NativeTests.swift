import XCTest
import UIKit
@testable import VetaNative

@MainActor final class NativeTests:XCTestCase {
    func testPS2CompressedDiscRoutingAndBounds() throws {
        var header=Data(repeating:0,count:64)
        header.replaceSubrange(0..<4,with:Data("CISO".utf8))
        header[4]=24;header[10]=64;header[17]=8;header[20]=1
        XCTAssertEqual(try NativeGameFile.console(header:header,ext:"cso",preferred:.ps2),.ps2)
        XCTAssertEqual(try NativeGameFile.console(header:header,ext:"cso",preferred:nil),.psp)
        XCTAssertEqual(try NativeGameFile.console(header:header,ext:"cso",preferred:.psp),.psp)
        XCTAssertNoThrow(try NativeGameFile.validate(header:header,size:1_000_000,ext:"cso",console:.ps2))
        var zeroHeader=header;zeroHeader[4]=0
        XCTAssertNoThrow(try NativeGameFile.validate(header:zeroHeader,size:1_000_000,ext:"cso",console:.ps2))
        for offset in [4,20,21] {
            var bad=header;bad[offset]=32
            XCTAssertThrowsError(try NativeGameFile.validate(header:bad,size:1_000_000,ext:"cso",console:.ps2))
        }
        var overflow=header;overflow.replaceSubrange(8..<16,with:Data(repeating:255,count:8))
        XCTAssertThrowsError(try NativeGameFile.validate(header:overflow,size:1_000_000,ext:"cso",console:.ps2))
        XCTAssertThrowsError(try NativeGameFile.validate(header:header,size:64,ext:"cso",console:.ps2),"Index must fit the file")
    }
    func test147EnableUserConsoleCatalog()throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VETA_ENABLE_ALL_CONSOLES"] == "147")
        let library=Library(),original=library.games
        for console in GameConsole.chronological {try library.enable(console)}
        XCTAssertEqual(library.consoles,Set(GameConsole.allCases))
        XCTAssertEqual(Library().consoles,Set(GameConsole.allCases))
        XCTAssertEqual(library.games,original,"Enabling consoles must preserve every game")
        let documents=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        for console in GameConsole.allCases {
            var isDirectory:ObjCBool=false
            XCTAssertTrue(FileManager.default.fileExists(atPath:documents.appendingPathComponent(console.name).path,isDirectory:&isDirectory),console.name)
            XCTAssertTrue(isDirectory.boolValue,console.name)
        }
        print("VETA147_CATALOG_ENABLED consoles=\(library.consoles.count) games=\(library.games.count)")
    }
    var temp:URL!
    override func setUpWithError() throws {
        temp=PhysicalFixturePaths.root.appendingPathComponent("TestScratch",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {veta_unload();try? FileManager.default.removeItem(at:temp)}
    private func expectedBackupGames(_ library:Library)->[Game] {
        library.games.map {game in
            var expected=game
            // Backups materialize inherited visuals to preserve appearance
            // when restored onto a device with different console settings.
            expected.videoPresentation=VideoProfileStore(library:library,game:game).resolved()
            return expected
        }
    }
    func fixture(_ name:String="thwaite") throws -> Data {
        try Data(contentsOf:XCTUnwrap(Bundle.main.url(forResource:name,withExtension:"nes",subdirectory:"Content/\(name)")))
    }
    func load(_ name:String="thwaite",region:String="NTSC") throws {
        let url=temp.appendingPathComponent("game.nes");try fixture(name).write(to:url)
        XCTAssertTrue(veta_load(url.path,temp.path,region))
    }
    func state() throws -> Data {
        var data=Data(count:veta_state_size())
        XCTAssertTrue(data.withUnsafeMutableBytes {veta_save_state($0.baseAddress,$0.count)})
        return data
    }
    func restore(_ data:Data) {XCTAssertTrue(data.withUnsafeBytes {veta_load_state($0.baseAddress,$0.count)})}
    func frame() -> Data {Data(bytes:veta_video(),count:Int(veta_width()*veta_height()*4))}
    func testRealNESVideoAudioInputAndStateReplay() throws {
        try load()
        for _ in 0..<180 {veta_run()}
        let title=frame()
        XCTAssertGreaterThan(Set(title).count,1, "The boot credits use a monochrome palette")
        XCTAssertEqual(veta_sample_rate(),48000)
        let snapshot=try state()
        veta_set_input(0,8) // Start
        for _ in 0..<3 {veta_run()}
        veta_set_input(0,0)
        for _ in 0..<180 {veta_run()}
        XCTAssertNotEqual(title,frame(),"Start must change the game's actual screen")
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,4, "Gameplay must contain distinct NES colors, not just distinct channel bytes")
        XCTAssertGreaterThan(veta_audio_nonzero(),100)
        restore(snapshot)
        veta_set_input(0,0)
        for _ in 0..<30 {veta_run()}
        let first=frame(),firstState=try state()
        restore(snapshot)
        for _ in 0..<30 {veta_run()}
        XCTAssertEqual(first,frame(),"State replay should produce identical pixels")
        XCTAssertEqual(firstState,try state(),"State replay should restore deterministic CPU/RAM state")
        // At least one simultaneous action reaches the actual libretro input callback.
        let before=try state()
        veta_set_input(0,(1<<7)|(1<<8)|1)
        XCTAssertEqual(veta_input_mask(0),385)
        for _ in 0..<60 {veta_run()}
        let pressed=try state()
        restore(before);veta_set_input(0,0)
        for _ in 0..<60 {veta_run()}
        XCTAssertNotEqual(pressed,try state())
    }
    func testAudioOutputRingAndUnderrunRecovery() throws {
        try load()
        var left=[Float](repeating:1,count:512),right=left
        veta_audio_clear()
        veta_audio_read(&left,&right,512,1)
        XCTAssertEqual(veta_audio_delivered(),0);XCTAssertEqual(veta_audio_underruns(),512)
        XCTAssertTrue(left.allSatisfy{$0 == 0} && right.allSatisfy{$0 == 0})
        for _ in 0..<180 {veta_run()}
        veta_audio_clear();veta_run()
        veta_audio_read(&left,&right,512,0.5)
        XCTAssertEqual(veta_audio_delivered(),512);XCTAssertEqual(veta_audio_underruns(),512)
        XCTAssertTrue((left+right).allSatisfy{abs($0)<=0.5})
        // Reopening a different session must reset its accounting.
        try load();XCTAssertEqual(veta_audio_delivered(),0);XCTAssertEqual(veta_audio_underruns(),0)
    }
    func testSnapshotAudioBudgetDoesNotChaseConcurrentConsumption()throws {
        try load()
        for _ in 0..<180 {veta_run()}
        let target=UInt32(veta_sample_rate()*0.08)
        func arrange() {
            veta_audio_clear();NativeAudio.prefill(minimumDuration:0.08)
            let count=Int(veta_audio_queued()-target)+500
            var left=[Float](repeating:0,count:count),right=left
            veta_audio_read(&left,&right,UInt32(count),1)
            XCTAssertEqual(veta_audio_queued(),target-500)
        }
        func consumeDuringRealCoreFrame() {
            veta_run()
            var left=[Float](repeating:0,count:400),right=left
            veta_audio_read(&left,&right,400,1)
        }
        arrange()
        let live=NativeAudio.refill(runFrame:consumeDuringRealCoreFrame)
        XCTAssertEqual(live.frames,2,"The consumer moving during execution triggers a second frame")
        arrange()
        let dropped=veta_audio_dropped()
        let snapshot=NativeAudio.refill(snapshotBudget:true,runFrame:consumeDuringRealCoreFrame)
        XCTAssertEqual(snapshot.frames,1,"One real core frame covers the deficit observed at callback entry")
        XCTAssertTrue(snapshot.hasAudio)
        XCTAssertEqual(veta_audio_dropped(),dropped)
        arrange()
        var calls=0
        let silent=NativeAudio.refill(snapshotBudget:true,runFrame:{calls+=1})
        XCTAssertEqual(calls,4);XCTAssertFalse(silent.hasAudio)
    }
    func testPALAndSecondGame() throws {
        try load("croom",region:"PAL")
        XCTAssertEqual(veta_fps(),50,accuracy:0.1)
        for _ in 0..<120 {veta_run()}
        XCTAssertGreaterThan(Set(frame()).count,1)
        XCTAssertGreaterThan(veta_audio_count(),48000)
    }
    func testAudioReserveAbsorbsFrameJitter() throws {
        for region in ["NTSC","PAL"] {
            try load(region:region)
            for _ in 0..<180 {veta_run()}
            veta_audio_clear();NativeAudio.prefill()
            let rate=veta_sample_rate(),fps=veta_fps()
            XCTAssertGreaterThanOrEqual(Double(veta_audio_queued()),rate*0.04)
            XCTAssertLessThanOrEqual(Double(veta_audio_queued()),rate*(0.04+1/fps)+2)
            let dropped=veta_audio_dropped()
            // Alternate late/early output blocks while preserving average
            // consumption. An empty startup queue would underrun immediately.
            for step in 0..<120 {
                let before=veta_audio_count();veta_run()
                let generated=Int(veta_audio_count()-before)
                let count=generated+(step%2==0 ? 400:-400)
                XCTAssertGreaterThan(count,0)
                var left=[Float](repeating:0,count:count),right=left
                veta_audio_read(&left,&right,UInt32(count),1)
            }
            XCTAssertEqual(veta_audio_underruns(),0)
            XCTAssertEqual(veta_audio_dropped(),dropped)
            XCTAssertEqual(veta_fps(),fps)
            veta_audio_clear();XCTAssertEqual(veta_audio_queued(),0)
            NativeAudio.prefill();XCTAssertGreaterThan(veta_audio_queued(),0)
        }
    }
    func testAdvancedAudioReserveAbsorbsSchedulingGap() throws {
        for region in ["NTSC","PAL"] {
            try load(region:region)
            for _ in 0..<180 {veta_run()}
            veta_audio_clear();NativeAudio.prefill(minimumDuration:0.08)
            XCTAssertGreaterThanOrEqual(Double(veta_audio_queued()),veta_sample_rate()*0.08)
            let dropped=veta_audio_dropped()
            // Model five output periods consumed together during a main-thread
            // scheduling gap, followed by the corresponding catch-up frames.
            for _ in 0..<24 {
                let before=veta_audio_count();veta_run()
                let count=Int(veta_audio_count()-before)*5
                var left=[Float](repeating:0,count:count),right=left
                veta_audio_read(&left,&right,UInt32(count),1)
                for _ in 0..<4 {veta_run()}
            }
            XCTAssertEqual(veta_audio_underruns(),0)
            XCTAssertEqual(veta_audio_dropped(),dropped)
        }
    }
    func testOutputAudioClockPreservesRateAcrossDisplayJitter() throws {
        for region in ["NTSC","PAL"] {
            try load(region:region)
            for _ in 0..<180 {veta_run()}
            veta_audio_clear();NativeAudio.prefill(minimumDuration:0.08)
            let before=veta_audio_count(),rate=veta_sample_rate(),fps=veta_fps(),queued=Double(veta_audio_queued())
            let dropped=veta_audio_dropped(),missing=veta_audio_underruns()
            var consumed:UInt64=0
            for step in 0..<1200 {
                // Audio keeps playing even when a display callback is late.
                let count=step%70==0 ? 3600:[480,960,480,1440,480,960][step%6]
                var left=[Float](repeating:0,count:count),right=left
                veta_audio_read(&left,&right,UInt32(count),1);consumed+=UInt64(count)
                let refill=NativeAudio.refill()
                XCTAssertLessThanOrEqual(refill.frames,4);XCTAssertTrue(refill.hasAudio)
            }
            XCTAssertEqual(veta_audio_underruns(),missing)
            XCTAssertEqual(veta_audio_dropped(),dropped)
            XCTAssertEqual(Double(veta_audio_count()-before)-Double(consumed),Double(veta_audio_queued())-queued,accuracy:2)
            XCTAssertEqual(Double(veta_audio_count()-before),Double(consumed),accuracy:rate/fps+2)
            XCTAssertEqual(veta_fps(),fps,"The reserve must not change PAL/NTSC speed or pitch")
        }
    }
    func testOutputAudioClockRebuildsReserveAfterLongStall() throws {
        try load()
        for _ in 0..<180 {veta_run()}
        veta_audio_clear();NativeAudio.prefill(minimumDuration:0.08)
        var left=[Float](repeating:0,count:9600),right=left
        veta_audio_read(&left,&right,9600,1) // An unavoidable gap longer than the reserve.
        let missing=veta_audio_underruns(),dropped=veta_audio_dropped()
        XCTAssertGreaterThan(missing,0)
        for step in 0..<120 {
            let refill=NativeAudio.refill()
            XCTAssertLessThanOrEqual(refill.frames,4);XCTAssertTrue(refill.hasAudio)
            if step>0 {XCTAssertGreaterThanOrEqual(Double(veta_audio_queued()),veta_sample_rate()*0.08)}
            veta_audio_read(&left,&right,480,1)
        }
        XCTAssertEqual(veta_audio_underruns(),missing,"A scheduling gap must not leave the reserve permanently depleted")
        XCTAssertEqual(veta_audio_dropped(),dropped)
    }
    func testBatteryMemorySurvivesCoreReload() throws {
        var rom=try fixture();rom[6] |= 2 // Test-only battery flag; original bundled ROM is unchanged.
        let url=temp.appendingPathComponent("battery.nes");try rom.write(to:url)
        XCTAssertTrue(veta_load(url.path,temp.path,"NTSC"))
        let n=veta_ram_size();XCTAssertGreaterThan(n,0)
        guard n>0 else{return}
        let expected=Data((0..<n).map {UInt8($0 % 251)})
        XCTAssertTrue(expected.withUnsafeBytes{veta_write_ram($0.baseAddress,$0.count)})
        var saved=Data(count:n);saved.withUnsafeMutableBytes{veta_read_ram($0.baseAddress,$0.count)}
        XCTAssertEqual(saved,expected)
        veta_unload();XCTAssertTrue(veta_load(url.path,temp.path,"NTSC"))
        XCTAssertTrue(saved.withUnsafeBytes{veta_write_ram($0.baseAddress,$0.count)})
        var actual=Data(count:n);actual.withUnsafeMutableBytes{veta_read_ram($0.baseAddress,$0.count)}
        XCTAssertEqual(actual,expected)
    }
    func testConsoleFoldersPreserveFilesAndImportCopies() throws {
        let documents=temp.appendingPathComponent("Documents",isDirectory:true)
        let folder=try GameFiles.prepareFolder(in:documents)
        XCTAssertEqual(folder,documents)
        let expected=Set(["NES"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:folder.path)),expected)
        let source=folder.appendingPathComponent("NES/Thwaite.nes")
        let rom=try fixture();try rom.write(to:source)
        let personal=folder.appendingPathComponent("NES/Mis favoritos",isDirectory:true)
        try FileManager.default.createDirectory(at:personal,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("SNES"),withIntermediateDirectories:true)
        XCTAssertEqual(try GameFiles.prepareFolder(in:documents),folder)
        XCTAssertEqual(try Data(contentsOf:source),rom)
        XCTAssertTrue(FileManager.default.fileExists(atPath:personal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent("SNES").path))
        let library=Library(root:temp.appendingPathComponent("library"))
        try library.importURL(source);try library.importURL(source)
        XCTAssertEqual(library.games.count,1)
        try FileManager.default.removeItem(at:source)
        XCTAssertEqual(try Data(contentsOf:library.romURL(XCTUnwrap(library.games.first))),rom)
    }
    func testConsoleFolderNameConflictPreservesExistingFile() throws {
        for name in ["NES"] {
            let documents=temp.appendingPathComponent(UUID().uuidString,isDirectory:true)
            let file=documents.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            let original=Data("Do not overwrite".utf8);try original.write(to:file)
            XCTAssertThrowsError(try GameFiles.prepareFolder(in:documents))
            XCTAssertEqual(try Data(contentsOf:file),original)
        }
    }
    func testLibraryDedupBackupAndFreshReopen() throws {
        let library=Library(root:temp.appendingPathComponent("library"))
        let game=try library.add(data:fixture(),name:"Thwaite")
        _=try library.add(data:fixture(),name:"Duplicate")
        XCTAssertEqual(library.games.count,1)
        var favorite=game;favorite.favorite=true;favorite.lastPlayed=Date();library.update(favorite)
        try load();for _ in 0..<60 {veta_run()}
        let data=try state(),encoded=try StateFile.encode(data,rom:game.id)
        try encoded.write(to:library.file(game,"quick.vstate"),options:.atomic)
        XCTAssertEqual(try StateFile.decode(Data(contentsOf:library.file(game,"quick.vstate")),rom:game.id),data)
        let backup=try library.export()
        let restored=Library(root:temp.appendingPathComponent("restored"))
        try restored.importURL(backup)
        XCTAssertEqual(restored.games.count,1)
        XCTAssertTrue(restored.games[0].favorite)
        XCTAssertEqual(try Data(contentsOf:restored.romURL(game)),try fixture())
        XCTAssertEqual(try Data(contentsOf:restored.file(game,"quick.vstate")),encoded)
        let reopened=Library(root:restored.root)
        XCTAssertEqual(reopened.games,restored.games)
        try restored.importURL(backup);XCTAssertEqual(restored.games.count,1)
        XCTAssertThrowsError(try StateFile.decode(encoded,rom:"another-rom"))
        XCTAssertThrowsError(try Library.validateROM(Data([1,2,3])))
        var truncated=try fixture();truncated=Data(truncated.prefix(24));XCTAssertThrowsError(try Library.validateROM(truncated))
    }
    func testSustainedCoreFrames() throws {
        try load()
        let start=CFAbsoluteTimeGetCurrent()
        for _ in 0..<3600 {veta_run()}
        let elapsed=CFAbsoluteTimeGetCurrent()-start
        XCTAssertEqual(veta_frame_count(),3600)
        XCTAssertLessThan(elapsed,60,"Core alone must sustain realtime on test hardware")
        print("VETA_NATIVE_CORE_3600_FRAMES_SECONDS=\(elapsed)")
    }
    func testControlGeometryAcrossSizesAndProfiles() {
        for (w,h,landscape) in [(320.0,260.0,false),(375,340,false),(402,400,false),(430,460,false),(640,200,true),(728,270,true),(874,340,true),(1024,500,true)] {
            for size in [0.85,1.0,1.2] { for height in [-0.12,0,0.12] { for spacing in [0.8,1.0,1.2] {
                let deck=TouchDeck(frame:CGRect(x:0,y:0,width:w,height:h))
                deck.landscape=landscape
                var style=ControlStyle();style.size=size;style.height=height;style.spacing=spacing;deck.style=style
                deck.layoutIfNeeded()
                for (name,rect) in deck.zones {
                    XCTAssertTrue(deck.bounds.contains(rect), "Outside: \(w)x\(h) \(size) \(height) \(name): \(rect)")
                    XCTAssertGreaterThanOrEqual(rect.width,44);XCTAssertGreaterThanOrEqual(rect.height,44)
                    for (other,otherRect) in deck.zones where name < other {
                        XCTAssertFalse(rect.intersects(otherRect),"Overlap \(name)/\(other) at \(w)x\(h), \(size), \(height)")
                    }
                }
            }}}
        }
    }
    func testConsoleLayoutKeepsAllControlsOutsidePicture() {
        for safe in [CGRect(x:0,y:20,width:320,height:548),CGRect(x:0,y:62,width:402,height:778),CGRect(x:62,y:0,width:750,height:381),CGRect(x:0,y:24,width:1024,height:1322),CGRect(x:0,y:24,width:1366,height:980)] {
            let layout=ConsoleLayout(safe:safe)
            XCTAssertTrue(safe.contains(layout.screen))
            if safe.width <= safe.height {
                XCTAssertEqual(layout.screen.minX,safe.minX)
                XCTAssertEqual(layout.screen.width,safe.width,"Portrait gameplay must fill the available width")
                XCTAssertLessThanOrEqual(layout.deck.height,layout.screen.height,"The controller must not be taller than the game")
                XCTAssertEqual(layout.deck.maxY,safe.maxY,accuracy:0.001)
                XCTAssertEqual(layout.toolbar.maxY,layout.deck.minY,accuracy:0.001)
                XCTAssertLessThanOrEqual(layout.screen.maxY,layout.toolbar.minY)
            }
            XCTAssertEqual(layout.screen.width/layout.screen.height,4/3,accuracy:0.001)
            for size in [0.85,1.2] {for height in [-0.12,0.12] {for spacing in [0.8,1.2] {
                let deck=TouchDeck(frame:layout.deck);deck.landscape=safe.width>safe.height
                var style=ControlStyle();style.size=size;style.height=height;style.spacing=spacing;deck.style=style;deck.layoutIfNeeded()
                for (name,zone) in deck.zones {
                    XCTAssertTrue(deck.bounds.contains(zone),name)
                    XCTAssertFalse(zone.offsetBy(dx:layout.deck.minX,dy:layout.deck.minY).intersects(layout.screen),name)
                }
            }}}
        }
    }
    func handheld(_ name:String,console:GameConsole)throws {
        let url=try XCTUnwrap(Bundle.main.url(forResource:name,withExtension:console.romExtension,subdirectory:"Content/\(name)"))
        try exerciseCore(url,console:console)
    }
    func exerciseCore(_ url:URL,console:GameConsole)throws {
        let bytes=try Data(contentsOf:url);try Library.validateROM(bytes,console:console)
        XCTAssertTrue(veta_load_console(url.path,temp.path,"Auto",console.coreIndex))
        for _ in 0..<240 {veta_run()}
        let boot=frame()
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2)
        for mask:UInt16 in [8,0,256,0] {veta_set_input(0,mask);for _ in 0..<120 {veta_run()}}
        XCTAssertNotEqual(boot,frame(),"The game must advance past its title")
        XCTAssertGreaterThan(veta_audio_count(),10000)
        XCTAssertGreaterThan(veta_audio_nonzero(),1000)
        if console == .gb || console == .gbc {XCTAssertEqual(veta_width(),160);XCTAssertEqual(veta_height(),144)}
        print("VETA_CORE_\(console.rawValue): \(veta_width())x\(veta_height()) audio=\(veta_audio_count()) nonzero=\(veta_audio_nonzero())")
        let saved=try state()
        veta_set_input(0,0);for _ in 0..<60 {veta_run()};let neutral=frame()
        restore(saved);for _ in 0..<60 {veta_run()};XCTAssertEqual(neutral,frame(),"Saved state must replay identical pixels")
        restore(saved);veta_set_input(0,128|256);for _ in 0..<60 {veta_run()}
        XCTAssertNotEqual(neutral,frame(),"Game must react to real controller input")
        let encoded=try StateFile.encode(saved,rom:sha256(bytes),core:console.coreID)
        XCTAssertEqual(try StateFile.decode(encoded,rom:sha256(bytes),core:console.coreID),saved)
        XCTAssertThrowsError(try StateFile.decode(encoded,rom:sha256(bytes),core:"wrong-core"))
        veta_unload();XCTAssertTrue(veta_load_console(url.path,temp.path,"Auto",console.coreIndex))
        restore(saved);veta_set_input(0,0);for _ in 0..<60 {veta_run()};XCTAssertEqual(neutral,frame(),"State must survive unloading/reopening")
    }
    func testAdditionalCoreBoots()throws {
        let docs=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures")
        for (name,index) in [("flappy.nds",UInt32(11)),("nortis.cue",UInt32(10)),("240p.pce",UInt32(9))] {
            let url=docs.appendingPathComponent(name)
            try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"Author-provided local fixture required")
            XCTAssertTrue(veta_load_console(url.path,docs.path,"Auto",index),name)
            let start=Date()
            for _ in 0..<360 {veta_run()}
            let title=frame()
            veta_set_pointer(0,16384,true);veta_set_input(0,8);for _ in 0..<3{veta_run()}
            veta_set_pointer(0,0,false);veta_set_input(0,0);for _ in 0..<120{veta_run()}
            veta_set_input(0,256);for _ in 0..<3{veta_run()};veta_set_input(0,0);for _ in 0..<120{veta_run()}
            print("VETA_INPUT_\(name): changed=\(title != frame())")
            print("VETA_BOOT_\(name): \(veta_width())x\(veta_height()) audio=\(veta_audio_count()) nonzero=\(veta_audio_nonzero()) seconds=\(Date().timeIntervalSince(start)) state=\(veta_state_size())")
            XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2,name)
            XCTAssertGreaterThan(veta_audio_count(),10000,name)
            let saved=try state();for _ in 0..<20 {veta_run()};let expected=frame()
            restore(saved);for _ in 0..<20 {veta_run()};XCTAssertEqual(expected,frame(),name)
            veta_unload()
        }
    }
    func testN64GameAndSaves()throws {try verifyNativeConsole("castle.n64",index:12)}
    func testPSPLibraryLifecycle()throws {try verifyNativeConsole("sudoku-psp.pbp",index:14)}
    func testAdvancedImportValidatesAndStreamsLargeDiscs()throws {
        let library=Library(root:temp.appendingPathComponent("large")),url=temp.appendingPathComponent("large.iso")
        FileManager.default.createFile(atPath:url.path,contents:nil)
        let f=try FileHandle(forWritingTo:url);try f.truncate(atOffset:300*1024*1024)
        try f.seek(toOffset:32769);try f.write(contentsOf:Data("CD001".utf8));try f.close()
        let game=try library.importNativeFile(url,console:.ps2)
        XCTAssertEqual(try library.romURL(game).resourceValues(forKeys:[.fileSizeKey]).fileSize,300*1024*1024)
        XCTAssertEqual(try library.importNativeFile(url,console:.ps2).id,game.id)
        XCTAssertThrowsError(try library.export(),"Oversize backups must fail before allocating a whole disc")
        let bad=temp.appendingPathComponent("bad.elf");try Data(repeating:0,count:1024).write(to:bad)
        XCTAssertThrowsError(try library.importNativeFile(bad,console:.ps2))
        XCTAssertEqual(library.games.count,1)
        XCTAssertThrowsError(try NativeGameFile.console(header:Data(),ext:"iso",preferred:nil))
        XCTAssertThrowsError(try NativeGameFile.validate(header:Data("3DSX".utf8),size:8,ext:"3dsx",console:.threeDS))
        var dol=Data(repeating:0,count:260);dol[2]=1;dol[0x93]=4
        let executable=temp.appendingPathComponent("unaligned.dol");try dol.write(to:executable)
        let imported=try library.importNativeFile(executable,console:.gamecube)
        let normalized=try Data(contentsOf:library.romURL(imported))
        XCTAssertEqual(normalized.count,288);XCTAssertEqual(normalized.prefix(260),dol)
        XCTAssertEqual(try Data(contentsOf:executable),dol)
        XCTAssertEqual(try library.importNativeFile(executable,console:.gamecube).id,imported.id)
        XCTAssertEqual(Set(GameConsole.allCases.map(\.coreIndex)).count,GameConsole.allCases.count)
        XCTAssertFalse(GameConsole.allCases.contains{$0.coreID=="unavailable"})
    }
    func testCompressedStatesAndCoreMemoryValidation()throws {
        let large=Data(repeating:0x35,count:75_497_472),encoded=try StateFile.encode(large,rom:"psp-size",core:"fixture")
        XCTAssertLessThan(encoded.count,large.count/20)
        XCTAssertEqual(try StateFile.decode(encoded,rom:"psp-size",core:"fixture"),large)
        let legacy=StateFile(version:1,core:StateFile.coreID,rom:"legacy",digest:sha256(Data([1,2,3])),bytes:Data([1,2,3]))
        XCTAssertEqual(try StateFile.decode(JSONEncoder().encode(legacy),rom:"legacy"),Data([1,2,3]))
        var broken=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        broken["uncompressedSize"]=StateFile.maximumSize+1
        XCTAssertThrowsError(try StateFile.decode(JSONSerialization.data(withJSONObject:broken),rom:"psp-size",core:"fixture"))
        broken["uncompressedSize"]=large.count;broken["digest"]="invalid"
        XCTAssertThrowsError(try StateFile.decode(JSONSerialization.data(withJSONObject:broken),rom:"psp-size",core:"fixture"))
        for files in [["../bad":Data()], ["a":Data(),"a/b":Data()], ["a":Data(),"A":Data()]] {XCTAssertThrowsError(try Library.validateCoreSaves(files))}
        try Library.validateCoreSaves(["nested/valid.sav":Data([1])])
        XCTAssertEqual(GameConsole.saturn.buttonMask("A"),1)
        XCTAssertEqual(GameConsole.saturn.buttonMask("C"),1<<11)
        XCTAssertEqual(GameConsole.saturn.buttonMask("Z"),1<<10)
        XCTAssertEqual(GameConsole.saturn.buttonMask("SELECT"),0)
    }
    func testSaturnMissingAndInvalidBIOS()throws {
        let library=Library(root:temp.appendingPathComponent("bios-test")),docs=temp.appendingPathComponent("Docs")
        XCTAssertThrowsError(try library.prepareSystem(for:.saturn,documents:docs))
        let bios=docs.appendingPathComponent("Saturn/BIOS/mpr-17933.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath:bios.deletingLastPathComponent().path))
        try Data(repeating:0,count:524288).write(to:bios)
        XCTAssertThrowsError(try library.prepareSystem(for:.saturn,documents:docs))
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.root.appendingPathComponent("System/mpr-17933.bin").path))
    }
    func testWaveTrackConversionAndValidation()throws {
        var wav=Data("RIFF".utf8)
        func append(_ value:UInt32,to data:inout Data){var n=value.littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}}
        append(44,to:&wav);wav.append(Data("WAVEfmt ".utf8));append(16,to:&wav)
        wav.append(contentsOf:[1,0,2,0]);append(44100,to:&wav);append(176400,to:&wav)
        wav.append(contentsOf:[4,0,16,0]);wav.append(Data("data".utf8));append(8,to:&wav)
        let samples=Data([1,2,3,4,5,6,7,8]);wav.append(samples)
        let source=temp.appendingPathComponent("audio.wav"),output=temp.appendingPathComponent("audio.bin")
        try wav.write(to:source);try DiscFiles.waveToBinary(source,destination:output)
        let raw=try Data(contentsOf:output);XCTAssertEqual(raw.count,2352);XCTAssertEqual(raw.prefix(8),samples)
        wav[22]=1;try wav.write(to:source);XCTAssertThrowsError(try DiscFiles.waveToBinary(source,destination:temp.appendingPathComponent("bad.bin")))
        for filename in ["../x.bin","quick.vstate","CoreSaves","disc.cue"] {XCTAssertThrowsError(try DiscFiles.names(in:Data("FILE \"\(filename)\" BINARY\n".utf8)))}
    }
    func testDiscImportAndBackup()throws {
        let library=Library(root:temp.appendingPathComponent("library")),source=temp.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let cue=source.appendingPathComponent("Demo.cue"),track=source.appendingPathComponent("track.bin")
        try Data("FILE \"track.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".utf8).write(to:cue)
        try Data(repeating:0x33,count:2352*20).write(to:track)
        try library.importURLs([cue,track],console:.ps1)
        XCTAssertEqual(library.games.count,1)
        let game=try XCTUnwrap(library.games.first)
        XCTAssertEqual(game.contentName,"disc.cue")
        XCTAssertEqual(try Data(contentsOf:library.file(game,"track.bin")),try Data(contentsOf:track))
        try library.importURLs([cue,track],console:.ps1);XCTAssertEqual(library.games.count,1)
        let backup=try library.export();defer{try? FileManager.default.removeItem(at:backup)}
        let restored=Library(root:temp.appendingPathComponent("restored"));try restored.importURL(backup)
        XCTAssertEqual(restored.games.first?.id,game.id)
        XCTAssertEqual(try Data(contentsOf:restored.file(game,"track.bin")),try Data(contentsOf:track))
        for path in ["../track.bin","/track.bin","..\\track.bin"] {XCTAssertThrowsError(try DiscFiles.names(in:Data("FILE \"\(path)\" BINARY\n".utf8)))}
        XCTAssertEqual(GameConsole.nes.coreIndex,0)
    }
    func testSaturnBIOSAndHomebrew()throws {
        let docs=PhysicalFixturePaths.root
        let url=docs.appendingPathComponent("EngineFixtures/Saturn/game.cue")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"Local author-provided Saturn fixture required")
        let library=Library(root:temp.appendingPathComponent("saturn"))
        try library.importURLs([url],console:nil)
        let game=try XCTUnwrap(library.games.first)
        XCTAssertEqual(game.console,.saturn)
        let normalized=try Data(contentsOf:library.romURL(game))
        XCTAssertFalse(String(decoding:normalized,as:UTF8.self).contains(" WAVE"))
        let system=try library.prepareSystem(for:.saturn,documents:PhysicalFixturePaths.root),saves=try library.prepareCoreSaves(for:game)
        XCTAssertTrue(veta_load_system(library.romURL(game).path,saves.path,system.path,"Auto",game.console.coreIndex))
        let start=Date()
        for _ in 0..<1800 {veta_run()}
        print("VETA_SATURN: \(veta_width())x\(veta_height()) audio=\(veta_audio_count()) nonzero=\(veta_audio_nonzero()) seconds=\(Date().timeIntervalSince(start)) state=\(veta_state_size())")
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2)
        XCTAssertGreaterThan(veta_audio_nonzero(),100)
        let raw=frame(),provider=CGDataProvider(data:raw as CFData)!
        let image=CGImage(width:Int(veta_width()),height:Int(veta_height()),bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:Int(veta_width())*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue)],provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        try UIImage(cgImage:image).pngData()!.write(to:docs.appendingPathComponent("EngineFixtures/Saturn/boot.png"))
        let saved=try state(),encoded=try StateFile.encode(saved,rom:game.id,core:game.console.coreID)
        XCTAssertEqual(try StateFile.decode(encoded,rom:game.id,core:game.console.coreID),saved)
        try encoded.write(to:library.file(game,"quick.vstate"))
        for _ in 0..<30 {veta_run()};let expected=frame()
        restore(saved);for _ in 0..<30 {veta_run()};XCTAssertEqual(expected,frame())
        restore(saved);veta_set_input(0,8);for _ in 0..<3 {veta_run()};veta_set_input(0,0)
        for _ in 0..<27 {veta_run()};XCTAssertNotEqual(expected,frame(),"Start should change the homebrew screen")
        let ramCount=veta_ram_size();XCTAssertEqual(ramCount,32768)
        var ram=Data(count:ramCount);ram.withUnsafeMutableBytes{veta_read_ram($0.baseAddress,$0.count)}
        try ram.write(to:library.file(game,"battery.sav"))
        veta_unload()
        let memories=try library.coreSaveFiles(game);XCTAssertFalse(memories?.isEmpty ?? true,"Saturn clock/cart files should be persisted by the core")
        let backup=try library.export();defer{try? FileManager.default.removeItem(at:backup)}
        let restored=Library(root:temp.appendingPathComponent("restored-saturn"));try restored.importURL(backup)
        XCTAssertEqual(try restored.coreSaveFiles(game),memories)
        XCTAssertEqual(try Data(contentsOf:restored.file(game,"battery.sav")),ram)
        let restoredSystem=try restored.prepareSystem(for:.saturn,documents:PhysicalFixturePaths.root),restoredSaves=try restored.prepareCoreSaves(for:game)
        XCTAssertTrue(veta_load_system(restored.romURL(game).path,restoredSaves.path,restoredSystem.path,"Auto",13))
        XCTAssertTrue(ram.withUnsafeBytes{veta_write_ram($0.baseAddress,$0.count)})
        restore(try StateFile.decode(Data(contentsOf:restored.file(game,"quick.vstate")),rom:game.id,core:game.console.coreID))
        for _ in 0..<30 {veta_run()};XCTAssertEqual(expected,frame())
        veta_unload()
        #if targetEnvironment(simulator)
        let uiLibrary=Library();try uiLibrary.enable(.saturn)
        try uiLibrary.importURLs([url],console:.saturn)
        var uiGame=try XCTUnwrap(uiLibrary.games.first(where:{$0.id==game.id}));uiGame.name="Coup · Saturn";uiLibrary.update(uiGame)
        try encoded.write(to:uiLibrary.file(uiGame,"auto.vstate"))
        #endif
    }
    func testPBPConsoleUsesPayloadBeyondHeader()throws {
        var header=Data(repeating:0,count:40);header.replaceSubrange(0..<4,with:Data("\0PBP".utf8))
        for offset in stride(from:8,through:32,by:4) {header[offset]=40}
        header[38]=1 // DATA.PSAR at 65536, after the usual header read.
        var reads=0
        XCTAssertEqual(try NativeGameFile.pbpConsole(header:header,size:70000) {offset,count in
            XCTAssertEqual(offset,65536);XCTAssertEqual(count,11);reads+=1;return Data("PSISOIMG00\0\0".utf8)
        },.ps1)
        XCTAssertEqual(reads,1)
        XCTAssertEqual(try NativeGameFile.pbpConsole(header:header,size:70000){_,_ in Data("PSTITLEIMG\0\0".utf8)},.ps1)
        XCTAssertEqual(try NativeGameFile.pbpConsole(header:header,size:70000){_,_ in Data("PSP archive".utf8)},.psp)
        XCTAssertThrowsError(try NativeGameFile.pbpConsole(header:header,size:100){_,_ in XCTFail("Invalid bounds must fail before reading");return Data()})
    }
    func testAtariDPCSizeAcceptedWithoutAcceptingArbitraryTruncation()throws {
        for size in [10240,10496] {XCTAssertNoThrow(try Library.validateROM(Data(repeating:0,count:size),console:.atari2600))}
        for size in [2047,8193,10497] {XCTAssertThrowsError(try Library.validateROM(Data(repeating:0,count:size),console:.atari2600))}
    }
    func testCSOVersionOneAllowsOmittedHeaderSize()throws {
        var h=Data(repeating:0,count:32);h.replaceSubrange(0..<4,with:Data("CISO".utf8));h[17]=8;h[20]=1
        XCTAssertNoThrow(try NativeGameFile.validate(header:h,size:4096,ext:"cso",console:.psp))
        h[20]=2;XCTAssertThrowsError(try NativeGameFile.validate(header:h,size:4096,ext:"cso",console:.psp))
        h[20]=1;h[4]=24;XCTAssertNoThrow(try NativeGameFile.validate(header:h,size:4096,ext:"cso",console:.psp))
        h[17]=7;XCTAssertThrowsError(try NativeGameFile.validate(header:h,size:4096,ext:"cso",console:.psp))
    }
    func testPBPDoesNotMoveExistingPlayStationMemoryCards()throws {
        let library=Library(root:temp.appendingPathComponent("ps1-save-layout"))
        var game=Game(id:String(repeating:"a",count:64),name:"Existing PS1",console:.ps1)
        try FileManager.default.createDirectory(at:library.directory(game.id),withIntermediateDirectories:true)
        let card=library.file(game,"memory.mcr"),bytes=Data([1,2,3,4]);try bytes.write(to:card)
        for content in ["game.exe","disc.cue","game.pbp"] {
            game.contentName=content
            XCTAssertEqual(try library.prepareCoreSaves(for:game),library.directory(game.id))
            XCTAssertEqual(try Data(contentsOf:card),bytes)
            XCTAssertEqual(NativeGameFile.isStreamedContent(game),content=="game.pbp")
        }
    }
    func verifyNativeConsole(_ filename:String,index:UInt32)throws {
        let fixtures=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures")
        let url=fixtures.appendingPathComponent(filename),console=try XCTUnwrap(GameConsole.allCases.first{$0.coreIndex==index})
        try XCTSkipUnless(console.playable,"This engine requires the simulator or a JIT-capable installation")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"Local author-provided fixture required: "+filename)
        let library=Library(root:temp.appendingPathComponent("library"))
        let game=try library.importNativeFile(url,console:console)
        XCTAssertEqual(try library.importNativeFile(url,console:console).id,game.id)
        XCTAssertEqual(library.games.count,1)
        let save=try library.prepareCoreSaves(for:game),system=try library.prepareSystem(for:console,documents:PhysicalFixturePaths.root)
        if index==18 {
            try FileManager.default.createDirectory(at:save.appendingPathComponent("User/Load"),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:fixtures.appendingPathComponent("xump-wii-sd.raw"),to:save.appendingPathComponent("User/Load/WiiSD.raw"))
        }
        XCTAssertTrue(veta_load_system(library.romURL(game).path,save.path,system.path,"Auto",index))
        var fpuBefore=fenv_t();fegetenv(&fpuBefore)
        let start=Date(),count=[16,18,19].contains(index) ? 1800:600
        for _ in 0..<count {veta_run()}
        var fpuAfter=fenv_t();fegetenv(&fpuAfter);XCTAssertEqual(fpuBefore.__fpcr,fpuAfter.__fpcr,"Guest floating-point modes must not escape into UIKit")
        print("ENGINE \(index): size=\(veta_width())x\(veta_height()) colors=\(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count) audio=\(veta_audio_nonzero()) time=\(Date().timeIntervalSince(start)) state=\(veta_state_size())")
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2)
        if index != 17 && index != 14 && index != 12 && filename != "3dstris.3dsx" {XCTAssertGreaterThan(veta_audio_nonzero(),1000)}
        if filename=="GTS_GC.dol" {
            // GTS opens a menu that ignores horizontal sticks; enter Controller Test first.
            veta_set_input(0,256);for _ in 0..<5 {veta_run()};veta_set_input(0,0)
            for _ in 0..<60 {veta_run()}
        }
        let before=try state()
        for _ in 0..<60 {veta_run()};let idle=frame();restore(before)
        if filename=="GTS_GC.dol" {
            veta_set_analog(0,0,32767,0);for _ in 0..<60 {veta_run()};veta_set_analog(0,0,0,0)
            XCTAssertNotEqual(idle,frame(),"Analog input must move the emulated controller axis")
            restore(before)
        }
        let press:UInt16=index==17 || index==16 ? 256:index==18 ? 4:index==15 ? 8:1
        if filename=="3dstris.3dsx" {
            veta_set_pointer(0,5000,true);for _ in 0..<5 {veta_run()};veta_set_pointer(0,5000,false)
            for _ in 0..<55 {veta_run()}
        } else {veta_set_input(0,press);for _ in 0..<60 {veta_run()};veta_set_input(0,0)}
        if filename != "cubevfpu.prx" {XCTAssertNotEqual(idle,frame(),"Input must change the emulated game, compared at the same frame")}
        if filename=="3dstris.3dsx" {
            // Select Normal on the bottom touchscreen, then move a falling piece.
            veta_set_pointer(-13107,16383,true);for _ in 0..<5 {veta_run()};veta_set_pointer(-13107,16383,false)
            for _ in 0..<120 {veta_run()}
            let playing=try state();for _ in 0..<15 {veta_run()};let still=frame();restore(playing)
            veta_set_input(0,128);for _ in 0..<15 {veta_run()};veta_set_input(0,0)
            XCTAssertNotEqual(still,frame(),"D-pad must move a falling 3DStris piece")
        }
        if filename=="sudoku-gc.dol" || filename=="sudoku-psp.pbp" {
            for _ in 0..<3 {veta_set_input(0,index==17 ? 256:1);for _ in 0..<5 {veta_run()};veta_set_input(0,0);for _ in 0..<90 {veta_run()}}
            for _ in 0..<300 {veta_run()}
            print("SUDOKU_GAME_AUDIO \(veta_audio_nonzero())")
            XCTAssertGreaterThan(veta_audio_nonzero(),1000)
        }
        if [16,18,19].contains(index) && filename != "3dstris.3dsx" {
            // Xump's "go!" card waits for another confirmation before gameplay.
            for _ in 0..<60 {veta_run()}
            veta_set_input(0,press);for _ in 0..<5 {veta_run()};veta_set_input(0,0)
            for _ in 0..<180 {veta_run()}
        }
        if filename=="sudoku-gc.dol" || filename=="xump-wii.dol" || filename=="xump-ps2.iso" {
            let beforeAudio=veta_audio_count()
            for _ in 0..<120 {veta_run()}
            let expected=120/veta_fps()*veta_sample_rate()
            let actual=Double(veta_audio_count()-beforeAudio)
            print("CORE_TIMING console=\(index) fps=\(veta_fps()) sampleRate=\(veta_sample_rate()) expectedAudio=\(expected) actualAudio=\(actual)")
            XCTAssertEqual(actual,expected,accuracy:expected*0.03,"Reported timing must match generated audio, including the initial 50→60 Hz settle")
        }
        let provider=CGDataProvider(data:frame() as CFData)!
        if let cg=CGImage(width:Int(veta_width()),height:Int(veta_height()),bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:Int(veta_width())*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) {try UIImage(cgImage:cg).pngData()?.write(to:fixtures.appendingPathComponent("engine-\(index).png"))}
        if index==12 {for _ in 0..<600 {veta_run()};print("N64 GAME AUDIO \(veta_audio_nonzero())");XCTAssertGreaterThan(veta_audio_nonzero(),1000)}
        let snapshot=try state(),encoded=try StateFile.encode(snapshot,rom:game.id,core:console.coreID)
        try encoded.write(to:library.file(game,"quick.vstate"));veta_unload()
        let exported=try library.export(),restored=Library(root:temp.appendingPathComponent("restored"))
        try restored.importURL(exported);try? FileManager.default.removeItem(at:exported)
        XCTAssertEqual(restored.games,expectedBackupGames(library))
        XCTAssertEqual(try restored.coreSaveFiles(game),try library.coreSaveFiles(game))
        let restoredSystem=try restored.prepareSystem(for:console,documents:PhysicalFixturePaths.root),restoredSave=try restored.prepareCoreSaves(for:game)
        XCTAssertTrue(veta_load_system(restored.romURL(game).path,restoredSave.path,restoredSystem.path,"Auto",index))
        for _ in 0..<2 {veta_run()}
        restore(try StateFile.decode(Data(contentsOf:restored.file(game,"quick.vstate")),rom:game.id,core:console.coreID))
        for _ in 0..<30 {veta_run()}
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2)
        veta_unload()
        #if targetEnvironment(simulator)
        if filename=="GTS_GC.dol" || filename=="xump-3ds.3dsx" {return} // Keep the game fixtures separate from diagnostics/known compatibility cases.
        let ui=Library();try ui.enable(console)
        var installed=try ui.importNativeFile(url,console:console)
        for var old in ui.games where old.name=="Prueba "+console.shortName && old.id != installed.id {old.name="Prueba anterior "+console.shortName;ui.update(old)}
        installed.name="Prueba "+console.shortName;ui.update(installed)
        if let files=try library.coreSaveFiles(game) {try ui.restoreCoreSaves(files,for:installed)}
        try encoded.write(to:ui.file(installed,"auto.vstate"))
        #endif
    }
    func testGameCubeBoot()throws {try verifyNativeConsole("GTS_GC.dol",index:17)}
    func testGameCubeGame()throws {try verifyNativeConsole("sudoku-gc.dol",index:17)}
    func testWiiBoot()throws {try verifyNativeConsole("xump-wii.dol",index:18)}
    func testDreamcastBoot()throws {try verifyNativeConsole("demon-bazooka.elf",index:15)}
    func testDreamcastAudioClockAcrossStateRestore()throws {
        let url=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/demon-bazooka.elf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"Local authorized Dreamcast fixture required")
        let library=Library(root:temp.appendingPathComponent("library")),game=try library.importNativeFile(url,console:.dreamcast)
        let save=try library.prepareCoreSaves(for:game),system=try library.prepareSystem(for:.dreamcast,documents:PhysicalFixturePaths.root)
        XCTAssertTrue(veta_load_system(library.romURL(game).path,save.path,system.path,"Auto",15))
        for _ in 0..<600 {veta_run()}
        veta_set_input(0,8);for _ in 0..<5 {veta_run()};veta_set_input(0,0)
        for _ in 0..<120 {veta_run()}
        let checkpoint=try state()
        var left=[Float](repeating:0,count:735),right=left
        for round in 0..<2 {
            restore(checkpoint);veta_audio_clear();NativeAudio.prefill()
            let dropped=veta_audio_dropped(),missing=veta_audio_underruns(),before=veta_audio_count()
            let reserve=Double(veta_audio_queued())
            var budget=0.0,peakQueue:UInt32=0,largestBatch=0.0
            for tick in 0..<2700 { // 45 seconds at a simulated 60 Hz display/audio clock.
                budget+=1.0/60
                veta_set_analog(0,0,(tick/90)%2==0 ? 26000:-26000,0)
                veta_set_input(0,tick%90<18 ? 1:0)
                var runs=0
                while budget>=1/veta_fps(),runs<4 {
                    let duration=Emulation.runFrame(console:.dreamcast)
                    largestBatch=max(largestBatch,duration*44100);budget-=duration;runs+=1
                }
                if runs==4 {budget=min(budget,1/veta_fps())}
                peakQueue=max(peakQueue,veta_audio_queued())
                veta_audio_read(&left,&right,735,1)
            }
            let speed=Double(veta_audio_count()-before)/(45*44100)
            print("DREAMCAST_AUDIO_CLOCK round=\(round) speed=\(speed) peakQueue=\(peakQueue) largestBatch=\(largestBatch) reserve=\(reserve) missing=\(veta_audio_underruns()-missing) dropped=\(veta_audio_dropped()-dropped)")
            XCTAssertEqual(speed,1,accuracy:0.005)
            XCTAssertEqual(veta_audio_dropped(),dropped)
            XCTAssertEqual(veta_audio_underruns(),missing)
            XCTAssertLessThanOrEqual(Double(peakQueue),reserve+largestBatch+735,"The queue must not grow beyond its reserve plus one core batch/display tick")
        }
    }
    func testThreeDSBoot()throws {try verifyNativeConsole("xump-3ds.3dsx",index:16)}
    func testThreeDSGame()throws {try verifyNativeConsole("3dstris.3dsx",index:16)}
    func testPS2Boot()throws {try verifyNativeConsole("xump-ps2.iso",index:19)}
    func testPS2AudioAcrossPauseAndRestore()throws {
        executionTimeAllowance=180
        let url=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/xump-ps2.iso")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"Local authorized PS2 fixture required")
        let library=Library(root:temp.appendingPathComponent("library")),game=try library.importNativeFile(url,console:.ps2)
        let save=try library.prepareCoreSaves(for:game),system=try library.prepareSystem(for:.ps2,documents:PhysicalFixturePaths.root)
        XCTAssertTrue(veta_load_system(library.romURL(game).path,save.path,system.path,"Auto",19))
        for _ in 0..<1800 {veta_run()}
        let checkpoint=try state()
        var left=[Float](repeating:0,count:735),right=left
        for round in 0..<4 {
            restore(checkpoint)
            Thread.sleep(forTimeInterval:0.25) // Producer can finish its in-flight work while UI is paused.
            // Match Emulation.resume/tick: PS2 uses the output clock and 80 ms
            // reserve. The old one-run-per-display-frame clock is no longer
            // used for this core and can starve after asynchronous boot.
            veta_audio_clear();NativeAudio.prefill(minimumDuration:0.08)
            let before=veta_audio_count(),dropped=veta_audio_dropped(),missing=veta_audio_underruns()
            for _ in 0..<600 {
                _ = NativeAudio.refill()
                veta_audio_read(&left,&right,735,1)
            }
            let speed=Double(veta_audio_count()-before)/(10*44100)
            print("PS2_AUDIO_CLOCK round=\(round) speed=\(speed) missing=\(veta_audio_underruns()-missing) dropped=\(veta_audio_dropped()-dropped)")
            XCTAssertEqual(speed,1,accuracy:0.01)
            XCTAssertEqual(veta_audio_underruns(),missing)
            XCTAssertEqual(veta_audio_dropped(),dropped)
        }
        // Reset must pause the VM and boot once, then resume real video/audio.
        let beforeResetAudio=veta_audio_count()
        veta_reset()
        for _ in 0..<1800 {veta_run()}
        XCTAssertGreaterThan(veta_audio_count()-beforeResetAudio,44100)
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2)
    }
    func testXumpSafePlatformInput() throws {
        let fixtures=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures")
        let url=fixtures.appendingPathComponent("xump-ps2.iso")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"Local authorized Xump fixture required")
        let library=Library(root:temp.appendingPathComponent("library")),game=try library.importNativeFile(url,console:.ps2)
        let save=try library.prepareCoreSaves(for:game),system=try library.prepareSystem(for:.ps2,documents:PhysicalFixturePaths.root)
        XCTAssertTrue(veta_load_system(library.romURL(game).path,save.path,system.path,"Auto",19))
        func playerX()->Double {
            let w=Int(veta_width()),h=Int(veta_height()),pixels=veta_video()!
            var total=0,count=0
            // Only the yellow player on level 01's starting platform, excluding
            // the HUD and the menu artwork. Falling leaves this region empty.
            for y in Int(Double(h)*0.48)..<Int(Double(h)*0.69) {
                for x in Int(Double(w)*0.14)..<Int(Double(w)*0.30) {
                    let p=pixels[y*w+x],r=(p>>16)&255,g=(p>>8)&255,b=p&255
                    if r>180 && g>120 && b<100 {total+=x;count+=1}
                }
            }
            XCTAssertGreaterThan(count,10,"Xump must remain on the safe starting tiles")
            return Double(total)/Double(max(1,count))
        }
        func clock()->[UInt32] {
            let w=Int(veta_width()),h=Int(veta_height()),pixels=veta_video()!
            return (0..<Int(Double(h)*0.06)).flatMap {y in
                (Int(Double(w)*0.85)..<w).map{x in pixels[y*w+x]}
            }
        }
        for _ in 0..<1800 {veta_run()}
        for _ in 0..<2 {
            veta_set_input(0,1);for _ in 0..<3 {veta_run()};veta_set_input(0,0)
            for _ in 0..<60 {veta_run()}
        }
        let initialX=playerX(),initialClock=clock()
        for step in 0..<3 {
            veta_set_input(0,step%2==0 ? 64:128);for _ in 0..<3 {veta_run()};veta_set_input(0,0)
            for _ in 0..<197 {veta_run()}
            let currentX=playerX()
            if step%2==0 {XCTAssertLessThan(currentX,initialX-10)}
            else {XCTAssertEqual(currentX,initialX,accuracy:8)}
        }
        XCTAssertNotEqual(initialClock,clock(),"The ten-second input path must leave the timer running")
    }

    private func awaitPSPBoot() throws {
        // PPSSPP loads asynchronously: a tight retro_run loop may exhaust hundreds
        // of polls before the loader gets CPU time. Audio callbacks establish that
        // emulation has begun; retain all rendering/audio/state assertions below.
        let deadline=Date().addingTimeInterval(10)
        while veta_audio_count()==0 && Date()<deadline {
            veta_run()
            if veta_audio_count()==0 {Thread.sleep(forTimeInterval:0.001)}
        }
        guard veta_audio_count()>0 else {throw NSError(domain:"VETATest",code:1,userInfo:[NSLocalizedDescriptionKey:"PSP failed to finish asynchronous boot within 10 seconds"])}
    }
    func testPSPAutomaticRestoreWaitsForBootAndPreservesLegacyBatteryFile() throws {
        let url=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/sudoku-psp.pbp")
        let library=Library(root:temp.appendingPathComponent("psp-cold-restore"))
        let game=try library.importNativeFile(url,console:.psp)
        let screen=MetalScreen();XCTAssertTrue(screen.ready)
        let first=Emulation(game:game,library:library)
        first.open(screen:screen)
        try awaitPSPBoot();for _ in 0..<120 {veta_run()}
        XCTAssertEqual(veta_ram_size(),0)
        first.pause();XCTAssertNil(first.error);first.close()
        let legacy=Data(repeating:0x63,count:4096),battery=library.file(game,"battery.sav")
        try legacy.write(to:battery)
        for _ in 0..<3 {
            let next=Emulation(game:game,library:library)
            next.open(screen:screen)
            XCTAssertTrue(next.ready);XCTAssertNil(next.error,"Automatic restore must await the asynchronous core")
            XCTAssertEqual(next.status,"Partida cargada")
            XCTAssertEqual(veta_ram_size(),0)
            XCTAssertEqual(try Data(contentsOf:battery),legacy,"Do not overwrite or delete legacy user files")
            next.pause();XCTAssertNil(next.error);next.close()
        }
    }
    func testPSPOutputClockAcrossRestoreAndDisplayJitter() throws {
        let url=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/sound.prx")
        let library=Library(root:temp.appendingPathComponent("psp-clock"))
        let system=try library.prepareSystem(for:.psp,documents:PhysicalFixturePaths.root)
        XCTAssertTrue(veta_load_system(url.path,temp.path,system.path,"Auto",14))
        try awaitPSPBoot();for _ in 0..<120 {veta_run()}
        let snapshot=try state(),rate=veta_sample_rate(),fps=veta_fps()
        for _ in 0..<3 {
            restore(snapshot);veta_audio_clear();NativeAudio.prefill(minimumDuration:0.08)
            let missing=veta_audio_underruns(),dropped=veta_audio_dropped()
            for step in 0..<180 {
                let count=step%30==0 ? 2205:735
                var left=[Float](repeating:0,count:count),right=left
                veta_audio_read(&left,&right,UInt32(count),1)
                XCTAssertLessThanOrEqual(NativeAudio.refill().frames,4)
            }
            XCTAssertEqual(veta_audio_underruns(),missing)
            XCTAssertEqual(veta_audio_dropped(),dropped)
            XCTAssertEqual(veta_sample_rate(),rate);XCTAssertEqual(veta_fps(),fps)
        }
    }
    func testPSPSoundCore()throws {
        let url=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/sound.prx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"PSP audio fixture required")
        let library=Library(root:temp.appendingPathComponent("library")),system=try library.prepareSystem(for:.psp,documents:PhysicalFixturePaths.root)
        for path in ["PSP/SAVEDATA","PSP/SYSTEM","PSP/PPSSPP_STATE"] {let target=temp.appendingPathComponent(path,isDirectory:true);try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)}
        XCTAssertTrue(veta_load_system(url.path,temp.path,system.path,"Auto",14))
        try awaitPSPBoot()
        for _ in 0..<120{veta_run()};veta_set_input(0,1);for _ in 0..<60{veta_run()};veta_set_input(0,0);for _ in 0..<300{veta_run()}
        print("VETA_PSP_SOUND nonzero=\(veta_audio_nonzero()) samples=\(veta_audio_count())")
        XCTAssertGreaterThan(veta_audio_nonzero(),1000)
    }
    func testPSPGame()throws {
        let url=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/XUMP-PSP/EBOOT.PBP")
        let library=Library(root:temp.appendingPathComponent("library")),game=try library.importNativeFile(url,console:.psp)
        try FileManager.default.copyItem(at:url.deletingLastPathComponent().appendingPathComponent("DATA"),to:library.file(game,"DATA"))
        let system=try library.prepareSystem(for:.psp,documents:PhysicalFixturePaths.root),save=try library.prepareCoreSaves(for:game)
        XCTAssertTrue(veta_load_system(library.romURL(game).path,save.path,system.path,"Auto",14))
        for _ in 0..<900 {veta_run()}
        XCTAssertGreaterThan(veta_audio_nonzero(),1000)
        let before=frame();veta_set_input(0,1);for _ in 0..<30 {veta_run()};veta_set_input(0,0);for _ in 0..<120 {veta_run()};XCTAssertNotEqual(before,frame())
        print("PSP_GAME audio=\(veta_audio_nonzero()) colors=\(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count)")
        let snapshot=try state();for _ in 0..<10 {veta_run()};restore(snapshot)
    }
    func testPSPHardwareCore()throws {
        let url=PhysicalFixturePaths.root.appendingPathComponent("EngineFixtures/cubevfpu.prx")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"PPSSPP's own homebrew fixture required")
        let library=Library(root:temp.appendingPathComponent("library")),system=try library.prepareSystem(for:.psp,documents:PhysicalFixturePaths.root)
        XCTAssertTrue(veta_load_system(url.path,temp.path,system.path,"Auto",14))
        try awaitPSPBoot()
        let start=Date()
        for _ in 0..<180{veta_run()}
        print("VETA_PSP: \(veta_width())x\(veta_height()) audio=\(veta_audio_count()) nonzero=\(veta_audio_nonzero()) seconds=\(Date().timeIntervalSince(start)) state=\(veta_state_size())")
        XCTAssertGreaterThan(Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count,2)
        let saved=try state();for _ in 0..<30{veta_run()};let expected=frame()
        restore(saved);for _ in 0..<30{veta_run()};XCTAssertEqual(expected,frame())
        veta_unload()
    }
    func testSegaAndAtariCores()throws {
        for (name,console) in [("gold-rush",GameConsole.megaDrive),("sushi-sms",.masterSystem),("sushi-gg",.gameGear),("berta",.atari2600)] {
            let url=try XCTUnwrap(Bundle.main.url(forResource:name,withExtension:console.romExtension,subdirectory:"Content/\(name)"))
            try exerciseCore(url,console:console)
        }
        try load();for _ in 0..<180 {veta_run()}
        XCTAssertGreaterThan(veta_audio_count(),10000,"NES must still work after unloading each isolated framework")
    }
    func testGameBoyNativeCore()throws {try handheld("sushi-gb",console:.gb)}
    func testGameBoyColorNativeCore()throws {try handheld("gluf-gbc",console:.gbc)}
    func testGameBoyAdvanceNativeCore()throws {try handheld("space-game",console:.gba)}
    func testSNESNativeCore()throws {
        let url=PhysicalFixturePaths.root.appendingPathComponent("SNES/Space Rescue Squad Demo v1.1.sfc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath:url.path),"Local author-provided SNES demo required; not redistributed in the app")
        try exerciseCore(url,console:.snes)
    }
    func testHandheldBatteryAndRTCReload()throws {
        var rom=try Data(contentsOf:XCTUnwrap(Bundle.main.url(forResource:"sushi-gb",withExtension:"gb",subdirectory:"Content/sushi-gb")))
        // Test cartridge only: MBC3 with battery/RTC, original licensed fixture untouched.
        rom[0x147]=0x10;rom[0x149]=3
        let url=temp.appendingPathComponent("clock.gb");try rom.write(to:url)
        XCTAssertTrue(veta_load_console(url.path,temp.path,"Auto",2))
        for _ in 0..<120 {veta_run()}
        let count=veta_ram_size();XCTAssertEqual(count,32768)
        let expected=Data((0..<count).map{UInt8($0%251)})
        XCTAssertTrue(expected.withUnsafeBytes{veta_write_ram($0.baseAddress,$0.count)})
        let rtcCount=veta_rtc_size();XCTAssertGreaterThan(rtcCount,0)
        var clock=Data(count:rtcCount);clock.withUnsafeMutableBytes{veta_read_rtc($0.baseAddress,$0.count)}
        veta_unload();XCTAssertTrue(veta_load_console(url.path,temp.path,"Auto",2))
        XCTAssertTrue(expected.withUnsafeBytes{veta_write_ram($0.baseAddress,$0.count)})
        XCTAssertTrue(clock.withUnsafeBytes{veta_write_rtc($0.baseAddress,$0.count)})
        var actual=Data(count:count);actual.withUnsafeMutableBytes{veta_read_ram($0.baseAddress,$0.count)};XCTAssertEqual(expected,actual)
        var actualClock=Data(count:rtcCount);actualClock.withUnsafeMutableBytes{veta_read_rtc($0.baseAddress,$0.count)};XCTAssertEqual(clock,actualClock)
    }
    func testMultiConsoleImportAndLegacyMigration()throws {
        let library=Library(root:temp.appendingPathComponent("multi"))
        let old=try fixture();let legacy=try library.add(data:old,name:"NES original")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:library.root.appendingPathComponent("library.json"))) as? [[String:Any]])
        json[0].removeValue(forKey:"console")
        try JSONSerialization.data(withJSONObject:json).write(to:library.root.appendingPathComponent("library.json"))
        let reopened=Library(root:library.root)
        XCTAssertEqual(reopened.games.first?.console,.nes)
        XCTAssertEqual(try Data(contentsOf:reopened.romURL(legacy)),old)
        for (name,console) in [("sushi-gb",GameConsole.gb),("gluf-gbc",.gbc),("space-game",.gba)] {
            let url=try XCTUnwrap(Bundle.main.url(forResource:name,withExtension:console.romExtension,subdirectory:"Content/\(name)"))
            try reopened.importURL(url);try reopened.importURL(url)
            XCTAssertEqual(reopened.games.filter{$0.console == console}.count,1)
            XCTAssertThrowsError(try Library.validateROM(Data([0,1,2,3]),console:console))
        }
        let backup=try reopened.export(),restored=Library(root:temp.appendingPathComponent("restored"))
        try restored.importURL(backup)
        XCTAssertEqual(Set(restored.games.map(\.console)),Set([.nes,.gb,.gbc,.gba]))
        XCTAssertEqual(restored.games,expectedBackupGames(reopened))
        let documents=temp.appendingPathComponent("Documents")
        try restored.enable(.threeDS,documents:documents);try restored.enable(.gamecube,documents:documents)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:documents.path)),Set(["Nintendo 3DS","GameCube"]))
        XCTAssertTrue(Library(root:restored.root).consoles.contains(.threeDS))
        XCTAssertEqual(GameConsole.chronological.map(\.year),GameConsole.chronological.map(\.year).sorted())
    }
    func testMultiConsoleControlGeometry() {
        for console in GameConsole.allCases.filter(\.playable) {
            for safe in [CGRect(x:0,y:20,width:320,height:548),CGRect(x:0,y:62,width:402,height:778),CGRect(x:62,y:0,width:750,height:381),CGRect(x:0,y:24,width:1024,height:1322)] {
                let layout=ConsoleLayout(safe:safe,aspect:console.aspect,minimumDeck:console.minimumDeck)
                XCTAssertEqual(layout.screen.width/layout.screen.height,console.aspect,accuracy:0.001)
                for size in [0.85,1.0,1.2] {for height in [-0.12,0.0,0.12] {
                    let deck=TouchDeck(frame:layout.deck);deck.landscape=safe.width>safe.height
                    var style=ControlStyle(console:console);style.size=size;style.height=height;deck.style=style;deck.layoutIfNeeded()
                    XCTAssertEqual(deck.zones["L"] != nil,console.shoulders && console != .wii)
                    XCTAssertEqual(deck.zones["X"] != nil,console.fourButtons || console == .megaDrive)
                    for (name,rect) in deck.zones {
                        XCTAssertTrue(deck.bounds.contains(rect),"\(console) \(safe) \(name) \(rect)")
                        XCTAssertFalse(rect.offsetBy(dx:layout.deck.minX,dy:layout.deck.minY).intersects(layout.screen))
                        for (other,otherRect) in deck.zones where name<other {
                            XCTAssertFalse(rect.intersects(otherRect),"\(console) \(safe) \(size) \(height) overlaps \(name)/\(other)")
                        }
                    }
                }}
            }
        }
    }
    func testPausedRestoreSurvivesRepeatedPauseAndExit() throws {
        let library=Library(root:temp.appendingPathComponent("paused-session"))
        let game=try library.add(data:fixture(),name:"Pause regression")
        let session=Emulation(game:game,library:library),screen=MetalScreen()
        session.open(screen:screen);defer {session.close()}
        XCTAssertTrue(session.ready);XCTAssertNil(session.error)
        for _ in 0..<90 {veta_run()}
        session.pause();try session.save()
        let quick=try StateFile.decode(Data(contentsOf:library.file(game,"quick.vstate")),rom:game.id)
        for _ in 0..<90 {veta_run()}
        try session.restore();session.pause()
        XCTAssertEqual(session.status,"Partida cargada")
        session.close()
        let automatic=try StateFile.decode(Data(contentsOf:library.file(game,"auto.vstate")),rom:game.id)
        XCTAssertEqual(automatic,quick,"Leaving after a paused restore must preserve the loaded moment")
    }
    func testAutomaticPALPreservesLegacyHeaderAndFilenameRules() throws {
        var bytes=try fixture()
        bytes[9]=1
        for i in 10..<16 {bytes[i]=0}
        let game=Game(id:sha256(bytes),name:"Homebrew")
        XCTAssertEqual(Library.effectiveRegion(game,rom:bytes),"PAL")
        let url=temp.appendingPathComponent("legacy.nes");try bytes.write(to:url)
        XCTAssertTrue(veta_load(url.path,temp.path,Library.effectiveRegion(game,rom:bytes)))
        XCTAssertEqual(veta_fps(),50,accuracy:0.1)
        bytes[9]=0
        XCTAssertEqual(Library.effectiveRegion(Game(id:game.id,name:"Game (Europe)"),rom:bytes),"PAL")
        XCTAssertEqual(Library.effectiveRegion(Game(id:game.id,name:"Palamedes"),rom:bytes),"Auto")
        var forced=game;forced.region="NTSC"
        XCTAssertEqual(Library.effectiveRegion(forced,rom:bytes),"NTSC")
    }

}
