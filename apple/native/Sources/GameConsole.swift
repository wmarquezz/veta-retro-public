import Foundation
import CoreGraphics

enum GameConsole:String,Codable,CaseIterable,Identifiable {
    case nes,snes,gb,gbc,gba,n64,ds,threeDS,gamecube,wii,ps1,ps2,psp,megaDrive,masterSystem,gameGear,saturn,dreamcast,atari2600,pcEngine
    #if VETA_JIT_DEVELOPMENT
    case ps3, xbox, xbox360
    #endif
    // Retain decoding of retired consoles to preserve existing library files.
    // Xbox, PS3 and Xbox 360 are excluded at the user's request (161).
    static var allCases:[Self] {
        let consoles:[Self]=[.nes,.snes,.gb,.gbc,.gba,.n64,.ds,.threeDS,.gamecube,.wii,.ps1,.ps2,.psp,.megaDrive,.masterSystem,.gameGear,.saturn,.dreamcast,.atari2600,.pcEngine]
        #if VETA_JIT_DEVELOPMENT
        return consoles
        #else
        return consoles.filter { $0 != .ps2 }
        #endif
    }
    var maximumPlayers:Int {
        guard Self.allCases.contains(self) else{return 1}
        #if VETA_JIT_DEVELOPMENT
        if let engine=nativeEngine {return max(1,min(4,Int(vng_max_players(engine))))}
        #endif
        return max(1,min(4,Int(veta_max_players(coreIndex))))
    }
    var nativeEngine:UInt32? {
        #if VETA_JIT_DEVELOPMENT
        switch self {case .ps3:return 1;case .xbox:return 2;case .xbox360:return 3;default:return nil}
        #else
        return nil
        #endif
    }
    var isStandaloneEngine:Bool {nativeEngine != nil}
    var isPlayStationController:Bool {
        #if VETA_JIT_DEVELOPMENT
        if self == .ps3 {return true}
        #endif
        return [.ps1,.ps2,.psp].contains(self)
    }
    var id:String {rawValue}
    var name:String {
        switch self {
        #if VETA_JIT_DEVELOPMENT
        case .ps3:return "PlayStation 3";case .xbox:return "Xbox";case .xbox360:return "Xbox 360"
        #endif
        case .nes:return "NES";case .snes:return "SNES";case .gb:return "Game Boy";case .gbc:return "Game Boy Color";case .gba:return "Game Boy Advance"
        case .n64:return "Nintendo 64";case .ds:return "Nintendo DS";case .threeDS:return "Nintendo 3DS";case .gamecube:return "GameCube";case .wii:return "Wii"
        case .ps1:return "PlayStation";case .ps2:return "PlayStation 2";case .psp:return "PSP"
        case .megaDrive:return "Mega Drive";case .masterSystem:return "Master System";case .gameGear:return "Game Gear";case .saturn:return "Saturn";case .dreamcast:return "Dreamcast"
        case .atari2600:return "Atari 2600";case .pcEngine:return "PC Engine"
        }
    }
    var year:Int {switch self {
        #if VETA_JIT_DEVELOPMENT
        case .ps3:return 2006;case .xbox:return 2001;case .xbox360:return 2005
        #endif
        case .atari2600:return 1977;case .nes:return 1983;case .masterSystem:return 1985;case .pcEngine:return 1987;case .megaDrive:return 1988;case .gb:return 1989;case .snes,.gameGear:return 1990;case .ps1,.saturn:return 1994;case .n64:return 1996;case .gbc,.dreamcast:return 1998;case .ps2:return 2000;case .gba,.gamecube:return 2001;case .ds,.psp:return 2004;case .wii:return 2006;case .threeDS:return 2011}}
    static var chronological:[Self] {allCases.sorted { $0.year == $1.year ? $0.name < $1.name:$0.year < $1.year }}
    var preferencePrefix:String {self == .nes ? "native.":"native.\(rawValue)."}
    var shortName:String {switch self {case .gb:return "GB";case .gbc:return "GBC";case .gba:return "GBA";case .threeDS:return "3DS";case .ps1:return "PS1";case .ps2:return "PS2";case .ds:return "DS";case .n64:return "N64";default:return name}}
    var usesSharedJITPool:Bool {
        #if VETA_JIT_DEVELOPMENT
        if self == .threeDS {return true}
        #endif
        return [.dreamcast,.gamecube,.wii,.ps2].contains(self)
    }
    var requiresJIT:Bool {isStandaloneEngine || usesSharedJITPool}
    var playable:Bool {
        guard Self.allCases.contains(self) else{return false}
        #if VETA_JIT_DEVELOPMENT
        if let engine=nativeEngine {
            guard vng_available(engine,Bundle.main.privateFrameworksPath ?? "") else{return false}
            // These cores validate their own JIT mode during initialization.
            // VETA's libretro allocation pool does not prove their JIT works.
            return true
        }
        #endif
        #if targetEnvironment(simulator)
        return true
        #elseif VETA_JIT_DEVELOPMENT
        return GameLaunchPlan.localInterpreterConsoles.contains(self) || !requiresJIT || (veta_jit_available() && usesSharedJITPool)
        #else
        return GameLaunchPlan.localInterpreterConsoles.contains(self) || !requiresJIT
        #endif
    }
    var coreIndex:UInt32 {switch self {
        #if VETA_JIT_DEVELOPMENT
        case .ps3:return 101;case .xbox:return 102;case .xbox360:return 103
        #endif
        case .nes:return 0;case .snes:return 1;case .gb:return 2;case .gbc:return 3;case .gba:return 4;case .megaDrive:return 5;case .masterSystem:return 6;case .gameGear:return 7;case .atari2600:return 8;case .pcEngine:return 9;case .ps1:return 10;case .ds:return 11;case .n64:return 12;case .saturn:return 13;case .psp:return 14;case .dreamcast:return 15;case .threeDS:return 16;case .gamecube:return 17;case .wii:return 18;case .ps2:return 19}}
    var coreID:String {
        #if VETA_ATARI_TIA
        if self == .atari2600 {return "tia-6ae5bf99-veta176-v1"}
        #endif
        switch self {
        #if VETA_JIT_DEVELOPMENT
        case .ps3:return "rpcs3-ios-native-v1";case .xbox:return "dukex-native-v1";case .xbox360:return "xenios-native-v1"
        #endif
        case .nes:return StateFile.coreID;case .snes:return "bsnes-mercury-79d7f9de-perf-v1";case .gb,.gbc,.gba:return "mgba-0.10.5-v1";case .megaDrive,.masterSystem,.gameGear:return "jgenesis-0a00c47b-veta170-v1";case .atari2600:return "stella2014-7d1361e4-v1";case .pcEngine:return "pce-fast-4eee99c4-v1";case .ps1:return "pcsx-c8816799-interpreter-v1";case .ds:return "desmume-95b4d798-v1";case .saturn:return "beetle-saturn-d0d84178-v1";case .n64:return "mupen-next-15bada85-v1";case .psp:return "ppsspp-31e94fcf-v1";case .dreamcast:return "flycast-6d81b998-v1";case .threeDS:return "azahar-93f8939a-v1";case .gamecube,.wii:return "dolphin-3aac3f05-v1";case .ps2:return "play-505dac73-v1"}}
    var aspect:CGFloat {
        #if VETA_JIT_DEVELOPMENT
        if self == .xbox {return 4/3}
        #endif
        if isStandaloneEngine{return 16/9};switch self {case .gb,.gbc,.gameGear:return 160/144;case .gba:return 240/160;case .ds:return 256/384;case .threeDS:return 400/480;case .psp:return 480/272;default:return 4/3}}
    var romExtension:String {switch self {case .snes:return "sfc";case .gb:return "gb";case .gbc:return "gbc";case .gba:return "gba";case .megaDrive:return "md";case .masterSystem:return "sms";case .gameGear:return "gg";case .atari2600:return "a26";case .pcEngine:return "pce";case .ps1:return "exe";case .ds:return "nds";default:return "nes"}}
    var analogSticks:Int {isStandaloneEngine ? 2:[.ps2,.gamecube,.wii].contains(self) ? 2:[.n64,.psp,.dreamcast,.threeDS].contains(self) ? 1:0}
    var minimumDeck:CGFloat {analogSticks>0 ? 320:fourButtons || self == .megaDrive || self == .saturn ? 250:210}
    var shoulders:Bool {isStandaloneEngine || [.snes,.gba,.ds,.threeDS,.gamecube,.ps1,.ps2,.psp,.saturn,.dreamcast,.n64,.wii].contains(self)}
    var fourButtons:Bool {isStandaloneEngine || [.snes,.ds,.threeDS,.gamecube,.ps1,.ps2,.psp,.saturn,.dreamcast].contains(self)}
    var color:UInt32 {
        switch self {case .gb:return 0xc6c5a9;case .gbc:return 0x6863ab;case .gba:return 0x6555a5;case .snes:return 0xaba6b8;case .gamecube:return 0x584b9b;case .threeDS:return 0x276f9c;case .ds:return 0xe1e2e3;case .ps1:return 0xb5b7b8;case .ps2,.psp,.megaDrive,.masterSystem,.saturn:return 0x303641;case .n64:return 0x444b4b;case .dreamcast,.wii,.pcEngine:return 0xe3e1d8;case .gameGear:return 0x363b4c;case .atari2600:return 0x9a653e;default:return 0xc8cbc9}
    }
    var availability:String {if isStandaloneEngine || self == .threeDS {return playable ? "Motor experimental disponible":"Motor experimental no disponible"};return playable ? "Motor nativo incluido":"Requiere JIT en iPhone"}
    var detail:String {
        if isStandaloneEngine {return "Laboratorio: compatibilidad y rendimiento en evaluación. Las opciones disponibles dependen del motor."}
        if !playable {return "Motor incluido. En iPhone necesita una sesión con JIT activo; la compatibilidad y velocidad dependen del juego."}
        if self == .saturn {return "Importa el CUE junto con sus pistas BIN o WAV. Requiere BIOS en VETA-Retro → Saturn → BIOS."}
        if self == .threeDS {return "Motor experimental: algunos juegos 3DS funcionan con lentitud. Admite 3DSX e imágenes CCI/3DS/CXI descifradas."}
        if self == .psp {return "Importa ISO, CSO, PBP o PRX. Palanca analógica y partidas guardadas incluidos."}
        if self == .dreamcast {return "Importa CDI, CHD o ejecutables ELF. Motor Flycast con arranque HLE."}
        if self == .gamecube || self == .wii {return "Importa ISO, GCM, RVZ, WBFS o DOL de esta consola. La compatibilidad y velocidad dependen del juego."}
        if self == .ps2 {return "Importa ISO o ELF. El motor Play! utiliza un sistema HLE y no requiere BIOS."}
        return "Importa tus juegos y juega sin conexión."
    }

    func buttonMask(_ name:String)->UInt16 {
        let map:[String:Int]
        if self == .saturn {map=["A":0,"B":8,"C":11,"X":1,"Y":9,"Z":10,"START":3,"L":12,"R":13]}
        else if self == .megaDrive {map=["A":1,"B":0,"C":8,"X":10,"Y":9,"Z":11,"START":3,"SELECT":2,"L":12,"R":13]}
        else if self == .n64 {map=["A":0,"B":1,"C↑":9,"C↓":8,"C←":10,"C→":11,"L":2,"R":13,"Z":12,"START":3]}
        else if self == .gamecube {map=["A":8,"B":0,"X":9,"Y":1,"L":12,"R":13,"Z":11,"START":3]}
        else if self == .dreamcast {map=["A":0,"B":8,"X":1,"Y":9,"L":12,"R":13,"L2":12,"R2":13,"START":3]}
        else if self == .wii {map=["A":8,"B":0,"C":9,"Z":1,"1":3,"2":2,"−":10,"+":11,"HOME":14,"SHAKE":13]}
        else if self == .atari2600 {map=["A":0,"START":3,"SELECT":2]}
        else {map=["A":8,"B":0,"X":9,"Y":1,"L":10,"R":11,"L2":12,"R2":13,"L3":14,"R3":15,"START":3,"SELECT":2]}
        if name == "A+B" {return buttonMask("A") | buttonMask("B")}
        return map[name].map{UInt16(1 << $0)} ?? 0
    }
    static func detect(_ data:Data,extension ext:String,preferred:Self? = nil)throws->Self {
        if data.starts(with:[0x4e,0x45,0x53,0x1a]) {return .nes}
        switch ext.lowercased() {
        case "sfc","smc":return .snes
        case "gb","gbc":guard data.count>0x143 else{throw VetaError.message("La ROM Game Boy está incompleta.")};return data[0x143]&0x80 != 0 ? .gbc:.gb
        case "gba":return .gba
        case "md","gen":return .megaDrive
        case "sms":return .masterSystem
        case "gg":return .gameGear
        case "a26":return .atari2600
        case "pce":return .pcEngine
        case "nds":return .ds
        case "exe":return .ps1
        case "cue":throw VetaError.message("Selecciona el CUE junto con todas sus pistas BIN.")
        case "chd","pbp","m3u":throw VetaError.message("Esta versión admite PlayStation en CUE + BIN o PS-X EXE. Este formato todavía no está habilitado.")
        case "bin":
            if data.count>0x104,Data(data[0x100..<0x104])==Data("SEGA".utf8){return .megaDrive}
            if let preferred,[Self.ps1,.atari2600,.megaDrive].contains(preferred){return preferred}
            throw VetaError.message("Este .bin es ambiguo. Selecciona primero su consola en la biblioteca.")
        default:throw VetaError.message("Selecciona una ROM de las consolas con motor incluido. Los archivos ZIP deben descomprimirse primero.")
        }
    }
}
