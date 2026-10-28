#if VETA_JIT_DEVELOPMENT
import SwiftUI

/// Explicit local validation only. Uses the ordinary player and core selection,
/// with all state/RAM writes redirected to the pre-existing QA cache namespace.
struct Commercial170QAView: View {
    @ObservedObject var library: Library
    var body: some View {
        let env=ProcessInfo.processInfo.environment
        if env["VETA_TV158_QA_PRIMARY"] == "1",
           let id=env["VETA_COMMERCIAL170_GAME"],
           let game=library.games.first(where:{$0.id==id}),
           [.snes,.megaDrive,.masterSystem,.gameGear,.atari2600].contains(game.console) {
            Commercial170QAPlayer(game:game,library:library)
        } else { Text(verbatim:"QA requires one replacement console and isolated saves") }
    }
}

private struct Commercial170QAPlayer: View {
    @StateObject private var session: Emulation
    private let preflight:DeviceReadiness.Preflight
    @State private var status="QA 170 running"
    init(game:Game,library:Library) {
        let readiness=DeviceReadiness.capture()
        let plan=GameLaunchPlan.resolve(console:game.console,snapshot:readiness.snapshot,preference:.automatic)
        preflight=readiness.preflight(game:game,library:library,plan:plan)
        _session=StateObject(wrappedValue:Emulation(game:game,library:library,plan:plan))
    }
    var body: some View {
        GameSurface(session:session,skin:"Clásica",revision:0).ignoresSafeArea()
            .overlay(alignment:.top) {Text(verbatim:status).padding().background(.black.opacity(0.8)).padding(.top,48)}
            .task {await run()}
            .onDisappear {session.close()}
    }
    @MainActor private func run() async {
        let run=ProcessInfo.processInfo.environment["VETA_TV158_QA_RUN"] ?? ""
        guard !run.isEmpty,run.count<=32,run.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45}) else {return}
        let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Veta170QA/"+run,isDirectory:true)
        let stem=session.game.id
        var record:[String:Any]=["game":stem,"console":session.game.console.rawValue,"core":session.game.coreID,
                                 "mode":session.plan.mode.rawValue,"scope":"physical iPhone, isolated saves, synthetic touch input"]
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            record["libraryPreflight"]=preflight.canLaunch
            guard preflight.canLaunch else {throw VetaError.message(preflight.blockers.joined(separator:"; "))}
            for _ in 0..<100 {
                if let error=session.error {throw VetaError.message(error)}
                // UIKit may finish constructing GameSurface before the launch
                // becomes active. Match the normal player's foreground resume.
                if session.ready && !session.running && UIApplication.shared.applicationState == .active {session.resume()}
                if session.ready && session.running {break}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            guard session.ready,session.running else {throw VetaError.message("QA player not running")}
            record["jitAvailable"]=veta_jit_available()
            let start=ProcessInfo.processInfo.systemUptime, frames=veta_frame_count(), audio=veta_audio_count()
            var images=[String](),observed=[UInt16]()
            for second in 0..<24 {
                let buttons:UInt16 = [3,6,9].contains(second) ? 1<<3 : second>=12 && second<20 ? (1<<7)|(1<<8):0
                session.setTouches(buttons)
                try await Task.sleep(nanoseconds:1_000_000_000)
                observed.append(veta_input_mask(0))
                if [2,11,23].contains(second), let png=GameplayScreenshot.png() {
                    let name=stem+"-frame-"+String(second)+".png"
                    try png.write(to:root.appendingPathComponent(name),options:.atomic);images.append(name)
                }
                if let error=session.error {throw VetaError.message(error)}
            }
            session.setTouches(0)
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            record["elapsed"]=elapsed;record["frames"]=veta_frame_count()-frames
            record["emulatedFramesPerSecond"]=Double(veta_frame_count()-frames)/elapsed
            record["targetFPS"]=veta_fps();record["audioFrames"]=veta_audio_count()-audio
            record["nonzeroAudioFrames"]=veta_audio_nonzero();record["inputMasks"]=observed
            record["images"]=images;record["thermalState"]=ProcessInfo.processInfo.thermalState.rawValue
            guard veta_frame_count()>frames+600,veta_audio_count()>audio,observed.contains(where:{$0 != 0}) else {
                throw VetaError.message("QA insufficient frame/audio/input evidence")
            }
            session.pause()
            try session.save("quick")
            let saved=try session.saveStore.read("quick")
            session.resume();try await Task.sleep(nanoseconds:1_000_000_000);session.pause()
            try session.restore("quick")
            guard try session.saveStore.read("quick")==saved else {throw VetaError.message("QA snapshot changed")}
            record["saveRestore"]="PASS";record["ramBytes"]=veta_ram_size()
            session.resume();try await Task.sleep(nanoseconds:1_000_000_000);session.pause()
            record["resume"]="PASS";record["status"]="PASS";status="QA 170 PASS"
        } catch {record["status"]="FAIL";record["error"]=error.localizedDescription;status="QA 170 FAIL: "+error.localizedDescription;session.pause()}
        if let data=try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent(stem+".json"),options:.atomic)
        }
    }
}
#endif
