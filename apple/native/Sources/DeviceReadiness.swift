import SwiftUI
import Metal

/// Presence and prerequisites, not a prediction of game compatibility or frame rate.
struct DeviceReadiness {
    struct Snapshot: Equatable {
        var metalAvailable: Bool
        var physicalMemory: UInt64
        var processorCount: Int
        var osVersion: OperatingSystemVersion
        var simulator: Bool
        var jitAvailable: Bool
        var experimentalBuild: Bool
        var includedConsoles: Set<GameConsole>
        var includedDSEngines: Set<DSGameEngine> = [.desmume]
        var includedInterpreterConsoles: Set<GameConsole> = []
        var includedWebAssemblyConsoles: Set<GameConsole> = []
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.metalAvailable == rhs.metalAvailable && lhs.physicalMemory == rhs.physicalMemory && lhs.processorCount == rhs.processorCount && lhs.osVersion.majorVersion == rhs.osVersion.majorVersion && lhs.osVersion.minorVersion == rhs.osVersion.minorVersion && lhs.osVersion.patchVersion == rhs.osVersion.patchVersion && lhs.simulator == rhs.simulator && lhs.jitAvailable == rhs.jitAvailable && lhs.experimentalBuild == rhs.experimentalBuild && lhs.includedConsoles == rhs.includedConsoles && lhs.includedDSEngines == rhs.includedDSEngines && lhs.includedInterpreterConsoles == rhs.includedInterpreterConsoles && lhs.includedWebAssemblyConsoles == rhs.includedWebAssemblyConsoles
        }
    }
    enum Status: String, CaseIterable { case included, experimental, requiresJIT, unavailable }
    struct Assessment: Identifiable {
        let console: GameConsole
        let status: Status
        let reasons: [String]
        let canAttemptLaunch: Bool
        var id: String { console.rawValue }
        var title: String {
            switch status {
            case .included: return "Motor incluido"
            case .experimental: return "Experimental"
            case .requiresJIT: return "Requiere JIT"
            case .unavailable: return "No disponible"
            }
        }
    }
    struct Preflight {
        let assessment: Assessment
        let blockers: [String]
        let warnings: [String]
        var canLaunch: Bool { blockers.isEmpty && assessment.canAttemptLaunch }
    }
    let snapshot: Snapshot
    static func frameworkName(for console: GameConsole) -> String? {
        switch console {
        case .nes, .gb, .gbc, .gba: return nil
        case .snes: return "BSNESCore"
        case .megaDrive, .masterSystem, .gameGear: return "JGenesisCore"
        case .atari2600:
            #if VETA_ATARI_TIA
            return "TIACore"
            #else
            return "StellaCore"
            #endif
        case .pcEngine: return "PCECore"
        case .ps1: return "PlayStationCore"
        case .ds: return "DSCore"
        case .n64: return "N64NextCore"
        case .saturn: return "SaturnCore"
        case .psp: return "PSPCore"
        case .dreamcast: return "DreamcastCore"
        case .threeDS: return "ThreeDSCore"
        case .gamecube, .wii: return "DolphinCore"
        case .ps2: return "PS2Core"
        #if VETA_JIT_DEVELOPMENT
        case .ps3:return "rpcs3"
        case .xbox:return "DukeXCore"
        case .xbox360:return "XeniOSCore"
        #endif
        }
    }
    static func capture(bundle: Bundle = .main) -> Self {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        #if VETA_JIT_DEVELOPMENT
        let experimental = true
        let jit = veta_jit_available()
        #else
        let experimental = false
        let jit = false
        #endif
        let included = Set(GameConsole.allCases.filter { console in
            #if VETA_JIT_DEVELOPMENT
            if let engine=console.nativeEngine {return vng_available(engine,bundle.privateFrameworksPath ?? "")}
            #endif
            guard let name = frameworkName(for: console) else { return true }
            guard let root = bundle.privateFrameworksURL else { return false }
            return FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name).framework/\(name)").path)
        })
        let dsEngines = Set(DSGameEngine.allCases.filter { engine in
            guard let root = bundle.privateFrameworksURL else { return false }
            let name = engine == .melonDS ? "MelonDSCore" : "DSCore"
            return FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name).framework/\(name)").path)
        })
        let interpreters = Set(GameLaunchPlan.localInterpreterConsoles.filter { console in
            guard included.contains(console), let root = bundle.privateFrameworksURL else { return false }
            let name = console == .dreamcast ? "DreamcastInterpreterCore" : frameworkName(for: console)!
            return FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name).framework/\(name)").path)
        })
        var webAssembly:Set<GameConsole>=[]
        #if VETA_JIT_DEVELOPMENT
        if bundle.url(forResource:"Play",withExtension:"js",subdirectory:"PS2Wasm") != nil,
           bundle.url(forResource:"Play",withExtension:"wasm",subdirectory:"PS2Wasm") != nil {webAssembly.insert(.ps2)}
        if bundle.url(forResource:"flycast_libretro",withExtension:"js",subdirectory:"DreamcastWasm") != nil,
           bundle.url(forResource:"flycast_libretro",withExtension:"wasm",subdirectory:"DreamcastWasm") != nil {webAssembly.insert(.dreamcast)}
        #endif
        return Self(snapshot: Snapshot(metalAvailable: MTLCreateSystemDefaultDevice() != nil,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion, simulator: simulator,
            jitAvailable: jit, experimentalBuild: experimental, includedConsoles: included, includedDSEngines: dsEngines, includedInterpreterConsoles: interpreters,includedWebAssemblyConsoles:webAssembly))
    }
    func assess(console: GameConsole, plan: GameLaunchPlan? = nil) -> Assessment {
        let selected = plan ?? GameLaunchPlan.resolve(console: console, snapshot: snapshot)
        guard selected.console == console, GameConsole.allCases.contains(console) else {
            return Assessment(console: console, status: .unavailable, reasons: ["El motor no está incluido en esta instalación."], canAttemptLaunch: false)
        }
        if let blocker = selected.blocker {
            return Assessment(console: console, status: .unavailable, reasons: [blocker], canAttemptLaunch: false)
        }
        if !snapshot.includedConsoles.contains(console) {
            return Assessment(console: console, status: .unavailable, reasons: ["El motor no está incluido en esta instalación."], canAttemptLaunch: false)
        }
        let supportedOS = snapshot.osVersion.majorVersion > 16 || (snapshot.osVersion.majorVersion == 16 && snapshot.osVersion.minorVersion >= 4)
        if !snapshot.metalAvailable || !supportedOS {
            return Assessment(console: console, status: .unavailable, reasons: [!snapshot.metalAvailable ? "Metal no está disponible." : "Esta versión requiere iOS 16.4 o posterior."], canAttemptLaunch: false)
        }
        if console.isStandaloneEngine {
            return Assessment(console:console,status:.experimental,reasons:["Motor independiente experimental. Su inicialización verificará los requisitos reales de JIT y firmware.","Compatibilidad del juego no validada."],canAttemptLaunch:true)
        }
        if selected.mode == .webAssembly && !snapshot.includedWebAssemblyConsoles.contains(console) {
            return Assessment(console:console,status:.unavailable,reasons:["El motor sin conexión no está incluido en esta instalación."],canAttemptLaunch:false)
        }
        if selected.isInterpreter && !snapshot.includedInterpreterConsoles.contains(console) {
            return Assessment(console: console, status: .unavailable, reasons: ["El motor sin conexión no está incluido en esta instalación."], canAttemptLaunch: false)
        }
        if selected.isInterpreter && console == .dreamcast && (snapshot.osVersion.majorVersion < 17 || (snapshot.osVersion.majorVersion == 17 && snapshot.osVersion.minorVersion < 4)) {
            return Assessment(console: console, status: .unavailable, reasons: ["El motor sin conexión de Dreamcast requiere iOS 17.4 o posterior."], canAttemptLaunch: false)
        }
        if selected.requiresJIT && !snapshot.simulator && (!snapshot.experimentalBuild || !snapshot.jitAvailable) {
            return Assessment(console: console, status: .requiresJIT, reasons: ["El motor está incluido, pero JIT no está activo para este proceso."], canAttemptLaunch: false)
        }
        let experimental = selected.requiresJIT || selected.isInterpreter || [.threeDS, .saturn, .n64, .psp].contains(console)
        return Assessment(console: console, status: experimental ? .experimental : .included,
            reasons: ["Compatibilidad del juego no validada.", snapshot.simulator ? "El simulador no acredita rendimiento en un iPhone." : "La velocidad depende del juego, del dispositivo y de su temperatura."] + (selected.notice.map { [$0] } ?? []), canAttemptLaunch: true)
    }
    func assess(game: Game, plan: GameLaunchPlan? = nil) -> Assessment {
        guard game.console == .ds else { return assess(console: game.console, plan: plan) }
        // The selected core is independent of the default DS framework. Presence
        // of DeSmuME must not hide a missing melonDS build (or the reverse).
        var selected = snapshot
        if snapshot.includedDSEngines.contains(game.dsEngine) { selected.includedConsoles.insert(.ds) }
        else { selected.includedConsoles.remove(.ds) }
        let base = Self(snapshot: selected).assess(console: .ds)
        guard base.canAttemptLaunch, game.dsEngine == .melonDS else { return base }
        guard snapshot.osVersion.majorVersion >= 17 else {
            return Assessment(console: .ds, status: .unavailable, reasons: ["melonDS DS requiere iOS 17 o posterior."], canAttemptLaunch: false)
        }
        return Assessment(console: .ds, status: .experimental,
            reasons: base.reasons + ["melonDS DS está en evaluación; Flappy pasó las pruebas locales de sonido. El rendimiento en este dispositivo aún debe comprobarse."], canAttemptLaunch: true)
    }
    @MainActor func preflight(game: Game, library: Library, plan: GameLaunchPlan? = nil) -> Preflight {
        let selected = plan ?? GameLaunchPlan.capture(for: game, readiness: self, library: library)
        return preflight(console: game.console, gameURL: library.romURL(game), systemDirectory: library.root.appendingPathComponent("System"), selectedAssessment: assess(game: game, plan: selected))
    }
    func preflight(console: GameConsole, gameURL: URL, systemDirectory: URL, selectedAssessment: Assessment? = nil) -> Preflight {
        let assessment = selectedAssessment ?? assess(console: console)
        var blockers = assessment.canAttemptLaunch ? [] : assessment.reasons
        var warnings = assessment.canAttemptLaunch ? assessment.reasons : ["Compatibilidad del juego no validada."]
        #if VETA_JIT_DEVELOPMENT
        if console.isStandaloneEngine {
            do {try ExperimentalGameContent.validate(gameURL,console:console)} catch {blockers.append(error.localizedDescription)}
            warnings.append("No hay estados rápidos ni vídeo remoto para este motor. La TV y los mandos cercanos requieren dispositivos compatibles.")
            return Preflight(assessment:assessment,blockers:blockers,warnings:warnings)
        }
        #endif
        do {
            // Re-stat on every attempt; URL resource-value caching can retain a
            // zero size after a game is copied or repaired at the same URL.
            let info = try FileManager.default.attributesOfItem(atPath: gameURL.path)
            let size = (info[.size] as? NSNumber)?.uint64Value ?? 0
            if (info[.type] as? FileAttributeType) != .typeRegular || size == 0 { blockers.append("El archivo del juego está vacío o no es un archivo regular.") }
        } catch { blockers.append("No se puede leer el archivo del juego.") }
        // Firmware validation remains in Library.prepareSystem; this probe does not
        // copy files, create folders or declare a merely present BIOS valid.
        if console == .saturn {
            warnings.append("Saturn requiere una BIOS válida; se verificará antes de iniciar.")
        }
        if console.requiresJIT && snapshot.physicalMemory < 4 * 1024 * 1024 * 1024 {
            warnings.append("La memoria total es limitada para este motor; no equivale a memoria disponible.")
        }
        return Preflight(assessment: assessment, blockers: blockers, warnings: warnings)
    }
}

struct DeviceReadinessView: View {
    @State private var readiness = DeviceReadiness.capture()
    private var alternateDS: DeviceReadiness.Assessment {
        var game = Game(id: "readiness-ds", name: "", console: .ds); game.dsEngine = .melonDS
        return readiness.assess(game: game)
    }
    var body: some View {
        List {
            Section("Este dispositivo") {
                NavigationLink("Rendimiento observado") { PerformanceHistoryView() }.accessibilityIdentifier("performance-history")
                LabeledContent("Metal", value: L10n.text(readiness.snapshot.metalAvailable ? "Disponible" : "No disponible"))
                LabeledContent("Memoria total", value: ByteCountFormatter.string(fromByteCount: Int64(readiness.snapshot.physicalMemory), countStyle: .memory))
                LabeledContent("Procesadores activos", value: String(readiness.snapshot.processorCount))
                LabeledContent("Sistema", value: "\(readiness.snapshot.osVersion.majorVersion).\(readiness.snapshot.osVersion.minorVersion).\(readiness.snapshot.osVersion.patchVersion)")
                Text("Estos datos no garantizan velocidad ni compatibilidad con todos los juegos.").font(.caption)
            }.listRowBackground(VetaTheme.panel)
            Section("Motores y requisitos") {
                ForEach(GameConsole.chronological) { console in
                    let assessment = readiness.assess(console: console)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(console.name); Spacer(); Text(LocalizedStringKey(assessment.title)).font(.caption).foregroundStyle(assessment.canAttemptLaunch ? VetaTheme.mint : VetaTheme.orange) }
                        Text(console.coreID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        ForEach(assessment.reasons, id: \.self) { Text(LocalizedStringKey($0)).font(.caption).foregroundStyle(.secondary) }
                    }.accessibilityIdentifier("readiness-\(console.rawValue)")
                }
            }.listRowBackground(VetaTheme.panel)
            Section("Motores alternativos") {
                HStack { Text(verbatim: "melonDS DS"); Spacer(); Text(LocalizedStringKey(alternateDS.title)).font(.caption) }
                ForEach(alternateDS.reasons, id: \.self) { Text(LocalizedStringKey($0)).font(.caption).foregroundStyle(.secondary) }
            }.listRowBackground(VetaTheme.panel)
        }.vetaForm().tint(VetaTheme.mint).navigationTitle("Compatibilidad del dispositivo")
            .toolbar { Button("Actualizar") { readiness = .capture() }.accessibilityIdentifier("refresh-readiness") }
    }
}
