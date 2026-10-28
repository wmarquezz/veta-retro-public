#if VETA_JIT_DEVELOPMENT
import Foundation
import Combine
import QuartzCore
import UIKit
import Darwin

#if DEBUG
/// Explicit QA only. Cumulative process CPU, not temperature in degrees or GPU energy.
/// Bounded sampling continues briefly after the engine closes to detect leaked work.
@MainActor private enum NativeResourceProbe {
    static var timer:Timer?
    static var phase="idle"
    static func threads()->[[String:Any]] {
        guard ProcessInfo.processInfo.environment["VETA_NATIVE_THREAD_PROBE"] == "1" else{return []}
        var list:thread_act_array_t?
        var count:mach_msg_type_number_t=0
        guard task_threads(mach_task_self_,&list,&count)==KERN_SUCCESS,let list else{return []}
        defer {vm_deallocate(mach_task_self_,vm_address_t(UInt(bitPattern:list)),vm_size_t(count)*vm_size_t(MemoryLayout<thread_t>.stride))}
        var rows=[[String:Any]]()
        for index in 0..<Int(count) {
            let thread=list[index]
            defer {mach_port_deallocate(mach_task_self_,thread)}
            var info=thread_extended_info()
            var size=mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size/MemoryLayout<natural_t>.size)
            let result=withUnsafeMutablePointer(to:&info) { pointer in
                pointer.withMemoryRebound(to:integer_t.self,capacity:Int(size)) {thread_info(thread,thread_flavor_t(THREAD_EXTENDED_INFO),$0,&size)}
            }
            guard result==KERN_SUCCESS else{continue}
            var identity=thread_identifier_info()
            var identitySize=mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size/MemoryLayout<natural_t>.size)
            let identified=withUnsafeMutablePointer(to:&identity) {pointer in
                pointer.withMemoryRebound(to:integer_t.self,capacity:Int(identitySize)) {thread_info(thread,thread_flavor_t(THREAD_IDENTIFIER_INFO),$0,&identitySize)}
            }
            guard identified==KERN_SUCCESS else{continue}
            let name=withUnsafeBytes(of:info.pth_name) {String(decoding:$0.prefix(while:{$0 != 0}),as:UTF8.self)}
            rows.append(["threadID":identity.thread_id,"port":thread,"name":name,"userNanoseconds":info.pth_user_time,"systemNanoseconds":info.pth_system_time,"cpuUsage":info.pth_cpu_usage,"runState":info.pth_run_state])
        }
        return rows
    }
    static func start() {
        guard ProcessInfo.processInfo.environment["VETA_NATIVE_RESOURCE_PROBE"] == "1",timer == nil else{return}
        let file=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("veta160-resource.jsonl")
        guard FileManager.default.createFile(atPath:file.path,contents:nil),let handle=try? FileHandle(forWritingTo:file) else{return}
        let deadline=ProcessInfo.processInfo.systemUptime+600
        timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { timer in
            MainActor.assumeIsolated {
                if ProcessInfo.processInfo.systemUptime>deadline {timer.invalidate();Self.timer=nil;try? handle.close();return}
                var usage=rusage()
                guard getrusage(RUSAGE_SELF,&usage)==0 else{return}
                func seconds(_ time:timeval)->Double {Double(time.tv_sec)+Double(time.tv_usec)/1_000_000}
                let row:[String:Any]=["uptime":ProcessInfo.processInfo.systemUptime,"phase":phase,"userCPU":seconds(usage.ru_utime),"systemCPU":seconds(usage.ru_stime),"thermal":ProcessInfo.processInfo.thermalState.rawValue,"pid":ProcessInfo.processInfo.processIdentifier,"threads":threads()]
                if let data=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) {try? handle.write(contentsOf:data+Data([10]))}
            }
        }
    }
}
#endif

struct NativeSessionCapabilities: Equatable {
    let raw:UInt32
    let maxPlayers:Int
    var pause:Bool {raw & 1 != 0}
    var input:Bool {raw & 2 != 0}
    var firmwareInstall:Bool {raw & 4 != 0}
    // Deliberately absent until a real engine contract supports them.
    var saveStates:Bool {raw & 16 != 0}
    var rumble:Bool {raw & 8 != 0}
    let externalDisplay=true
    var remoteControllers:Bool {input && maxPlayers>1}
}
@MainActor protocol NativeSession: AnyObject {
    var capabilities:NativeSessionCapabilities {get}
    func prepare(layer:CAMetalLayer)
    func start()
    func pause()
    func resume()
    func stop()
    func setTouches(_ mask:UInt16)
    func setAnalog(_ stick:Int,_ value:CGPoint)
    func updateDisplay(width:UInt32,height:UInt32,hz:Float)
}

// Only lifecycle work enters this queue. A lock protects pointer publication;
// boot never holds it, so UI display/input/snapshot cannot wait for boot.
private final class NativeEngineHost {
    private let queue:DispatchQueue
    private let snapshots:NativeSnapshotMailbox
    private let lock=NSLock()
    private var pointer:UnsafeMutableRawPointer?
    private var cancelled=false
    private var teardownError:String?
    let layer:CAMetalLayer
    private let initialWidth:UInt32
    private let initialHeight:UInt32
    // Failed destroy explicitly retains the host and CAMetalLayer until process
    // exit. Releasing a drawable surface underneath a live GPU thread is unsafe.
    private static let retainedLock=NSLock()
    private static var retained:[NativeEngineHost]=[]
    init(layer:CAMetalLayer) {
        let queue=DispatchQueue(label:"VETA.native.lifecycle",qos:.userInitiated)
        self.queue=queue;snapshots=NativeSnapshotMailbox(queue:queue)
        self.layer=layer;initialWidth=UInt32(max(1,layer.drawableSize.width));initialHeight=UInt32(max(1,layer.drawableSize.height))}
    private static func message(_ buffer:[CChar],fallback:String)->String {buffer.withUnsafeBufferPointer {p in p.baseAddress.map{String(cString:$0)}.flatMap{$0.isEmpty ? nil:$0} ?? fallback}}
    func create(engine:UInt32,frameworks:String,support:String,cache:String,system:String,allowJIT:Bool,interpreter:Bool,completion:@escaping(Result<Void,Error>)->Void) {
        queue.async { [self] in
            var error=[CChar](repeating:0,count:2048)
            let created=frameworks.withCString {f in support.withCString {s in cache.withCString {c in system.withCString {y in
                var config=VNGConfig();config.framework_directory=f;config.support_directory=s;config.cache_directory=c;config.system_directory=y;config.allow_jit_protocol=allowJIT;config.interpreter=interpreter
                return vng_create(engine,&config,&error,error.count)
            }}}}
            guard let created else {DispatchQueue.main.async {completion(.failure(VetaError.message(Self.message(error,fallback:"No se pudo inicializar el motor nativo."))))};return}
            lock.lock();let discard=cancelled;if !discard {pointer=created};lock.unlock()
            if discard {destroy(created);return}
            // The CAMetalLayer was configured on main before create; the bridge
            // only retains/attaches it. Geometry is supplied again by layout.
            vng_display(created,Unmanaged.passUnretained(layer).toOpaque(),initialWidth,initialHeight,60)
            DispatchQueue.main.async {completion(.success(()))}
        }
    }
    func perform(_ operation:@escaping(UnsafeMutableRawPointer,UnsafeMutablePointer<CChar>?,Int)->Bool,completion:@escaping(Result<Void,Error>)->Void) {
        snapshots.invalidate()
        queue.async { [self] in
            lock.lock();let p=cancelled ? nil:pointer;lock.unlock()
            guard let p else {DispatchQueue.main.async {completion(.failure(VetaError.message("El motor no está inicializado.")))};return}
            var error=[CChar](repeating:0,count:2048)
            let ok=operation(p,&error,error.count)
            let message=Self.message(error,fallback:"El motor no completó la operación.")
            DispatchQueue.main.async {completion(ok ? .success(()):.failure(VetaError.message(message)))}
        }
    }
    @discardableResult private func destroy(_ p:UnsafeMutableRawPointer)->String? {
        var error=[CChar](repeating:0,count:2048)
        _ = vng_stop(p,&error,error.count)
        if !vng_destroy(p,&error,error.count) {
            Self.retainedLock.lock();Self.retained.append(self);Self.retainedLock.unlock()
            let message=Self.message(error,fallback:"El motor no pudo detenerse. Cierra VETA antes de iniciar otro juego.")
            lock.lock();teardownError=message;lock.unlock()
            return message
        }
        return nil
    }
    func stop(completion:@escaping(String?)->Void) {
        lock.lock();cancelled=true;let p=pointer;pointer=nil;lock.unlock()
        snapshots.close()
        queue.async { [self] in
            if let p {_ = destroy(p)}
            lock.lock();let error=teardownError;lock.unlock()
            DispatchQueue.main.async {completion(error)}
        }
    }
    func display(width:UInt32,height:UInt32,hz:Float) {
        lock.lock();defer{lock.unlock()}
        if let p=pointer,!cancelled {vng_display(p,Unmanaged.passUnretained(layer).toOpaque(),width,height,hz)}
    }
    func imageFilter(_ value:UInt32? = nil)->Bool {
        lock.lock();defer{lock.unlock()}
        guard let p=pointer,!cancelled else{return false}
        return value.map{vng_set_image_filter(p,$0)} ?? vng_image_filter_supported(p)
    }
    func input(port:UInt32,value:VNGInput) {
        lock.lock();defer{lock.unlock()}
        if let p=pointer,!cancelled {var value=value;vng_input(p,port,&value)}
    }
    func feedback(port:UInt32)->VNGFeedback {
        lock.lock();defer{lock.unlock()};var value=VNGFeedback()
        if let p=pointer,!cancelled {vng_feedback(p,port,&value)}
        return value
    }
    func snapshot()->VNGSnapshot? {
        snapshots.value { [self] in
            // Executed after earlier boot/pause/resume tasks, never on main.
            // Stop detaches the pointer before queueing destroy; skip it then.
            lock.lock();let p=cancelled ? nil:pointer;lock.unlock()
            guard let p else{return nil}
            var value=VNGSnapshot();vng_snapshot(p,&value);return value
        }
    }
}

@MainActor final class NativeSessionModel:ObservableObject,NativeSession {
    typealias Phase=NativeLifecyclePolicy.Phase
    let game:Game
    let library:Library
    let plan:GameLaunchPlan
    let capabilities:NativeSessionCapabilities
    @Published private(set) var phase:Phase = .idle {
        didSet {
            #if DEBUG
            if game.console == .xbox {NativeResourceProbe.phase=String(describing:phase)}
            #endif
        }
    }
    @Published private(set) var status="Motor experimental"
    @Published var error:String?
    @Published var showMenu=false
    @Published private(set) var stateBusy=false
    @Published private(set) var stateNotice:String?
    private var host:NativeEngineHost?
    private var surface:CAMetalLayer?
    private var helperTimer:Timer?
    private var helperDeadline:TimeInterval=0
    private var helperRequested=false
    private var playWhenReady=false
    private var terminalStopError:String?
    private var importingSystem=false
    private var pendingImportClose:[(Bool)->Void]=[]
    private var timer:Timer?
    private var lastSnapshotTime:TimeInterval=0
    private var lastEngineState:UInt32=0
    private var pauseRequested=false
    private var interruptionMenu=NativeInterruptionMenuPolicy()
    private var recordedPlay=false
    private var observers:[NSObjectProtocol]=[]
    private var touchMask:UInt16=0
    private var analog:[CGPoint]=[.zero,.zero]
    var releaseTouches:(()->Void)?
    init(game:Game,library:Library,plan:GameLaunchPlan? = nil) {
        self.game=game;self.library=library;self.plan=plan ?? GameLaunchPlan.capture(for:game,readiness:.capture(),library:library)
        #if DEBUG
        if game.console == .xbox {NativeResourceProbe.start()}
        #endif
        let engine=game.console.nativeEngine ?? 0
        capabilities=NativeSessionCapabilities(raw:vng_capabilities(engine),maxPlayers:max(1,min(4,Int(vng_max_players(engine)))))
    }
    var needsHelper:Bool {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        return false
        #else
        return plan.requiresJIT && vng_needs_helper(game.console.nativeEngine ?? 0) && !ProcessInfo.processInfo.arguments.contains("--nextgen-jit-debugger")
        #endif
    }
    var executionNotice:String? {
        game.console == .xbox && plan.isInterpreter ? "Xbox sin conexión: la carga puede tardar varios minutos y la velocidad depende del juego. Máximo rendimiento está disponible en Ajustes. Cambiar el modo de Xbox requiere cerrar y volver a abrir VETA." : nil
    }
    var canPrepare:Bool {terminalStopError == nil && host == nil && (phase == .idle || phase == .failed)}
    var canStart:Bool {host != nil && lastEngineState==0 && (phase == .ready || phase == .failed)}
    var canInstallFirmware:Bool {capabilities.firmwareInstall && canStart}
    var canImportXboxSystem:Bool {game.console == .xbox && canPrepare}
    func prepare(layer:CAMetalLayer) {
        guard surface == nil else{return}
        surface=layer;status="Prepara el motor antes de iniciar el juego."
    }
    // Explicit game intent survives the helper round-trip, never app relaunch.
    // The original prepare controls remain available for firmware management.
    func play() {
        guard canPrepare || canStart else{return}
        playWhenReady=true
        if canStart {startRequestedGame()}
        else if needsHelper {activateHelper()}
        else {prepareEngine()}
    }
    private func startRequestedGame() {
        // Standalone engines enter their JIT protocol while starting the core.
        // Waiting for the helper's detach here would prevent that protocol
        // from ever running. The engine owns verification before guest code.
        guard playWhenReady,canStart,UIApplication.shared.applicationState == .active else{return}
        playWhenReady=false
        start()
    }
    func prepareEngine() {
        guard canPrepare,UIApplication.shared.applicationState == .active,let layer=surface else{return}
        guard !needsHelper else {fail("Activa este motor con el ayudante antes de prepararlo.");return}
        guard prewarm() else{return}
        initialize(layer:layer,allowJIT:plan.requiresJIT && ProcessInfo.processInfo.arguments.contains("--nextgen-jit-debugger"))
    }
    func activateHelper() {
        guard canPrepare,needsHelper,UIApplication.shared.applicationState == .active else{return}
        #if VETA_EMBEDDED_JIT
        guard prewarm() else{return}
        phase = .preparing;status="Preparando conexión y JIT dentro de VETA…";error=nil
        helperRequested=true
        helperDeadline=ProcessInfo.processInfo.systemUptime+180
        helperTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in MainActor.assumeIsolated {self?.pollHelper()} }
        EmbeddedJIT.shared.start { [weak self] result in
            guard let self,self.phase != .stopped,self.phase != .stopping else{return}
            switch result {
            case .success:self.startRequestedGame()
            case .failure(let error):
                self.helperTimer?.invalidate();self.helperTimer=nil;self.helperRequested=false
                self.fail(error.localizedDescription)
            }
        }
        #else
        guard let url=JITSession.helperDestination.activationURL(bundleID:Bundle.main.bundleIdentifier ?? "",pid:getpid()),UIApplication.shared.canOpenURL(url) else {fail("Configura VETA Connect para preparar este juego, o utiliza StikDebug con LocalDevVPN.");return}
        guard prewarm() else{return}
        phase = .preparing;status=L10n.format("Esperando a %@…",JITSession.helperName);error=nil
        UIApplication.shared.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self,self.phase == .preparing else{return}
                guard opened else {self.fail("No se pudo abrir el ayudante. Puedes volver a intentarlo.");return}
                self.helperRequested=true;self.helperDeadline=ProcessInfo.processInfo.systemUptime+180
                self.helperTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in MainActor.assumeIsolated {self?.pollHelper()} }
            }
        }
        #endif
    }
    // DukeX primes its signal-based coroutine pool before a debugger attaches.
    // This call is deliberately on MainActor, per the native engine contract.
    private func prewarm()->Bool {
        guard plan.console == game.console else {fail("El motor no está incluido en esta instalación.");return false}
        // The local route must not touch helper/VPN preparation. The adapter
        // verifies executionMode()==1 before initialization can skip JIT.
        guard !plan.requiresJIT || JITSession.shared.prepareStandalone() else {
            fail("Espera a que termine la preparación JIT actual antes de activar otro motor.");return false
        }
        var error=[CChar](repeating:0,count:512)
        let ready=vng_prewarm_mode(game.console.nativeEngine ?? 0,Bundle.main.privateFrameworksPath ?? "",plan.isInterpreter,&error,error.count)
        if !ready {fail(String(cString:error))}
        return ready
    }
    private func pollHelper() {
        guard helperRequested else{return}
        if ProcessInfo.processInfo.systemUptime>=helperDeadline {
            helperTimer?.invalidate();helperTimer=nil;helperRequested=false;fail("El ayudante no se conectó a este proceso. Revisa la conexión local y vuelve a intentarlo.");return
        }
        guard UIApplication.shared.applicationState == .active,veta_jit_debugger_attached(),let layer=surface else{return}
        helperTimer?.invalidate();helperTimer=nil;helperRequested=false
        initialize(layer:layer,allowJIT:true)
    }
    private func initialize(layer:CAMetalLayer,allowJIT:Bool) {
        guard UIApplication.shared.applicationState == .active else{return}
        guard let engine=game.console.nativeEngine else{return}
        guard vng_available(engine,Bundle.main.privateFrameworksPath ?? "") else {fail("El motor no está incluido o no es compatible con esta plataforma.");return}
        do {
            try ExperimentalGameContent.validate(library.romURL(game),console:game.console)
            let root=library.root.appendingPathComponent("NativeEngines/"+game.console.rawValue,isDirectory:true)
            let support=root.appendingPathComponent("Support"),cache=root.appendingPathComponent("Cache"),system=root.appendingPathComponent("System")
            for folder in [support,cache,system] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
            let host=NativeEngineHost(layer:layer);self.host=host;phase = .preparing;status="Preparando motor nativo…"
            UIApplication.shared.isIdleTimerDisabled=true
            observeApplicationLifecycle()
            traceLifecycle("prepare")
            host.create(engine:engine,frameworks:Bundle.main.privateFrameworksPath ?? "",support:support.path,cache:cache.path,system:system.path,allowJIT:allowJIT,interpreter:plan.isInterpreter) { [weak self] result in
                guard let self,self.phase != .stopping,self.phase != .stopped else{return}
                switch result {case .success:
                    self.lastEngineState=0;self.phase = .ready;self.status="Listo para iniciar";UIApplication.shared.isIdleTimerDisabled=false;self.traceLifecycle("prepared")
                    let size=layer.drawableSize;host.display(width:UInt32(max(1,size.width)),height:UInt32(max(1,size.height)),hz:60)
                    self.startRequestedGame()
                case .failure(let error):self.host=nil;self.fail(error.localizedDescription)}
            }
        } catch {fail(error.localizedDescription)}
    }
    var supportsImageFilters:Bool {game.console == .xbox && host?.imageFilter() == true}
    private func applyImageFilter()->Bool {
        guard supportsImageFilters else{return true}
        var mode:UInt32=VideoProfileStore(library:library,game:game).resolved().filter == .xbr ? 1:0
        #if DEBUG
        if let raw=ProcessInfo.processInfo.environment["VETA_XBOX_IMAGE_FILTER"],let probe=UInt32(raw),probe<=1 {mode=probe}
        #endif
        let accepted=host?.imageFilter(mode) == true
        #if DEBUG
        if ProcessInfo.processInfo.environment["VETA_XBOX_IMAGE_FILTER"] != nil {print("VETA160_XBOX_IMAGE_FILTER requested=\(mode) accepted=\(accepted)")}
        #endif
        if !accepted {error=L10n.text("No se pudo aplicar el filtro de imagen.")}
        return accepted
    }
    func start() {
        if let blocker = plan.blocker { error = L10n.text(blocker); return }
        guard canStart,UIApplication.shared.applicationState == .active,let host else{return}
        guard applyImageFilter() else{return}
        phase = .loading;error=nil;status="Iniciando juego…";recordedPlay=false;pauseRequested=false
        // Boot can compile for much longer than Auto-Lock. Protect this interval,
        // not just the later running phase; actual background still stops it.
        UIApplication.shared.isIdleTimerDisabled=true;traceLifecycle("boot-request")
        let path=library.romURL(game).path
        ControllerHub.shared.configure(console:game.console,maxPlayers:capabilities.maxPlayers)
        // Guests can enumerate pads and request rumble on their very first
        // instruction. Publish neutral connected ports before boot starts.
        releaseInput()
        // Remote/TV surfaces have no frame contract for these engines yet.
        PlayTogether.shared.stop()
        host.perform({p,e,n in path.withCString{vng_boot(p,$0,e,n)}}) { [weak self] result in
            guard let self,self.phase != .stopping,self.phase != .stopped else{return}
            self.traceLifecycle("boot-completed")
            switch result {
            case .success:
                // Boot acceptance precedes shader/PPU compilation. Only a real
                // VNG_RUNNING snapshot can mark this session as running.
                UIApplication.shared.isIdleTimerDisabled=true;self.beginPolling()
            case .failure(let error):self.operationFailed(error.localizedDescription)
            }
        }
    }
    private func traceLifecycle(_ event:String) {
        let entry="VETA_NATIVE_LIFECYCLE time=\(ProcessInfo.processInfo.systemUptime) console=\(game.console.rawValue) event=\(event) phase=\(phase) engine=\(lastEngineState) app=\(UIApplication.shared.applicationState.rawValue)"
        print(entry)
        // Keep low-frequency lifecycle evidence available even when a helper,
        // rather than Xcode, launched the app. No per-frame writes or game paths.
        let folder=library.root.appendingPathComponent("NativeEngines/"+game.console.rawValue,isDirectory:true)
        let file=folder.appendingPathComponent("lifecycle.log")
        do {try NativeLifecycleLog.append(entry,to:file)}
        catch {print("VETA_NATIVE_LIFECYCLE log unavailable")}
    }
    private func observeApplicationLifecycle() {
        guard observers.isEmpty else{return}
        for (name,event) in [(UIApplication.willResignActiveNotification,NativeLifecyclePolicy.Event.resignActive),(UIApplication.didEnterBackgroundNotification,.enterBackground)] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {self?.applicationLifecycle(event)}
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {self?.presentInterruptionMenuIfNeeded();self?.startRequestedGame()}
        })
    }
    private func presentInterruptionMenuIfNeeded() {
        if interruptionMenu.consume(foreground:UIApplication.shared.applicationState == .active,phase:phase,menuVisible:showMenu) {
            traceLifecycle("interruption-menu")
            showMenu=true
        }
    }
    func applicationLifecycle(_ event:NativeLifecyclePolicy.Event) {
        let action=NativeLifecyclePolicy.action(for:event,phase:phase,canPause:capabilities.pause)
        traceLifecycle("\(event):\(action)")
        switch action {
        case .releaseInput:releaseInput()
        case .pause:pause(interrupted:true)
        case .stop:stop(reason:"entered-background")
        }
    }
    private func beginPolling() {
        timer?.invalidate()
        let inputTimer=Timer(timeInterval:1/60,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {self?.poll()}
        }
        // Touch tracking must not suspend delivery of held buttons or releases.
        RunLoop.main.add(inputTimer,forMode:.common)
        timer=inputTimer
    }
    private func poll() {
        guard [.loading,.running,.paused].contains(phase),let host else{return}
        if capabilities.input {
            let values=ControllerHub.shared.inputs(console:game.console,touchMask:touchMask,touchAnalog:analog,running:phase == .running && !showMenu && UIApplication.shared.applicationState == .active)
            for port in 0..<min(values.count,capabilities.maxPlayers) {
                let input=values[port],l=input.axes[0],r=input.axes[1]
                var value=VNGInput();value.connected=ControllerHub.shared.isConnected(port:port) ? 1:0;value.buttons=input.mask;value.left_x=Float(l.x);value.left_y=Float(l.y);value.right_x=Float(r.x);value.right_y=Float(r.y);value.left_trigger=input.mask & (1<<12) != 0 ? 1:0;value.right_trigger=input.mask & (1<<13) != 0 ? 1:0
                host.input(port:UInt32(port),value:value)
                if capabilities.rumble {
                    let feedback=phase == .running && !showMenu ? host.feedback(port:UInt32(port)):VNGFeedback()
                    ControllerHub.shared.applyRumble(port:port,strong:feedback.strong,weak:feedback.weak)
                }
            }
        }
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastSnapshotTime>=0.25 else{return};lastSnapshotTime=now
        guard var snapshot=host.snapshot() else{return}
        let text=withUnsafePointer(to:&snapshot.message) {$0.withMemoryRebound(to:CChar.self,capacity:512){String(cString:$0)}}
        lastEngineState=snapshot.state
        switch snapshot.state {
        case 4:operationFailed(text.isEmpty ? "El motor detuvo la ejecución.":text)
        case 1:
            if phase != .loading {phase = .loading}
            let next=text.isEmpty ? "Iniciando juego…":text
            if status != next {status=next}
        case 2:
            if !pauseRequested && phase != .running {phase = .running}
            if !recordedPlay {
                recordedPlay=true
                var updated=library.games.first(where:{$0.id==game.id}) ?? game;updated.lastPlayed=Date();library.update(updated)
            }
            if snapshot.valid_fps != 0 {status=snapshot.frames>0 ? String(format:"%.1f fps · %llu cuadros",snapshot.fps,snapshot.frames):String(format:"%.1f fps",snapshot.fps)}
            else {status=text.isEmpty ? "Motor en ejecución":text}
        case 3:
            // Avoid publishing an identical pause state at 4 Hz while a system
            // menu or confirmation is being presented over this form.
            if phase != .paused {phase = .paused}
            if !text.isEmpty && status != text {status=text}
        case 0:
            timer?.invalidate();timer=nil;releaseInput();phase = .ready;status=text.isEmpty ? "El motor detuvo la ejecución.":text;UIApplication.shared.isIdleTimerDisabled=false
        default:break
        }
    }
    func setTouches(_ mask:UInt16) {touchMask=mask}
    func setAnalog(_ stick:Int,_ value:CGPoint) {if (0..<2).contains(stick){analog[stick]=value}}
    func updateDisplay(width:UInt32,height:UInt32,hz:Float) {host?.display(width:width,height:height,hz:hz)}
    private func releaseInput() {
        releaseTouches?();touchMask=0;analog=[.zero,.zero];ControllerHub.shared.releaseAll()
        for port in 0..<capabilities.maxPlayers {
            var value=VNGInput()
            // Releasing buttons is not unplugging the controller. Preserve
            // port identity through pause, helper transitions and resume.
            value.connected=ControllerHub.shared.isConnected(port:port) ? 1:0
            host?.input(port:UInt32(port),value:value)
        }
    }
    func pause() {pause(interrupted:false)}
    private func pause(interrupted:Bool) {
        traceLifecycle(interrupted ? "pause-interruption":"pause-request")
        releaseInput()
        if phase == .loading {stop(reason:"pause-during-loading");return}
        guard phase == .running,lastEngineState==2,let host else{return}
        guard capabilities.pause else {stop(reason:"pause-unsupported");return}
        if interrupted {interruptionMenu.request()}
        pauseRequested=true;phase = .paused;UIApplication.shared.isIdleTimerDisabled=false
        host.perform({vng_pause($0,$1,$2)}) { [weak self] result in
            guard let self,self.phase != .stopping,self.phase != .stopped else{return}
            switch result {
            case .failure(let error):self.interruptionMenu.cancel();self.operationFailed(error.localizedDescription)
            case .success:
                if interrupted {self.interruptionMenu.acknowledgePause();self.presentInterruptionMenuIfNeeded()}
            }
        }
    }
    static func quickStateFilename(for plan:GameLaunchPlan)->String {
        plan.console == .xbox && plan.isInterpreter ? "native-quick-tci-v1.vngstate":"native-quick.vngstate"
    }
    // Both manifests are preserved alongside each other. Their disk snapshots
    // stay in the existing System/QCOW2; changing execution mode does not clone
    // disks or EEPROM and must never load a state from the other backend.
    private var quickStateURL:URL {library.stateDirectory(game).appendingPathComponent(Self.quickStateFilename(for:plan))}
    var hasQuickState:Bool {FileManager.default.fileExists(atPath:quickStateURL.path)}
    var canUseStates:Bool {capabilities.saveStates && phase == .paused && lastEngineState == 3 && !stateBusy}
    func saveQuickState(){stateOperation(load:false)}
    func loadQuickState(){stateOperation(load:true)}
    private func stateOperation(load:Bool) {
        guard canUseStates,let host else{return}
        releaseInput();stateNotice=nil;stateBusy=true;status=load ? "Cargando partida…":"Guardando el juego…"
        do {try FileManager.default.createDirectory(at:quickStateURL.deletingLastPathComponent(),withIntermediateDirectories:true)}
        catch {stateBusy=false;self.error=error.localizedDescription;return}
        let path=quickStateURL.path
        host.perform({p,e,n in path.withCString {load ? vng_load_state(p,$0,e,n):vng_save_state(p,$0,e,n)}}) { [weak self] result in
            guard let self else{return};self.stateBusy=false
            guard self.phase == .paused else{return}
            switch result {
            case .success:
                // Engine telemetry refreshes status every quarter second. Keep
                // the save/load acknowledgement visible until the next action.
                self.stateNotice=load ? "Partida cargada":"Partida guardada"
            case .failure(let error):
                if self.host?.snapshot()?.state == 4 {self.operationFailed(error.localizedDescription)}
                else {self.error=error.localizedDescription;self.status="En pausa"}
            }
            self.traceLifecycle(load ? "quick-load":"quick-save")
        }
    }
    func resume() {
        guard phase == .paused,!stateBusy,let host,UIApplication.shared.applicationState == .active else{return}
        stateNotice=nil
        guard applyImageFilter() else{return}
        releaseInput()
        interruptionMenu.cancel()
        host.perform({vng_resume($0,$1,$2)}) { [weak self] result in
            guard let self,self.phase == .paused else{return}
            switch result {case .success:self.pauseRequested=false;self.lastSnapshotTime=0;UIApplication.shared.isIdleTimerDisabled=true;case .failure(let error):self.operationFailed(error.localizedDescription)}
        }
    }
    func openMenu() {
        guard phase == .running || phase == .paused else{return}
        if capabilities.pause {pause()} else {releaseInput()}
        // A core without pause keeps running while its menu is visible. Never
        // stop a one-session-per-process engine merely to change controls.
        showMenu=true
    }
    func importXboxSystem(_ source:URL) {
        guard canImportXboxSystem else{return}
        importingSystem=true;phase = .preparing;error=nil;status="Copiando firmware y disco Xbox…"
        let destination=library.root.appendingPathComponent("NativeEngines/xbox/System/xbox",isDirectory:true)
        Task { @MainActor [self] in
            let result=await Task.detached(priority:.userInitiated) {Result {try XboxSystemFiles.install(from:source,to:destination)}}.value
            importingSystem=false
            if phase == .stopping {
                phase = .stopped
                let completions=pendingImportClose;pendingImportClose=[]
                completions.forEach{$0(true)}
                return
            }
            switch result {
            case .success:phase = .idle;status="Archivos de sistema Xbox importados. Ya puedes preparar el motor."
            case .failure(let error):fail(error.localizedDescription)
            }
        }
    }
    func installFirmware(_ url:URL) {
        guard canInstallFirmware,let host else{return}
        let scoped=url.startAccessingSecurityScopedResource();phase = .preparing;status="Instalando firmware…"
        host.perform({p,e,n in url.path.withCString{vng_install_firmware(p,$0,e,n)}}) { [weak self] result in
            if scoped {url.stopAccessingSecurityScopedResource()}
            guard let self,self.phase != .stopping,self.phase != .stopped else{return}
            switch result {case .success:self.phase = .ready;self.status="Firmware instalado";case .failure(let error):self.fail(error.localizedDescription)}
        }
    }
    func stop() {stop(reason:"requested",completion:{_ in})}
    func stop(reason:String) {stop(reason:reason,completion:{_ in})}
    func stop(reason:String="requested",completion:@escaping(Bool)->Void) {
        playWhenReady=false
        traceLifecycle("stop-request:"+reason)
        interruptionMenu.cancel()
        if importingSystem {
            // Complete this transaction before dismissing the player. A new
            // session cannot open these files while their import is pending.
            pendingImportClose.append(completion);phase = .stopping;status="Cerrando motor…";return
        }
        if let terminalStopError {fail(terminalStopError);completion(false);return}
        if phase == .stopped {completion(true);return}
        guard phase != .stopping else{return}
        PlayTogether.shared.stop();releaseInput();helperTimer?.invalidate();helperTimer=nil;helperRequested=false;timer?.invalidate();timer=nil;observers.forEach(NotificationCenter.default.removeObserver);observers=[]
        UIApplication.shared.isIdleTimerDisabled=false;phase = .stopping;status="Cerrando motor…"
        guard let host else {ExternalDisplayHub.shared.endGame();phase = .stopped;completion(true);return}
        self.host=nil;host.stop { [weak self] error in
            if let error {self?.terminalStopError=error;self?.fail(error);completion(false)}
            else {ExternalDisplayHub.shared.endGame();self?.phase = .stopped;completion(true)}
        }
    }
    private func operationFailed(_ message:String) {
        guard phase != .stopping,phase != .stopped else{return}
        // Unknown or invalidated state must never authorize a second boot.
        lastEngineState=host?.snapshot()?.state ?? 4
        if lastEngineState==0 {fail(message)}
        else {error=message;stop(reason:"operation-failed")}
    }
    private func fail(_ message:String) {playWhenReady=false;interruptionMenu.cancel();timer?.invalidate();timer=nil;releaseInput();phase = .failed;error=message;status=message;UIApplication.shared.isIdleTimerDisabled=false}
}
#endif
