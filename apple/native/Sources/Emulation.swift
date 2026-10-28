import UIKit
import AVFoundation
import GameController
import SwiftUI

#if VETA_JIT_DEVELOPMENT
// Opt-in observation only. No game names, pixels, controller data or save payloads.
private final class Veta165SchedulingProbe {
    struct Tick: Codable, Sendable {
        let uptime: Double
        let displayTimestamp: Double
        let displayGapMS: Double
        let entryGapMS: Double
        let idleGapMS: Double
        let count: Int
        let workMS: Double
        let presentMS: Double
        let totalMS: Double
        let queuedBefore: UInt32
        let queuedAfter: UInt32
        let audioProduced: UInt64
        let audioDelivered: UInt64
        let audioMissing: UInt64
        let audioDropped: UInt64
        let sampleRate: Double
        let targetFPS: Double
        let audioClock: Bool
        let visualProbe: Bool
        let fastForward: Bool
        let thermal: Int
    }
    struct Report: Codable, Sendable {
        let schema: Int
        let session: String
        let process: Int32
        let phase: String
        let totalTicks: UInt64
        let totalAdvances: UInt64
        let countHistogram: [UInt64]
        let workMS: Double
        let presentMS: Double
        let idleMS: Double
        let retainedTicks: [Tick]
    }
    // At most one write in flight and one newer snapshot retained. JSON encoding
    // and atomic disk replacement stay off the display/audio threads.
    final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "Veta165Scheduling.write", qos: .utility)
        private var busy = false
        private var pending: Report?
        func submit(_ report: Report, to url: URL) {
            lock.lock()
            pending = report
            guard !busy else { lock.unlock(); return }
            busy = true
            lock.unlock()
            queue.async { [self] in
                while true {
                    lock.lock()
                    guard let report = pending else {
                        busy = false; lock.unlock(); return
                    }
                    pending = nil; lock.unlock()
                    do {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let data = try JSONEncoder().encode(report)
                        try data.write(to: url, options: .atomic)
                    } catch { print("VETA165_SCHEDULING write failed: \(error.localizedDescription)") }
                }
            }
        }
    }
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> Veta165SchedulingProbe? {
        guard environment["VETA_PERF165_SCHEDULING"] == "1",
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let raw = environment["VETA_PERF165_RUN"] ?? "unknown"
        let run = String(raw.prefix(80).map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return Veta165SchedulingProbe(directory: caches.appendingPathComponent("Veta165Scheduling"), run: run)
    }
    private let session = UUID().uuidString
    private let output: URL
    private let writer = Writer()
    private var ticks: [Tick] = []
    private var next = 0
    private var totalTicks: UInt64 = 0
    private var totalAdvances: UInt64 = 0
    private var histogram = [UInt64](repeating: 0, count: 5)
    private var workMS = 0.0, presentMS = 0.0, idleMS = 0.0
    private var previousEntry = 0.0, previousEnd = 0.0, lastFlush = 0.0
    init(directory: URL, run: String) {
        output = directory.appendingPathComponent(run + "-" + session + ".json")
        ticks.reserveCapacity(600)
    }
    func beginSegment() { previousEntry = 0; previousEnd = 0 }
    func record(start: Double, end: Double, display: Double, displayGap: Double, count: Int,
                work: Double, present: Double, queuedBefore: UInt32, queuedAfter: UInt32,
                produced: UInt64, delivered: UInt64, missing: UInt64, dropped: UInt64,
                sampleRate: Double, targetFPS: Double, audioClock: Bool, visualProbe: Bool,
                fastForward: Bool, thermal: Int) {
        let idle = previousEnd > 0 ? max(0, start - previousEnd) * 1000 : 0
        let tick = Tick(uptime: start, displayTimestamp: display, displayGapMS: displayGap * 1000,
                        entryGapMS: previousEntry > 0 ? (start - previousEntry) * 1000 : 0,
                        idleGapMS: idle, count: count, workMS: work, presentMS: present,
                        totalMS: (end - start) * 1000, queuedBefore: queuedBefore, queuedAfter: queuedAfter,
                        audioProduced: produced, audioDelivered: delivered, audioMissing: missing,
                        audioDropped: dropped, sampleRate: sampleRate, targetFPS: targetFPS,
                        audioClock: audioClock, visualProbe: visualProbe, fastForward: fastForward, thermal: thermal)
        previousEntry = start; previousEnd = end
        if ticks.count < 600 { ticks.append(tick) } else { ticks[next] = tick; next = (next + 1) % 600 }
        totalTicks += 1; totalAdvances += UInt64(max(0, count)); histogram[min(4, max(0, count))] += 1
        workMS += work; presentMS += present; idleMS += idle
        if end - lastFlush >= 5 { lastFlush = end; flush(phase: "running") }
    }
    func flush(phase: String) {
        let ordered = ticks.count == 600 ? Array(ticks[next...]) + Array(ticks[..<next]) : ticks
        writer.submit(Report(schema: 1, session: session, process: ProcessInfo.processInfo.processIdentifier,
                             phase: phase, totalTicks: totalTicks, totalAdvances: totalAdvances,
                             countHistogram: histogram, workMS: workMS, presentMS: presentMS,
                             idleMS: idleMS, retainedTicks: ordered), to: output)
    }
}
#endif

final class NativeAudio {
    static func refillSnapshotBudget(console: GameConsole, override: String? = nil) -> Bool {
        console == .threeDS || ((console == .gamecube || console == .wii) && override != "0")
    }
    static func usesHybridReadback(console: GameConsole, snapshotBudget: Bool, override: String? = nil) -> Bool {
        guard snapshotBudget && (console == .gamecube || console == .wii) else { return false }
        return override != "0" && override != "1" && override != "profile"
    }
#if VETA_JIT_DEVELOPMENT
    static let refillFramesOverride = ProcessInfo.processInfo.environment["VETA_PERF165_REFILL_FRAMES"]
    static let snapshotBudgetOverride = ProcessInfo.processInfo.environment["VETA_PERF165_SNAPSHOT_BUDGET"]
    static let readbackModeOverride: String? = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["VETA_PERF165_DEFER_GC_READBACK"]
        #else
        return nil
        #endif
    }()
    static func refillFrameLimit(console: GameConsole, override: String?) -> Int {
        guard console == .gamecube || console == .wii else { return 4 }
        switch override {
        case "1": return 1
        case "2": return 2
        case "4": return 4
        default: return 4
        }
    }
#endif
    static let visualRenderProbe:Bool = {
        #if VETA_JIT_DEVELOPMENT
        return ProcessInfo.processInfo.environment["VETA_TV158_QA_PRIMARY"] == "1" && ProcessInfo.processInfo.environment["VETA_OFFLINE160_AUDIO"] != "1"
        #else
        return false
        #endif
    }()

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    // Cores produce whole video-frame batches; the output device consumes
    // smaller blocks. Start with a short reserve instead of an empty queue.
    // Keep the core's actual clock/pitch unchanged and bound startup work.
    static func prefill(minimumDuration:Double=0.04) {
        let target=UInt32(veta_sample_rate()*max(minimumDuration,2/veta_fps()))
        for _ in 0..<8 {
            if veta_audio_queued()>=target {break}
            veta_run()
        }
    }
    // The output device is the clock for cores with batched audio. Rebuild the
    // bounded reserve after a delayed display callback instead of permanently
    // losing it when the display scheduler discards catch-up time.
    static func refill(reserveDuration:Double=0.08,maximumFrames:Int=4,snapshotBudget:Bool=false,runFrame:()->Void={veta_run()},hintLastFrame:((Bool)->Void)?=nil)->(frames:Int,hasAudio:Bool) {
        let target=UInt32(veta_sample_rate()*reserveDuration)
        var count=0
        let before=veta_audio_count()
        let queued=veta_audio_queued()
        let deficit=UInt64(target>queued ? target-queued:0)
        let samplesPerFrame = hintLastFrame == nil ? 0 : veta_sample_rate()/veta_fps()
        let expectedSamples = samplesPerFrame.isFinite && samplesPerFrame>0 && samplesPerFrame<Double(UInt32.max) ? UInt64(ceil(samplesPerFrame)):0
        // Expensive cores must not chase the consumer while they execute.
        // Keep the amount owed at callback entry, with the same bounded work.
        while count<maximumFrames && (snapshotBudget ? veta_audio_count()-before<deficit:veta_audio_queued()<target) {
            // Play delivers SPU blocks spanning more than one video frame.
            // An empty frame does not mean audio stopped: keep filling within
            // the work budget, otherwise the reserve collapses after restore.
            if let hintLastFrame {
                let produced=veta_audio_count()-before
                let remaining=deficit>produced ? deficit-produced:0
                // A readback hint only: actual PCM still decides how many
                // frames run. Unexpected audio batches retain the final flush.
                hintLastFrame(!snapshotBudget || expectedSamples==0 || remaining<=expectedSamples || count==maximumFrames-1)
            }
            runFrame();count+=1
        }
        return (count,count == 0 || veta_audio_count()>before)
    }
    func start(rate: Double, volume: Float, reserveDuration:Double=0.04) throws {
        stop()
        // Local image QA must not reactivate a previously selected AirPlay
        // audio receiver. It uses the display clock and discards generated PCM.
        if Self.visualRenderProbe {return}
        let session = AVAudioSession.sharedInstance()
        let policy=AudioPlaybackPolicy.current
        try session.setCategory(policy.category, mode:.default, options:policy.options)
        try session.setPreferredSampleRate(rate)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate:rate, channels:2) else { throw VetaError.message("Formato de audio no disponible.") }
        let source = AVAudioSourceNode(format:format) { _,_,count,list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let l = buffers[0].mData, let r = buffers[1].mData else { return noErr }
            veta_audio_read(l.assumingMemoryBound(to:Float.self),r.assumingMemoryBound(to:Float.self),count,1)
            return noErr
        }
        self.source = source
        engine.attach(source); engine.connect(source,to:engine.mainMixerNode,format:format)
        engine.mainMixerNode.outputVolume = volume
        Self.prefill(minimumDuration:reserveDuration)
        try engine.start()
    }
    func setVolume(_ value: Float) { engine.mainMixerNode.outputVolume = value }
    func stop() {
        engine.stop()
        if let source { engine.detach(source); self.source = nil }
        veta_audio_clear()
    }
}
@MainActor final class Emulation: NSObject, ObservableObject {
    @Published var showMenu = false
    @Published var error: String?
    @Published var status = ""
    @Published var ready = false
    @Published var diagnostics = ""
    @Published private(set) var fastForward=false
    @Published private(set) var heldButtons:UInt16=0
    private var fastClock=FastForwardClock()
    var supportsFastForward:Bool {GameplayControlPolicy.fastForwardAvailable(game.console)}
    let game: Game
    let plan: GameLaunchPlan
    let library: Library
    private var link: CADisplayLink?
    private let audio = NativeAudio()
    weak var screen: MetalScreen?
    var releaseTouches: (() -> Void)?
    var finished: (() -> Void)?
    private(set) var running = false
    private var opened = false
    private var lastTime: CFTimeInterval = 0
    private var accumulated: Double = 0
    private var pendingVideo=false
    private var touchMask: UInt16 = 0
    private var touchAnalog=[CGPoint.zero,CGPoint.zero]
    private var observers: [NSObjectProtocol] = []
    private var metricStart: CFTimeInterval = 0
    private var previousFrames: UInt64 = 0
    private var frameCosts: [Double] = []
    private var savedFrames: UInt64 = 0
    private var activeProfile = CoreProfile()
    var activeOptionsFingerprint: String { activeProfile.fingerprint }
    var saveStore: NativeSaveStore { NativeSaveStore(directory: library.stateDirectory(game, plan: plan), rom: game.id, core: plan.stateCoreID(for: game)) }
#if VETA_JIT_DEVELOPMENT
    private var lastTelemetry: CFTimeInterval = 0
    private func telemetry(_ event:String) {JITTelemetry.record(event:event,core:game.coreID,console:game.console.shortName,metrics:diagnostics+Self.runProfileMetrics)}
#endif
    // Private DEBUG diagnostics only. Totals are cumulative for one core load,
    // including restore/warm-up frames; readback is nested inside coreRunMS.
    // Ten-second telemetry deltas separate steady play from first-frame setup.
#if DEBUG
    private static var clockHistogram=[Int](repeating:0,count:5)
    private static var clockGapMax=0.0,clockWorkMax=0.0
#endif
    static var runProfileMetrics:String {
#if DEBUG
        let value=veta_run_profile_snapshot()
        guard value.enabled else{return ""}
        func ms(_ ns:UInt64)->String {String(format:"%.3f",locale:Locale(identifier:"en_US_POSIX"),Double(ns)/1_000_000)}
        return ";runProfileVersion:1;coreRunCount:\(value.core_run_count);coreRunMS:\(ms(value.core_run_ns));hardwareBeginMS:\(ms(value.hardware_begin_ns))" +
            ";videoReadCount:\(value.video_read_count);videoReadFailures:\(value.video_read_failures);videoReadMS:\(ms(value.video_read_ns))" +
            ";queueSubmitCount:\(value.queue_submit_count);queueSubmitMS:\(ms(value.queue_submit_ns));queueWaitCount:\(value.queue_wait_count);queueWaitMS:\(ms(value.queue_wait_ns))" +
            ";callbackWaitCount:\(value.callback_wait_count);callbackWaitMS:\(ms(value.callback_wait_ns));queueLockCount:\(value.queue_lock_count);queueLockMS:\(ms(value.queue_lock_ns))" +
            ";cpuConvertCount:\(value.cpu_convert_count);cpuConvertMS:\(ms(value.cpu_convert_ns))" +
            ";clockTicks0:\(clockHistogram[0]);clockTicks1:\(clockHistogram[1]);clockTicks2:\(clockHistogram[2]);clockTicks3:\(clockHistogram[3]);clockTicks4:\(clockHistogram[4]);clockGapMaxMS:\(clockGapMax*1000);clockWorkMaxMS:\(clockWorkMax*1000)"
#else
        return ""
#endif
    }
    var volume: Float { Float(UserDefaults.standard.object(forKey:"native.volume") as? Double ?? 0.8) }
    init(game: Game, library: Library, plan: GameLaunchPlan? = nil) { self.game=game;self.library=library;self.plan=plan ?? GameLaunchPlan.capture(for:game,readiness:.capture(),library:library);super.init() }
    func open(screen: MetalScreen) {
        guard !opened else { return }
        if let blocker = plan.blocker { error = blocker; return }
        self.screen=screen
        if PlayTogether.shared.isHosting && PlayTogether.shared.console != game.console { PlayTogether.shared.stop() }
        guard screen.ready else { error="Metal no está disponible en este dispositivo."; return }
        let region: String,system:URL,saves:URL
        do { region = game.console == .nes ? Library.effectiveRegion(game, rom: try Data(contentsOf: library.romURL(game))):"Auto";system=try library.prepareSystem(for:game.console);saves=try library.prepareSessionSaves(for:game) }
        catch { self.error = error.localizedDescription; return }
        do {
            try FileManager.default.createDirectory(at:library.stateDirectory(game,plan:plan),withIntermediateDirectories:true)
            activeProfile = try GameProfileStore(library: library, game: game).resolved()
            // Preserve existing iNES header/name region detection when Auto is inherited.
            if activeProfile.values[CoreOptionID.nesRegion.rawValue] == "Auto" { activeProfile.values[CoreOptionID.nesRegion.rawValue] = region }
            try activeProfile.installForNextLoad()
        } catch { self.error = error.localizedDescription; return }
#if DEBUG
        let profile3DS=game.console == .threeDS && (ProcessInfo.processInfo.arguments.contains("--native-diagnostics") || ProcessInfo.processInfo.environment["VETA_PROFILE_3DS"] == "1")
        Self.clockHistogram=[Int](repeating:0,count:5);Self.clockGapMax=0;Self.clockWorkMax=0
        veta_run_profile_enable(profile3DS)
#else
        veta_run_profile_enable(false)
#endif
        guard veta_load_system_mode(library.romURL(game).path,saves.path,system.path,region,game.coreIndex,plan.isInterpreter) else {error="No se pudo abrir este juego de \(game.console.name). Comprueba el archivo y su compatibilidad.";return}
        opened=true;ready=true
        ControllerHub.shared.configure(console: game.console, maxPlayers: Int(veta_max_players(game.coreIndex)))
#if VETA_JIT_DEVELOPMENT
        telemetry("open")
#endif
        do {
            let ram=library.file(game,"battery.sav")
            // PSP saves live in its memory-stick filesystem. Older core builds
            // incorrectly advertised guest RAM as battery memory; retain any
            // legacy file on disk, but never apply it to the running PSP.
            if game.console != .psp, FileManager.default.fileExists(atPath:ram.path) {
                let data=try Data(contentsOf:ram)
                guard data.withUnsafeBytes({veta_write_ram($0.baseAddress,$0.count)}) else {throw VetaError.message("La memoria del cartucho no corresponde a este motor.")}
            }
            let rtc=library.file(game,"clock.rtc")
            if FileManager.default.fileExists(atPath:rtc.path) {
                let data=try Data(contentsOf:rtc)
                guard data.withUnsafeBytes({veta_write_rtc($0.baseAddress,$0.count)}) else{throw VetaError.message("El reloj guardado no corresponde a este cartucho.")}
            }
            try library.migrateLegacy3DSAuto(game,plan:plan,optionsFingerprint:activeOptionsFingerprint)
            if FileManager.default.fileExists(atPath:try saveStore.url("auto").path) { try restore("auto") }
        } catch { self.error=error.localizedDescription }
        if game.console == .nes {do {try NESCheat.install(nesCheats())}catch{self.error=error.localizedDescription}}
        // Automated replacement-core checks keep the user's play history intact.
        if !ProcessInfo.processInfo.arguments.contains("--commercial170-qa") {
            var updated=game;updated.lastPlayed=Date();library.update(updated)
        }
        let center=NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification,AVAudioSession.interruptionNotification,AVAudioSession.routeChangeNotification,NSNotification.Name.GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                if name == AVAudioSession.interruptionNotification,
                   (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                if name == AVAudioSession.routeChangeNotification,
                   (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) != AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { return }
                MainActor.assumeIsolated { self?.pause();self?.showMenu=true }
            })
        }
        if ProcessInfo.processInfo.arguments.contains("--native-diagnostics") { status="Diagnóstico disponible" }
        resume()
    }
    func setTouches(_ value: UInt16) { touchMask=value; updateInput() }
    func setTouchAnalog(_ index:Int,_ value:CGPoint) {guard (0..<2).contains(index) else{return};touchAnalog[index]=value;updateInput()}
    private func updateInput() {
        let inputs = ControllerHub.shared.inputs(console: game.console, touchMask: touchMask|heldButtons, touchAnalog: touchAnalog, running: running)
        for port in 0..<4 {
            let input = inputs.indices.contains(port) ? inputs[port] : ControllerInputState()
            veta_set_input(UInt32(port), running ? input.mask : 0)
            for stick in 0..<2 {
                let value = running && input.axes.indices.contains(stick) ? input.axes[stick] : .zero
                veta_set_analog(UInt32(port), UInt32(stick), Int16(max(-1,min(1,value.x))*32767), Int16(max(-1,min(1,value.y))*32767))
            }
        }
    }
    func setHeldButtons(_ value:UInt16) {heldButtons=value & GameplayControlPolicy.allowedHoldMask(game.console);updateInput()}
    func setFastForward(_ enabled:Bool) {
        guard opened,running,supportsFastForward,enabled != fastForward else{return}
        fastForward=enabled;fastClock.reset();accumulated=0;lastTime=0;pendingVideo=false
        frameCosts.removeAll();metricStart=CACurrentMediaTime();previousFrames=veta_frame_count()
        DevicePerformance.shared.end()
        if enabled {audio.stop();status="Avance 2× · sonido silenciado"}
        else {
            do {try audio.start(rate:veta_sample_rate(),volume:volume)}catch{self.error=error.localizedDescription;pause();showMenu=true;return}
            metricStart=CACurrentMediaTime();previousFrames=veta_frame_count()
            DevicePerformance.shared.begin(game:game);status="Velocidad normal"
        }
    }
    func resumeFastForward() {showMenu=false;resume();setFastForward(true)}
    private func clearGameplayControls() {fastForward=false;fastClock.reset();heldButtons=0}
    private var cheatStore:NESCheatStore {NESCheatStore(url:library.file(game,"cheats-nes.json"))}
    func nesCheats()throws->[NESCheat] {try cheatStore.read()}
    func applyNESCheats(_ list:[NESCheat])throws {
        guard opened,game.console == .nes else {throw VetaError.message("Los trucos todavía no están disponibles para este motor.")}
        let next=try NESCheat.validated(list),previous=try cheatStore.read()
        try NESCheat.install(next)
        do {try cheatStore.write(next)}catch {try? NESCheat.install(previous);throw error}
        status="Trucos NES actualizados"
    }
    func captureScreenshot()throws->URL {
        guard opened,let png=GameplayScreenshot.png() else {throw VetaError.message("Todavía no hay un cuadro del juego para capturar.")}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("VETA-Capturas",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url=folder.appendingPathComponent("VETA-"+UUID().uuidString+".png")
        try png.write(to:url,options:.atomic);return url
    }
    private func updateRumble() {
        for port in 0..<4 { ControllerHub.shared.applyRumble(port: port, strong: UInt16(veta_rumble_strength(UInt32(port), 0)), weak: UInt16(veta_rumble_strength(UInt32(port), 1))) }
    }
    private var audioClockActive=false
#if VETA_JIT_DEVELOPMENT
    private lazy var schedulingProbe = Veta165SchedulingProbe.make()
#endif
    private var usesOutputAudioClock:Bool {
        if NativeAudio.visualRenderProbe {return false}
        return [GameConsole.gamecube,.wii,.ps2,.psp,.threeDS].contains(game.console)
    }
    func resume() {
        guard opened,!running,UIApplication.shared.applicationState == .active else { return }
        // JIT cores have longer bursts after state restore and when warm.
        // Keep a bounded 80 ms reserve without changing their clock or pitch.
        do {try audio.start(rate:veta_sample_rate(),volume:volume,reserveDuration:usesOutputAudioClock || game.console.requiresJIT ? 0.08:0.04)} catch {self.error="Audio: \(error.localizedDescription)";return}
        audioClockActive=usesOutputAudioClock && veta_audio_count()>0
        running=true;DevicePerformance.shared.begin(game:game);lastTime=0;accumulated=0;pendingVideo=false;metricStart=CACurrentMediaTime();previousFrames=veta_frame_count();UIApplication.shared.isIdleTimerDisabled=true
        let link=CADisplayLink(target:self,selector:#selector(tick(_:)))
        link.preferredFrameRateRange=CAFrameRateRange(minimum:60,maximum:120,preferred:60)
        self.link=link;link.add(to:.main,forMode:.common)
#if VETA_JIT_DEVELOPMENT
        schedulingProbe?.beginSegment()
        telemetry("resume")
#endif
    }
    static func runFrame(console:GameConsole)->Double {
        let before=veta_audio_count()
        veta_run()
        // Flycast runs until a rendered frame, which may span multiple VBlanks.
        // Its generated audio measures that elapsed emulated time. Treating
        // every retro_run as exactly 1/fps makes audio accumulate and overflow.
        if console == .dreamcast {return Double(veta_audio_count()-before)/veta_sample_rate()}
        return 1/veta_fps()
    }
    @objc private func tick(_ link: CADisplayLink) {
        guard running else { return }
        if finishStoppedCore() {return}
#if VETA_JIT_DEVELOPMENT
        let schedulingStart = schedulingProbe == nil ? 0 : CACurrentMediaTime()
        let schedulingQueuedBefore = schedulingProbe == nil ? 0 : veta_audio_queued()
        let schedulingAudioClock = audioClockActive
        var schedulingPresentMS = 0.0
#endif
        let now=link.timestamp
        let observedDelta=lastTime == 0 ? 1/veta_fps() : now-lastTime
        let delta=min(observedDelta,0.1)
        lastTime=now;accumulated+=delta
        // A Flycast frame can represent a long emulated interval. Keep the
        // previous image until its audio interval has elapsed, instead of
        // displaying the future frame immediately while its sound is queued.
        if pendingVideo && accumulated>=0 {screen?.presentFrame();pendingVideo=false}
        let interval=1/veta_fps()
        var count=0
        updateInput()
        let started=CACurrentMediaTime()
        if fastForward {
            accumulated=0
            count=fastClock.advance(elapsed:delta,fps:veta_fps()){veta_run();veta_audio_clear()}
        } else if audioClockActive {
            // Fix the refill deficit at the start of this callback. Chasing
            // concurrent consumption batches frames and disrupts pacing.
#if VETA_JIT_DEVELOPMENT
            let snapshotBudget=NativeAudio.refillSnapshotBudget(console:game.console,override:NativeAudio.snapshotBudgetOverride)
            let maximumFrames=NativeAudio.refillFrameLimit(console:game.console,override:NativeAudio.refillFramesOverride)
            let hybridReadback=NativeAudio.usesHybridReadback(console:game.console,snapshotBudget:snapshotBudget,override:NativeAudio.readbackModeOverride)
            let readbackHint:((Bool)->Void)? = hybridReadback ? {veta_video_readback_hint($0)}:nil
            let refill=NativeAudio.refill(maximumFrames:maximumFrames,snapshotBudget:snapshotBudget,hintLastFrame:readbackHint)
#else
            let snapshotBudget=NativeAudio.refillSnapshotBudget(console:game.console)
            let hybridReadback=NativeAudio.usesHybridReadback(console:game.console,snapshotBudget:snapshotBudget)
            let readbackHint:((Bool)->Void)? = hybridReadback ? {veta_video_readback_hint($0)}:nil
            let refill=NativeAudio.refill(snapshotBudget:snapshotBudget,hintLastFrame:readbackHint)
#endif
            count=refill.frames;audioClockActive=refill.hasAudio;accumulated=0
        } else {
            let beforeAudio=veta_audio_count()
            while accumulated>=interval,count<4 {accumulated-=Self.runFrame(console:game.console);count+=1}
            if count==4 {accumulated=min(accumulated,interval)}
            // Some boot screens produce no samples. Keep their video clock
            // running, then follow the output clock once audio actually starts.
            if usesOutputAudioClock,veta_audio_count()>beforeAudio {audioClockActive=true;accumulated=0}
        }
#if VETA_JIT_DEVELOPMENT
        let schedulingWorkMS = schedulingProbe == nil ? 0 : (CACurrentMediaTime()-started)*1000
#endif
        if finishStoppedCore() {return}
        if count>0 {
            pendingVideo=game.console == .dreamcast && accumulated<0
#if VETA_JIT_DEVELOPMENT
            let schedulingPresentStart = schedulingProbe == nil ? 0 : CACurrentMediaTime()
#endif
            if !pendingVideo {screen?.presentFrame()}
#if VETA_JIT_DEVELOPMENT
            if schedulingProbe != nil { schedulingPresentMS = (CACurrentMediaTime()-schedulingPresentStart)*1000 }
#endif
            frameCosts.append((CACurrentMediaTime()-started)*1000/Double(count))
        }
#if DEBUG
        if game.console == .psp, ProcessInfo.processInfo.arguments.contains("--native-diagnostics"),
           observedDelta>0.08 || CACurrentMediaTime()-started>0.05 {
            print("PSP_SCHEDULING gap=\(observedDelta) work=\(CACurrentMediaTime()-started) frames=\(count) queued=\(veta_audio_queued()) missing=\(veta_audio_underruns())")
        }
#endif
#if DEBUG
        if game.console == .threeDS {
            Self.clockHistogram[min(4,count)]+=1
            Self.clockGapMax=max(Self.clockGapMax,observedDelta)
            Self.clockWorkMax=max(Self.clockWorkMax,CACurrentMediaTime()-started)
        }
#endif
        if NativeAudio.visualRenderProbe {veta_audio_clear()}
        updateRumble()
        if frameCosts.count>600 {frameCosts.removeFirst(frameCosts.count-600)}
        let metricNow=CACurrentMediaTime(),metricElapsed=metricNow-metricStart
        if metricElapsed>=1 {
            let currentFrames=veta_frame_count()
            let measuredFrames=currentFrames>=previousFrames ? currentFrames-previousFrames:0
            previousFrames=currentFrames;metricStart=metricNow
            // The simulation delta is capped to prevent catch-up bursts. It is
            // not elapsed wall time and overstates FPS when the core is slow.
            let fps=Double(measuredFrames)/metricElapsed
            let sorted=frameCosts.sorted();let p95=sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]
            if !fastForward {DevicePerformance.shared.sample(game:game,elapsed:metricElapsed,frames:measuredFrames,p95:p95,targetFPS:veta_fps(),audioMissing:veta_audio_underruns(),audioDropped:veta_audio_dropped())}
            diagnostics=(fastForward ? "2× · ":"")+String(format:"%.1f fps · p95 %.2f ms · %llu cuadros · audio %llu",fps,p95,veta_frame_count(),veta_audio_nonzero())
            screen?.accessibilityValue="frames:\(veta_frame_count());audio:\(veta_audio_nonzero());input:\(veta_input_mask(0))"
            if ProcessInfo.processInfo.arguments.contains("--native-diagnostics") {
                screen?.accessibilityValue = (screen?.accessibilityValue ?? "") + ";fpsTarget:\(veta_fps());sampleRate:\(veta_sample_rate());audioDelivered:\(veta_audio_delivered());audioUnderruns:\(veta_audio_underruns());audioDropped:\(veta_audio_dropped());audioProduced:\(veta_audio_count())"
            }
#if DEBUG
            if game.console == .threeDS {
                screen?.accessibilityValue=(screen?.accessibilityValue ?? "")+Self.runProfileMetrics
            }
#endif
        }
#if VETA_JIT_DEVELOPMENT
        if CACurrentMediaTime()-lastTelemetry>=10 {lastTelemetry=CACurrentMediaTime();telemetry("sample")}
#endif
        if veta_frame_count()-savedFrames>UInt64(veta_fps()*30) {
            savedFrames=veta_frame_count()
            do {try saveRAM()} catch {self.error=error.localizedDescription;pause();showMenu=true}
        }
#if VETA_JIT_DEVELOPMENT
        schedulingProbe?.record(start: schedulingStart, end: CACurrentMediaTime(), display: now,
                                displayGap: observedDelta, count: count, work: schedulingWorkMS,
                                present: schedulingPresentMS, queuedBefore: schedulingQueuedBefore,
                                queuedAfter: veta_audio_queued(), produced: veta_audio_count(),
                                delivered: veta_audio_delivered(), missing: veta_audio_underruns(),
                                dropped: veta_audio_dropped(), sampleRate: veta_sample_rate(), targetFPS: veta_fps(),
                                audioClock: schedulingAudioClock, visualProbe: NativeAudio.visualRenderProbe,
                                fastForward: fastForward, thermal: ProcessInfo.processInfo.thermalState.rawValue)
#endif
    }
    func pause() {
        clearGameplayControls()
        guard opened,running else {updateInput();return}
        running=false;link?.invalidate();link=nil;DevicePerformance.shared.end();audio.stop();lastTime=0
        if pendingVideo {screen?.presentFrame();pendingVideo=false}
        releaseTouches?();touchMask=0;touchAnalog=[.zero,.zero];ControllerHub.shared.releaseAll();veta_rumble_clear();updateInput()
        UIApplication.shared.isIdleTimerDisabled=false
#if VETA_JIT_DEVELOPMENT
        schedulingProbe?.flush(phase: "pause")
        telemetry("pause")
#endif
        do {try save("auto")} catch {self.error="No se pudo guardar al pausar: \(error.localizedDescription)"}
    }
    func openMenu() {pause();showMenu=true}
    func changeVolume(_ value: Double) {UserDefaults.standard.set(value,forKey:"native.volume");audio.setVolume(Float(value))}
    func saveRAM() throws {
        let rtcSize=veta_rtc_size()
        if rtcSize>0 {var data=Data(count:rtcSize);data.withUnsafeMutableBytes{veta_read_rtc($0.baseAddress,rtcSize)};try data.write(to:library.file(game,"clock.rtc"),options:.atomic)}
        let n=veta_ram_size();guard n>0 else {return}
        var data=Data(count:n);data.withUnsafeMutableBytes {veta_read_ram($0.baseAddress,n)}
        try data.write(to:library.file(game,"battery.sav"),options:.atomic)
    }
    private func captureState() throws -> Data {
        guard opened else { throw VetaError.message("Abre un juego primero.") }
        let count = veta_state_size()
        guard count > 0, count <= StateFile.maximumSize else { throw VetaError.message("El motor no ofrece un guardado de tamaño compatible.") }
        var data = Data(count: count)
        guard data.withUnsafeMutableBytes({ veta_save_state($0.baseAddress, count) }) else { throw VetaError.message("No se pudo obtener el estado.") }
        return data
    }
    func save(_ slot: String = "quick") throws {
        let data = try captureState()
        let encoded = try StateFile.encode(data, rom: game.id, core: plan.stateCoreID(for: game), optionsFingerprint: activeOptionsFingerprint, thumbnail: NativeSaveStore.thumbnail(), optionsSnapshot: activeProfile.values)
        try saveStore.write(encoded, slot: slot)
        try saveRAM(); status = slot == "auto" ? "Guardado automático listo" : "Partida guardada"
    }
    func restore(_ slot: String = "quick") throws {
        guard opened else { throw VetaError.message("Abre un juego primero.") }
        // Validate before changing the current session or creating a recovery copy.
        let data = try StateFile.decode(saveStore.read(slot), rom: game.id, core: plan.stateCoreID(for: game), optionsFingerprint: activeOptionsFingerprint)
        let wasRunning = running
        if wasRunning { pause() }
        // A snapshot or recovery-file write can fail before core mutation. Keep
        // the prior running state unless a rejected restore unloaded the core.
        defer { if wasRunning && opened && !running { resume() } }
        // Hardware-backed cores need bootstrapping before serializing/restoring.
        if game.console == .psp, veta_audio_count() == 0 {
            // PPSSPP boots asynchronously. Two polls cannot establish that the
            // renderer/memory exists, and the rollback snapshot would fail
            // before loading a perfectly valid automatic save.
            let deadline=Date().addingTimeInterval(30)
            while veta_audio_count()==0,Date()<deadline {
                veta_run()
                if veta_audio_count()==0 {Thread.sleep(forTimeInterval:0.001)}
            }
            guard veta_audio_count()>0 else {throw VetaError.message("No se pudo obtener el estado.")}
            veta_audio_clear()
        } else if NativeGameFile.consoles.contains(game.console), veta_frame_count() == 0 {
            veta_run(); veta_run(); veta_audio_clear()
        }
        let rollback = try captureState()
        let recovery = try StateFile.encode(rollback, rom: game.id, core: plan.stateCoreID(for: game), optionsFingerprint: activeOptionsFingerprint, thumbnail: NativeSaveStore.thumbnail(), optionsSnapshot: activeProfile.values)
        // When explicitly restoring the recovery slot, keep the requested bytes
        // already in memory; then retain the state we're about to leave.
        let recoveryURL = try saveStore.url("before-load")
        try recovery.write(to: recoveryURL, options: .atomic)
        guard try saveStore.read("before-load") == recovery else { throw VetaError.message("No se pudo verificar la copia previa a cargar.") }
        if !data.withUnsafeBytes({ veta_load_state($0.baseAddress, $0.count) }) {
            let recovered = rollback.withUnsafeBytes { veta_load_state($0.baseAddress, $0.count) }
            veta_audio_clear()
            if recovered {
                screen?.presentFrame(); if wasRunning { resume() }
                throw VetaError.message("El motor rechazó esta partida. Se recuperó tu sesión anterior.")
            }
            // Do not autosave a partially mutated core over the user's good slots.
            veta_unload(); opened=false; ready=false; ControllerHub.shared.releaseAll()
            throw VetaError.message("El motor rechazó la partida y no pudo recuperar la sesión en memoria. Cierra el juego; la copia «Antes de cargar» sigue guardada.")
        }
        veta_audio_clear(); lastTime=0; accumulated=0; pendingVideo=false
        savedFrames=veta_frame_count();previousFrames=savedFrames
        screen?.presentFrame();status="Partida cargada"
        if wasRunning { resume() }
#if VETA_JIT_DEVELOPMENT
        telemetry("restore")
#endif
    }
    var hasQuickSave: Bool {guard let url=try? saveStore.url("quick") else{return false};return FileManager.default.fileExists(atPath:url.path)}
    func reset() throws {
        guard opened else {throw VetaError.message("Abre un juego primero.")}
        if game.console == .gamecube || game.console == .wii {
            // Dolphin's reset callback only taps the console's reset switch;
            // homebrew may ignore it. Restart the core without restoring the
            // automatic state, preserving the quick save and game files.
            let saves=try library.prepareSessionSaves(for:game),system=try library.prepareSystem(for:game.console)
            pause();veta_unload();opened=false;ready=false
            try activeProfile.installForNextLoad()
            guard veta_load_system_mode(library.romURL(game).path,saves.path,system.path,"Auto",game.coreIndex,plan.isInterpreter) else {
                throw VetaError.message("No se pudo reiniciar el juego. Vuelve a la biblioteca e inténtalo otra vez.")
            }
            opened=true;ready=true;error=nil
            veta_run();veta_run();veta_audio_clear()
            savedFrames=veta_frame_count();previousFrames=savedFrames
            frameCosts.removeAll();lastTime=0;accumulated=0;pendingVideo=false
            screen?.presentFrame()
#if VETA_JIT_DEVELOPMENT
            telemetry("open")
#endif
            try save("auto")
        } else {veta_reset()}
        status="Juego reiniciado"
    }
    private func finishStoppedCore()->Bool {
        guard veta_shutdown_requested() else{return false}
        // A failed guest must not replace a good automatic save with its
        // incomplete state. Keep the library and all existing saves intact.
        close(saveProgress:false)
        error="El motor detuvo la ejecución."
        return true
    }
    func close(saveProgress:Bool=true) {
        clearGameplayControls();releaseTouches?();touchMask=0;touchAnalog=[.zero,.zero]
        // A failed restore may already have unloaded the core. Observers, audio
        // and external screens still need cleanup, without autosaving bad state.
        if opened {
            if saveProgress {
                if !running {do {try save("auto")} catch {self.error="No se pudo guardar al salir: \(error.localizedDescription)"}}
                pause()
            } else {link?.invalidate();link=nil;running=false;audio.stop()}
            veta_unload()
        }
        link?.invalidate();link=nil;running=false;DevicePerformance.shared.end();audio.stop()
        observers.forEach(NotificationCenter.default.removeObserver);observers=[]
        opened=false;ready=false;ControllerHub.shared.releaseAll();ExternalDisplayHub.shared.endGame()
        UIApplication.shared.isIdleTimerDisabled=false
#if VETA_JIT_DEVELOPMENT
        schedulingProbe?.flush(phase: "close")
        telemetry("close")
#endif
        try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
    }
    func report() throws -> URL {
        let value:[String:Any]=["core":game.coreID,"frames":veta_frame_count(),"audioFrames":veta_audio_count(),"nonzeroAudioFrames":veta_audio_nonzero(),"fpsTarget":veta_fps(),"sampleRate":veta_sample_rate(),"metrics":diagnostics,"thermalState":ProcessInfo.processInfo.thermalState.rawValue,"native":true,"optionsFingerprint":activeOptionsFingerprint,"options":activeProfile.values,"fastForward":fastForward,"heldButtons":heldButtons,"audioDelivered":veta_audio_delivered(),"audioUnderruns":veta_audio_underruns(),"audioDropped":veta_audio_dropped()]
        let url=library.root.appendingPathComponent("native-diagnostics.json")
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        status="Diagnóstico guardado";return url
    }
}
