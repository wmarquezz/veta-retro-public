import XCTest
import UIKit
@testable import VetaNative

/// Opt-in evaluation of user-provided cartridges/discs in an isolated library.
/// Core evidence only: PCM production is not an audible-speaker test, and
/// emulated frame throughput is not physical-device performance.
@MainActor final class RetailCoreTests:XCTestCase {
    struct Entry:Decodable {let console:GameConsole;let path:String;let name:String}
    // GPU readback can round a small number of channels by one 8-bit unit.
    // Observed PSP replay: 68 channels, delta exactly 1, out of 518400.
    // Preserve exact comparisons for other cores and reject motion, broad
    // differences, alpha changes, or a delta of 2 even in a single channel.
    private func samePicture(_ a:Data,_ b:Data,console:GameConsole)->Bool {
        if a==b {return true}
        guard console == .psp,a.count==b.count,a.count%4==0,!a.isEmpty else{return false}
        var changedPixels=0
        for offset in stride(from:0,to:a.count,by:4) {
            guard a[offset+3]==b[offset+3] else{return false}
            var changed=false
            for channel in 0..<3 {
                let delta=abs(Int(a[offset+channel])-Int(b[offset+channel]))
                if delta>1 {return false};changed = changed || delta>0
            }
            if changed {changedPixels+=1}
            if changedPixels>a.count/4/1000 {return false}
        }
        return true
    }
    func testPSPReplayComparisonRejectsMotionAndOnlyAllowsSparseRounding() {
        let a=Data(repeating:100,count:4000)
        var b=a;b[0]=101
        XCTAssertTrue(samePicture(a,b,console:.psp))
        XCTAssertFalse(samePicture(a,b,console:.nes))
        b[4]=101;XCTAssertFalse(samePicture(a,b,console:.psp))
        b=a;b[0]=102;XCTAssertFalse(samePicture(a,b,console:.psp))
        b=a;b[3]=101;XCTAssertFalse(samePicture(a,b,console:.psp))
        XCTAssertFalse(samePicture(a,Data(),console:.psp))
    }
    func testPSPCancelDuringBootAndReopen()throws {
        let env=ProcessInfo.processInfo.environment
        guard let folder=env["VETA_RETAIL_ROOT"],let selected=env["VETA_RETAIL_NAME"] else{throw XCTSkip("Explicit local collection required")}
        let source=URL(fileURLWithPath:folder),fm=FileManager.default
        let entries=try JSONDecoder().decode([Entry].self,from:Data(contentsOf:source.appendingPathComponent("selection.json")))
        let entry=try XCTUnwrap(entries.first{$0.name==selected && $0.console == .psp})
        let docs=fm.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let library=Library(root:docs.appendingPathComponent("PSPCancellationIsolated"))
        try library.importURLs([source.appendingPathComponent(entry.path)],console:.psp)
        let game=try XCTUnwrap(library.games.first)
        let saves=try library.prepareCoreSaves(for:game),system=try library.prepareSystem(for:.psp,documents:docs)
        for delay in [0.0,0.005] {
            XCTAssertTrue(veta_load_system(library.romURL(game).path,saves.path,system.path,"Auto",game.coreIndex))
            Thread.sleep(forTimeInterval:delay)
            // Closing while the asynchronous loader still owns graphics must
            // not destroy its context before pending boot work is joined.
            veta_unload()
        }
        guard veta_load_system(library.romURL(game).path,saves.path,system.path,"Auto",game.coreIndex) else {
            return XCTFail("PSP did not reopen after cancellation")
        }
        defer{veta_unload()}
        let deadline=Date().addingTimeInterval(30)
        while veta_audio_count()==0 && Date()<deadline {
            veta_run()
            if veta_audio_count()==0 {Thread.sleep(forTimeInterval:0.001)}
        }
        XCTAssertGreaterThan(veta_audio_count(),0,"Reopened PSP must complete asynchronous boot")
        for _ in 0..<120 {veta_run()}
        XCTAssertGreaterThan(veta_frame_count(),100)
        print("PSP_CANCEL_REOPEN_PASS frames=\(veta_frame_count())")
    }
    func testSelectedRetailGame()throws {
        let env=ProcessInfo.processInfo.environment
        guard let folder=env["VETA_RETAIL_ROOT"],let selected=env["VETA_RETAIL_NAME"] else{throw XCTSkip("Explicit local collection required")}
        let source=URL(fileURLWithPath:folder),fm=FileManager.default
        let entries=try JSONDecoder().decode([Entry].self,from:Data(contentsOf:source.appendingPathComponent("selection.json")))
        let entry=try XCTUnwrap(entries.first{$0.name==selected})
        let docs=fm.urls(for:.documentDirectory,in:.userDomainMask)[0]
        let library=Library(root:docs.appendingPathComponent("RetailIsolated"))
        try library.importURLs([source.appendingPathComponent(entry.path)],console:entry.console)
        let game=try XCTUnwrap(library.games.first)
        let saves=try library.prepareCoreSaves(for:game),system=try library.prepareSystem(for:entry.console,documents:docs)
        let started=Date()
        guard veta_load_system(library.romURL(game).path,saves.path,system.path,"Auto",game.coreIndex) else {
            XCTFail("Core rejected the imported game; no runtime checks were performed")
            return
        }
        defer{veta_unload()}
        if entry.console == .psp {
            // retro_load_game starts a worker; its initial retro_run calls are
            // loader polls, not guest frames. Await the first audio callback
            // (silence is allowed here) before timing or capturing any state.
            let deadline=Date().addingTimeInterval(30)
            while veta_audio_count()==0 && Date()<deadline {
                veta_run()
                if veta_audio_count()==0 {Thread.sleep(forTimeInterval:0.001)}
            }
            guard veta_audio_count()>0 else {XCTFail("PSP asynchronous boot did not finish in 30 seconds");return}
            XCTAssertEqual(veta_ram_size(),0,"PSP filesystem saves must not be treated as cartridge battery RAM")
        }
        func frame()->Data {Data(bytes:veta_video(),count:Int(veta_width()*veta_height()*4))}
        func run(_ count:Int){for _ in 0..<count{veta_run()}}
        func state()throws->Data {
            let size=veta_state_size();XCTAssertGreaterThan(size,0)
            var bytes=Data(count:size)
            let saved=bytes.withUnsafeMutableBytes{veta_save_state($0.baseAddress,$0.count)}
            return try XCTUnwrap(saved ? bytes:nil,"The core did not produce a valid state; do not restore an empty buffer")
        }
        func restore(_ bytes:Data)throws {
            let loaded=bytes.withUnsafeBytes{veta_load_state($0.baseAddress,$0.count)}
            _ = try XCTUnwrap(loaded ? true:nil,"Core rejected the saved state")
        }
        func screenshot(_ name:String)throws {
            guard let provider=CGDataProvider(data:frame() as CFData),let image=CGImage(width:Int(veta_width()),height:Int(veta_height()),bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:Int(veta_width())*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else{return XCTFail("No valid game frame")}
            try UIImage(cgImage:image).pngData()!.write(to:docs.appendingPathComponent(name+".png"))
        }
        let bootFrames=min(7200,max(600,Int(env["VETA_RETAIL_BOOT_FRAMES"] ?? "600") ?? 600))
        run(bootFrames)
        // Explicit, recorded navigation for titles with silent menus or long
        // introductions. Never infer a successful audio check from a title screen.
        let setup=env["VETA_RETAIL_SETUP"] ?? ""
        for step in setup.split(separator:",") {
            let parts=step.split(separator:":")
            guard parts.count==3,let held=Int(parts[1]),let released=Int(parts[2]),
                  (0...3600).contains(held),(0...3600).contains(released) else {
                XCTFail("Invalid explicit gameplay setup");return
            }
            let key=String(parts[0]),directions:[String:UInt16]=["UP":1<<4,"DOWN":1<<5,"LEFT":1<<6,"RIGHT":1<<7]
            let mask=directions[key] ?? entry.console.buttonMask(key)
            guard mask != 0 else {XCTFail("Unknown setup control: "+key);return}
            veta_set_input(0,mask);run(held)
            veta_set_input(0,0);run(released)
            try screenshot("retail-setup-\(key)-\(veta_frame_count())")
        }
        try screenshot("retail-title")
        let first=frame();run(120);let motion=first != frame()
        var deterministic=false,inputChanged=false
        for button in ["START","A","B"] {
            let snapshot=try state()
            veta_set_input(0,0);run(120);let idle=frame()
            try restore(snapshot);run(120);let repeatIdle=frame()
            try restore(snapshot);veta_set_input(0,entry.console.buttonMask(button));run(5);veta_set_input(0,0);run(115)
            if samePicture(idle,repeatIdle,console:entry.console) {deterministic=true;if !samePicture(frame(),idle,console:entry.console) {inputChanged=true}}
        }
        run(300)
        let extraFrames=min(3600,max(0,Int(env["VETA_RETAIL_EXTRA_FRAMES"] ?? "0") ?? 0))
        run(extraFrames);try screenshot("retail-after-input")
        let before=try state();run(30);let expected=frame();try screenshot("retail-replay-expected")
        try restore(before);run(30);try screenshot("retail-replay-restored")
        let replayExact=frame()==expected
        let replay=samePicture(frame(),expected,console:entry.console)
        let colors=Set(UnsafeBufferPointer(start:veta_video(),count:Int(veta_width()*veta_height()))).count
        let result:[String:Any]=["name":entry.name,"console":entry.console.rawValue,"source":"local user collection","scope":"core; no speaker/UI/physical performance claim","frames":veta_frame_count(),"fpsTarget":veta_fps(),"nonzeroAudio":veta_audio_nonzero(),"colors":colors,"animatedBeforeInput":motion,"deterministicBaseline":deterministic,"inputChangedImage":inputChanged,"saveRestoreReplay":replay,"elapsedSeconds":Date().timeIntervalSince(started)]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:docs.appendingPathComponent("retail-result.json"))
        try JSONSerialization.data(withJSONObject:["setup":setup,"bootFrames":bootFrames,"extraFrames":extraFrames],options:[.prettyPrinted,.sortedKeys]).write(to:docs.appendingPathComponent("retail-scenario.json"))
        print("RETAIL_CORE_RESULT \(result)")
        print("RETAIL_REPLAY exact=\(replayExact) visuallyEquivalent=\(replay)")
        XCTAssertGreaterThan(colors,2)
        XCTAssertGreaterThan(veta_audio_nonzero(),100)
        XCTAssertTrue(deterministic,"Cannot credit input causality without a stable no-input baseline")
        XCTAssertTrue(inputChanged,"Input did not change the game relative to the same-frame baseline")
        XCTAssertTrue(replay,"Restored state did not replay the same picture")
        if env["VETA_PSP_VERIFY_MEMORY_STICK"] == "1" {
            XCTAssertEqual(entry.console,.psp)
            let card=saves.appendingPathComponent("PSP/SAVEDATA")
            let files=(fm.enumerator(at:card,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? [])
                .filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile)==true}
            XCTAssertTrue(files.contains{$0.lastPathComponent=="PARAM.SFO"},"The game must create native PSP metadata")
            XCTAssertTrue(files.contains{$0.lastPathComponent=="DATA.BIN"},"The game must create native PSP save data")
            let contents=try Dictionary(uniqueKeysWithValues:files.map{($0,try Data(contentsOf:$0))})
            // Start the core afresh, without restoring any VETA snapshot.
            veta_unload()
            XCTAssertTrue(veta_load_system(library.romURL(game).path,saves.path,system.path,"Auto",game.coreIndex))
            let deadline=Date().addingTimeInterval(30)
            while veta_audio_count()==0,Date()<deadline {veta_run();Thread.sleep(forTimeInterval:0.001)}
            XCTAssertGreaterThan(veta_audio_count(),0)
            run(900);try screenshot("retail-memory-stick-reboot")
            for step in (env["VETA_PSP_MEMORY_STICK_REOPEN_SETUP"] ?? "").split(separator:",") {
                let parts=step.split(separator:":")
                guard parts.count==3,let held=Int(parts[1]),let released=Int(parts[2]),
                      (0...3600).contains(held),(0...3600).contains(released) else {XCTFail("Invalid memory-stick reopen navigation");return}
                let key=String(parts[0]),directions:[String:UInt16]=["UP":1<<4,"DOWN":1<<5,"LEFT":1<<6,"RIGHT":1<<7]
                let mask=directions[key] ?? entry.console.buttonMask(key)
                guard mask != 0 else {XCTFail("Unknown reopen control: "+key);return}
                veta_set_input(0,mask);run(held);veta_set_input(0,0);run(released)
                try screenshot("retail-memory-stick-\(key)-\(veta_frame_count())")
            }
            for (url,data) in contents {XCTAssertEqual(try Data(contentsOf:url),data,"Native save changed during read-only reopening")}
            try screenshot("retail-memory-stick-reopened")
            print("PSP_MEMORY_STICK_REOPEN files=\(contents.count) unchanged=true noSnapshot=true")
        }
    }
}
