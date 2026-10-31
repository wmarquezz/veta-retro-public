import Foundation
import CryptoKit
import Compression

enum DSGameEngine: String, Codable, CaseIterable, Identifiable {
    case desmume, melonDS
    var id:String {rawValue}
    var name:String {self == .desmume ? "DeSmuME" : "melonDS DS"}
}
struct Game: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var favorite = false
    var lastPlayed: Date?
    var importedAt = Date()
    var region = "Auto"
    var console:GameConsole = .nes
    var contentName:String? = nil
    var guide:GameGuide? = nil
    var videoPresentation:VideoPresentation? = nil
    var dsEngine:DSGameEngine = .desmume
    var coreIndex:UInt32 {console == .ds && dsEngine == .melonDS ? 20:console.coreIndex}
    var coreID:String {console == .ds && dsEngine == .melonDS ? "melonds-ds-f394adba-16f127db-v2":console.coreID}
    enum CodingKeys:String,CodingKey {case id,name,favorite,lastPlayed,importedAt,region,console,contentName,dsEngine,guide,videoPresentation}
    init(id:String,name:String,console:GameConsole = .nes) {self.id=id;self.name=name;self.console=console}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        favorite=try c.decodeIfPresent(Bool.self,forKey:.favorite) ?? false
        lastPlayed=try c.decodeIfPresent(Date.self,forKey:.lastPlayed)
        importedAt=try c.decodeIfPresent(Date.self,forKey:.importedAt) ?? Date()
        region=try c.decodeIfPresent(String.self,forKey:.region) ?? "Auto"
        console=try c.decodeIfPresent(GameConsole.self,forKey:.console) ?? .nes
        contentName=try c.decodeIfPresent(String.self,forKey:.contentName)
        dsEngine=try c.decodeIfPresent(DSGameEngine.self,forKey:.dsEngine) ?? .desmume
        // Bad optional web metadata must not make the game library unreadable.
        guide=try? c.decode(GameGuide.self,forKey:.guide)
        videoPresentation=(try? c.decode(VideoPresentation.self,forKey:.videoPresentation))?.validated(for:console)
        if let contentName,contentName.contains("/") || contentName.contains("\\") || contentName==".." {throw VetaError.message("Nombre de archivo inválido en la biblioteca.")}
    }
}
enum VetaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return L10n.text(s) }; return nil }
}
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
struct NativeBackup: Codable {
    struct Entry: Codable { let game: Game; let rom: Data; let quick: Data?; let auto: Data?; let ram: Data?; var rtc:Data? = nil; var tracks:[String:Data]? = nil; var coreSaves:[String:Data]? = nil; var cover:Data? = nil; var additionalStates:[String:Data]? = nil; var profile:CoreProfile? = nil; var otherDSEngine:EngineSaveArchive? = nil; var nesCheats:[NESCheat]? = nil; var executionStates:[String:[String:Data]]? = nil; var webEngineStorage:WebEngineArchive? = nil }
    let format: String
    let version: Int
    let entries: [Entry]
}
struct StateFile: Codable {
    let version: Int
    let core: String
    let rom: String
    let digest: String
    let bytes: Data
    var uncompressedSize:Int? = nil
    var codec:String? = nil
    var optionsFingerprint:String? = nil
    var optionsSnapshot:[String:String]? = nil
    var createdAt:Date? = nil
    var thumbnail:Data? = nil
    var protected:Bool? = nil
    var name:String? = nil
    static let coreID = "fceumm-ac0d00a-v1"
    static let maximumSize=128*1024*1024
    static func encode(_ bytes: Data, rom: String, core:String = coreID, optionsFingerprint:String? = nil, thumbnail:Data? = nil, optionsSnapshot:[String:String]? = nil) throws -> Data {
        guard !bytes.isEmpty,bytes.count<=maximumSize else{throw VetaError.message("El estado supera el tamaño admitido.")}
        var compressed=Data(count:bytes.count)
        let count=compressed.withUnsafeMutableBytes {destination in bytes.withUnsafeBytes {source in
            compression_encode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,destination.count,source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
        }}
        if count>0 && count<bytes.count {
            compressed.count=count
            return try JSONEncoder().encode(Self(version:optionsFingerprint == nil ? 2:3,core:core,rom:rom,digest:sha256(bytes),bytes:compressed,uncompressedSize:bytes.count,codec:"lzfse",optionsFingerprint:optionsFingerprint,optionsSnapshot:optionsSnapshot,createdAt:Date(),thumbnail:thumbnail))
        }
        return try JSONEncoder().encode(Self(version:optionsFingerprint == nil ? 2:3,core:core,rom:rom,digest:sha256(bytes),bytes:bytes,uncompressedSize:bytes.count,codec:"raw",optionsFingerprint:optionsFingerprint,optionsSnapshot:optionsSnapshot,createdAt:Date(),thumbnail:thumbnail))
    }
    static func decode(_ data: Data, rom: String, core:String = coreID, optionsFingerprint:String? = nil) throws -> Data {
        let invalid=VetaError.message("Este estado está dañado o pertenece a otro juego o motor.")
        let state=try JSONDecoder().decode(Self.self,from:data)
        guard state.core==core,state.rom==rom,!state.bytes.isEmpty,state.bytes.count<=maximumSize else{throw invalid}
        guard (state.thumbnail?.count ?? 0)<=512*1024 else{throw invalid}
        if let name = state.name {
            guard name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid }
        }
        if state.version==3 {
            guard let stored=state.optionsFingerprint,stored.count==64,stored.allSatisfy({$0.isHexDigit}) else{throw invalid}
            if let snapshot=state.optionsSnapshot {
                guard snapshot.count<=CoreOptionID.allCases.count,snapshot.allSatisfy({key,value in CoreOptionID(rawValue:key)?.values.contains(value) == true}),CoreProfile(values:snapshot).fingerprint==stored else{throw invalid}
            }
            if let optionsFingerprint,stored != optionsFingerprint {throw VetaError.message("Este estado usa otro perfil del motor. Restaura sus opciones antes de cargarlo; tu partida actual no cambió.")}
        }
        let result:Data
        if state.version==1 {
            guard state.bytes.count<16_777_216 else{throw invalid};result=state.bytes
        } else if [2,3].contains(state.version),let size=state.uncompressedSize,size>0,size<=maximumSize {
            if state.codec=="raw" {guard state.bytes.count==size else{throw invalid};result=state.bytes}
            else if state.codec=="lzfse" {
                var decoded=Data(count:size)
                let count=decoded.withUnsafeMutableBytes {destination in state.bytes.withUnsafeBytes {source in
                    compression_decode_buffer(destination.bindMemory(to:UInt8.self).baseAddress!,destination.count,source.bindMemory(to:UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
                }}
                guard count==size else{throw invalid};result=decoded
            } else {throw invalid}
        } else {throw invalid}
        guard sha256(result)==state.digest else{throw invalid}
        return result
    }
}
@MainActor final class Library: ObservableObject {
    @Published var games: [Game] = []
    @Published var error: String?
    @Published var consoles:Set<GameConsole> = Set(GameConsole.allCases)
    var populatedConsoles: [GameConsole] {
        let present = Set(games.map(\.console))
        return GameConsole.chronological.filter { present.contains($0) }
    }
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VetaNative", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let selection=self.root.appendingPathComponent("consoles.json")
            if FileManager.default.fileExists(atPath:selection.path) {
                let saved=try JSONDecoder().decode(Set<GameConsole>.self,from:Data(contentsOf:selection))
                consoles=Set(GameConsole.allCases)
                if consoles != saved {try JSONEncoder().encode(consoles).write(to:selection,options:.atomic)}
            }
            let index = self.root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: index.path) { games = try JSONDecoder().decode([Game].self, from: Data(contentsOf: index)) }
            try recoverInterruptedDeletions()
            #if VETA_JIT_DEVELOPMENT
            do {try recoverPS3Deletions()} catch {self.error=error.localizedDescription}
            #endif
            try recoverInterruptedImports()
            if root == nil {
                do {try GameFiles.migrate(active:consoles.map(\.name))}
                catch {self.error="No se pudieron organizar las carpetas de Archivos: \(error.localizedDescription) La biblioteca y las partidas están disponibles. VETA volverá a intentarlo al abrir."}
            }
        } catch { self.error = "No se pudo abrir la biblioteca: \(error.localizedDescription)" }
    }
    func enable(_ console:GameConsole,documents:URL? = nil)throws {
        guard GameConsole.allCases.contains(console) else {throw VetaError.message("Consola desconocida.")}
        _ = try GameFiles.prepareFolder(in:documents,names:[console.name])
        var next=consoles;next.insert(console)
        try JSONEncoder().encode(next).write(to:root.appendingPathComponent("consoles.json"),options:.atomic)
        consoles=next
    }
    static func effectiveRegion(_ game: Game, rom: Data) -> String {
        guard game.console == .nes else{return "Auto"}
        if game.region != "Auto" { return game.region }
        guard rom.count >= 16 else { return "Auto" }
        // NES 2.0 region is handled by the core; legacy iNES needs the same
        // header/name rules used by VETA's previous player (never mutate ROM bytes).
        if rom[7] & 12 == 8 { return "Auto" }
        if rom[9] & 1 != 0 && rom[10..<16].allSatisfy({$0 == 0}) { return "PAL" }
        let pattern = #"\((?:PAL|Europe|E|France|F|Germany|G|Italy|I|Spain|S|Sweden|Sw|Australia|A)\)"#
        if game.name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return "PAL" }
        return "Auto"
    }
    func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func romURL(_ game: Game) -> URL { directory(game.id).appendingPathComponent(game.contentName ?? "game.\(game.console.romExtension)") }
    func stateDirectory(_ game:Game)->URL {
        #if VETA_JIT_DEVELOPMENT
        if ProcessInfo.processInfo.environment["VETA_TV158_QA_PRIMARY"] == "1" {
            // Console-wide render QA may autosave on interruption. Keep every
            // test state and core filesystem outside the user's save slots.
            let run=ProcessInfo.processInfo.environment["VETA_TV158_QA_RUN"] ?? ""
            let safeRun=run.count<=32 && run.utf8.allSatisfy{(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45}
            let folder="VetaTV158RenderQA" + (!run.isEmpty && safeRun ? "-"+run:"")
            return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent(folder,isDirectory:true).appendingPathComponent(game.id,isDirectory:true)
        }
        #endif
        // Replacement cores have incompatible snapshots and cartridge-RAM layouts.
        // Preserve all legacy files verbatim; no implicit migration or overwrite.
        #if VETA_ATARI_TIA
        if game.console == .atari2600 {
            return directory(game.id).appendingPathComponent("engines/"+game.coreID,isDirectory:true)
        }
        #endif
        if [.snes,.megaDrive,.masterSystem,.gameGear].contains(game.console) {
            return directory(game.id).appendingPathComponent("engines/"+game.coreID,isDirectory:true)
        }
        return game.console == .ds && game.dsEngine == .melonDS ? directory(game.id).appendingPathComponent("engines/melonds",isDirectory:true):directory(game.id)
    }
    func file(_ game: Game, _ name: String) -> URL {
        let isState=name.hasSuffix(".vstate") || ["battery.sav","clock.rtc","CoreSaves"].contains(name)
        return (isState ? stateDirectory(game):directory(game.id)).appendingPathComponent(name)
    }
    func prepareSessionSaves(for game:Game)throws->URL {
        try FileManager.default.createDirectory(at:stateDirectory(game),withIntermediateDirectories:true)
        if game.console == .ds && game.dsEngine == .melonDS {
            let saves=file(game,"CoreSaves");try FileManager.default.createDirectory(at:saves,withIntermediateDirectories:true);return saves
        }
        return try prepareCoreSaves(for:game)
    }
    func setDSEngine(_ engine:DSGameEngine,for game:Game)throws {
        guard game.console == .ds,let index=games.firstIndex(where:{$0.id==game.id}) else {throw VetaError.message("No se encontró el juego de Nintendo DS.")}
        var next=games;next[index].dsEngine=engine
        try JSONEncoder().encode(next).write(to:root.appendingPathComponent("library.json"),options:.atomic)
        games=next
    }
    func persist() throws { try JSONEncoder().encode(games).write(to: root.appendingPathComponent("library.json"), options: .atomic) }
    static func validateROM(_ data: Data,console:GameConsole = .nes) throws {
        guard console.playable else {throw VetaError.message("El motor de \(console.name) todavía no está integrado.")}
        if console == .ds {
            guard data.count>=512,data.count<=512*1024*1024 else{throw VetaError.message("Tamaño de ROM Nintendo DS inválido.")}
            func word(_ offset:Int)->Int {Int(data[offset]) | Int(data[offset+1])<<8 | Int(data[offset+2])<<16 | Int(data[offset+3])<<24}
            for offset in [0x20,0x30] {let start=word(offset),length=word(offset+12);guard start>=512,length>0,start<=data.count,length<=data.count-start else{throw VetaError.message("La ROM Nintendo DS está incompleta.")}}
            return
        }
        guard data.count<=64*1024*1024 else{throw VetaError.message("La ROM supera los 64 MB.")}
        if [.megaDrive,.masterSystem,.gameGear,.atari2600,.pcEngine,.ps1].contains(console) {
            switch console {
            case .megaDrive:
                guard MegaDriveROM.isCartridge(data) else { throw MegaDriveROM.invalid }
            case .masterSystem,.gameGear:
                guard data.count>=8192,data.count<=4*1024*1024,[0x1ff0,0x3ff0,0x7ff0].contains(where:{data.count >= $0+8 && Data(data[$0..<$0+8])==Data("TMR SEGA".utf8)}) else{throw VetaError.message("Cabecera Sega de 8 bits inválida.")}
            case .atari2600:
                // Stella accepts the original DPC cartridge size (Pitfall II),
                // including its optional 256-byte data area.
                guard data.count>=2048,data.count<=512*1024,data.count%1024==0 || (10240...10496).contains(data.count) else{throw VetaError.message("Tamaño de cartucho Atari 2600 inválido.")}
            case .pcEngine:
                guard data.count>=8192,data.count<=8*1024*1024,[0,512].contains(data.count%8192) else{throw VetaError.message("Selecciona un cartucho PC Engine .pce válido.")}
            case .ps1:
                guard data.count>=2048,data.starts(with:Data("PS-X EXE".utf8)) else{throw VetaError.message("Selecciona un ejecutable PS-X EXE o importa un disco completo con su CUE y pistas.")}
            default:break
            }
            return
        }
        if console == .gb || console == .gbc {
            guard data.count>=32768,data.count%16384==0 else{throw VetaError.message("La ROM Game Boy está incompleta.")}
            let size=data[0x148];let expected=size<=8 ? 32768 << Int(size):[0x52:72*16384,0x53:80*16384,0x54:96*16384][Int(size)] ?? 0
            var checksum:UInt8=0;for byte in data[0x134...0x14c] {checksum=checksum &- byte &- 1}
            guard expected>0,data.count>=expected,checksum==data[0x14d],(data[0x143]&0x80 != 0)==(console == .gbc) else{throw VetaError.message("La cabecera Game Boy no coincide con la consola o está dañada.")};return
        }
        if console == .gba {
            guard data.count>=192,data.count<=32*1024*1024,data[0xb2]==0x96 else{throw VetaError.message("Selecciona una ROM GBA válida.")}
            var checksum:UInt8=0;for byte in data[0xa0...0xbc] {checksum=checksum &- byte};checksum=checksum &- 0x19
            guard checksum==data[0xbd] else{throw VetaError.message("La cabecera GBA está dañada.")};return
        }
        if console == .snes {
            let offset=data.count%1024 == 512 ? 512:0
            let valid=[0x7fc0,0xffc0,0x40ffc0].contains {base in
                let h=base+offset;guard data.count>=h+64 else{return false}
                let reset=Int(data[h+0x3c]) | Int(data[h+0x3d])<<8
                guard reset>=0x8000 else{return false}
                if [0x20,0x21,0x22,0x23,0x25,0x30,0x31,0x32,0x35].contains(data[h+0x15]) {return true}
                // Early cartridges can use the mapper byte as the last title character.
                // Require independent checksum and executable reset evidence in that case.
                let entry=offset+(base & ~0x7fff)+(reset & 0x7fff)
                guard entry<data.count else{return false}
                let checksum=Int(data[h+0x1e]) | Int(data[h+0x1f])<<8
                let complement=Int(data[h+0x1c]) | Int(data[h+0x1d])<<8
                let resetOpcode=[0x78,0x18,0x38,0x9c,0x4c,0x5c].contains(data[entry])
                if resetOpcode && checksum>0 && complement>0 && checksum+complement==0xffff {return true}
                // Some unlicensed HiROM cartridges omit metadata but provide a native-mode
                // reset trampoline (CLC; XCE; JML) into a populated ROM bank.
                guard base==0xffc0, data.count-offset>=32768, (data.count-offset)%32768==0,
                      data[h..<h+32].allSatisfy({$0==0}), entry+6<=data.count,
                      Array(data[entry..<entry+3])==[0x18,0xfb,0x5c] else{return false}
                let target=Int(data[entry+3]) | Int(data[entry+4])<<8 | Int(data[entry+5])<<16
                let targetOffset=offset+(target & 0x3fffff)
                return target>=0xc00000 && targetOffset<data.count && ![0x00,0xff].contains(data[targetOffset])
            }
            guard data.count>=32768,valid else{throw VetaError.message("Selecciona una ROM SNES válida (.sfc o .smc).")};return
        }
        guard data.count >= 16, data.count <= 64*1024*1024, Array(data.prefix(4)) == [0x4e, 0x45, 0x53, 0x1a] else {
            throw VetaError.message("Selecciona una ROM NES válida (.nes).")
        }
        let nes2 = data[7] & 12 == 8
        // Reject truncated standard iNES images before handing untrusted bytes to the core.
        if !nes2 {
            let expected = 16 + (data[6] & 4 != 0 ? 512 : 0) + Int(data[4])*16384 + Int(data[5])*8192
            guard data[4] > 0, data.count >= expected else { throw VetaError.message("La ROM NES está incompleta.") }
        }
    }
    @discardableResult func add(data: Data, name: String, console:GameConsole = .nes) throws -> Game {
        guard GameConsole.allCases.contains(console) else {throw VetaError.message("Consola desconocida.")}
        try Self.validateROM(data,console:console)
        let id = sha256(data)
        if let existing = games.first(where: { $0.id == id }) { return existing }
        let game = Game(id: id, name: String(name.prefix(160)),console:console)
        let dir = directory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: romURL(game), options: .atomic)
        games.append(game)
        do { try persist() } catch { games.removeAll { $0.id == id }; throw error }
        return game
    }
    static let demoNames=["thwaite":"Thwaite","croom":"Concentration Room","akanoid-gb":"A_KANOID","sushi-gb":"Sushi Nights","gluf-gbc":"GLUF · Tesla Frog","space-game":"Space Game","gold-rush":"Gold Rush","sushi-sms":"Sushi Nights · SMS","sushi-gg":"Sushi Nights · GG","berta":"Berta"]
    func demoExtension(_ name:String)->String {name == "gold-rush" ? "md":["sushi-sms","gluf-sms"].contains(name) ? "sms":["sushi-gg","akanoid-gg"].contains(name) ? "gg":name == "berta" ? "a26":name == "space-game" ? "gba":name == "gluf-gbc" ? "gbc":name.hasSuffix("-gb") ? "gb":"nes"}
    func addBundled(_ name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: demoExtension(name), subdirectory: "Content/\(name)") else { throw VetaError.message("No se encontró el juego de muestra.") }
        _ = try add(data: Data(contentsOf: url), name: Self.demoNames[name] ?? name,console:try GameConsole.detect(Data(contentsOf:url),extension:url.pathExtension))
    }
    @discardableResult func importURL(_ url: URL,console preferred:GameConsole? = nil) throws -> Game? {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        if NativeGameFile.extensions.contains(url.pathExtension.lowercased()) {return try importNativeFile(url,console:preferred)}
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // DS cartridges may be up to 512 MiB; keep other cartridge and backup
        // limits unchanged. The console-specific validator still checks contents.
        let isDS = url.pathExtension.lowercased() == "nds"
        if isDS {
            guard size <= 512*1024*1024 else { throw VetaError.message("La ROM Nintendo DS supera el límite de 512 MiB.") }
        } else {
            guard size < 256*1024*1024 else { throw VetaError.message("El archivo supera el límite de tamaño permitido para este formato.") }
        }
        let data = try Data(contentsOf: url, options: isDS ? .mappedIfSafe : [])
        if !["vetanes","vetaretro"].contains(url.pathExtension.lowercased()) {
            let normalized = try MegaDriveROM.normalize(data, extension: url.pathExtension)
            let console=try GameConsole.detect(normalized,extension:url.pathExtension,preferred:preferred)
            return try add(data:normalized,name:url.deletingPathExtension().lastPathComponent,console:console)
        }
        let backup = try JSONDecoder().decode(NativeBackup.self, from: data)
        guard ((backup.format == "veta-native-nes" && backup.version == 1) || (backup.format == "veta-native" && [2,3,4,5,6].contains(backup.version))), backup.entries.count <= 500 else { throw VetaError.message("Selecciona un respaldo nativo .vetaretro o .vetanes válido.") }
        // Validate the entire archive before writing; existing games/saves win.
        for entry in backup.entries {
            guard GameConsole.allCases.contains(entry.game.console) else {throw VetaError.message("Consola desconocida.")}
            if let tracks=entry.tracks {
                guard [.ps1,.saturn].contains(entry.game.console),entry.game.contentName == "disc.cue" else{throw VetaError.message("Respaldo de disco inválido.")}
                let names=try DiscFiles.names(in:entry.rom)
                guard Set(names)==Set(tracks.keys) else{throw VetaError.message("Faltan pistas en el respaldo.")}
                var hash=SHA256()
                for data in [entry.rom]+names.compactMap({tracks[$0]}) {var count=UInt64(data.count).bigEndian;withUnsafeBytes(of:&count){hash.update(data:Data($0))};hash.update(data:data)}
                guard entry.game.id==hash.finalize().map({String(format:"%02x",$0)}).joined() else{throw VetaError.message("Una pista del respaldo está dañada.")}
            } else {
                if let content=entry.game.contentName,NativeGameFile.isStreamedContent(entry.game) {
                    guard DiscFiles.safeName(content),content.hasPrefix("game.") else{throw VetaError.message("Nombre inválido en el respaldo.")}
                    try NativeGameFile.validate(header:Data(entry.rom.prefix(65536)),size:entry.rom.count,ext:(content as NSString).pathExtension,console:entry.game.console)
                } else {
                    guard entry.game.contentName==nil else{throw VetaError.message("Faltan archivos del juego en el respaldo.")}
                    try Self.validateROM(entry.rom,console:entry.game.console)
                }
                guard entry.game.id == sha256(entry.rom) || (entry.game.console == .threeDS && ThreeDSImportNormalization.matchesOriginalIdentity(entry.rom,id:entry.game.id)) else { throw VetaError.message("El respaldo contiene una ROM dañada.") }
            }
            if let cheats=entry.nesCheats {
                guard entry.game.console == .nes else {throw VetaError.message("Los trucos de este respaldo no corresponden a NES.")}
                _ = try NESCheat.validated(cheats)
            }
            if let cover=entry.cover {_ = try CoverRecord.decode(cover)}
            if let files=entry.coreSaves {try Self.validateCoreSaves(files)}
            if let profile=entry.profile {_ = try profile.validated(for:entry.game.console)}
            if let other=entry.otherDSEngine {try validateEngineArchive(other,game:entry.game)}
            if let states=entry.executionStates {try validateExecutionStates(states,game:entry.game)}
            if let storage=entry.webEngineStorage {try storage.validate(game:entry.game)}
            if let states=entry.additionalStates {
                guard states.count<=NativeSaveStore.slots.count,states.keys.allSatisfy({NativeSaveStore.slots.contains($0) && $0 != "auto" && $0 != "quick"}),states.values.reduce(0,{$0+$1.count})<=128*1024*1024 else {throw VetaError.message("Ranuras inválidas en el respaldo.")}
                for state in states.values {_ = try StateFile.decode(state,rom:entry.game.id,core:entry.game.coreID)}
            }
            for state in [entry.quick, entry.auto].compactMap({$0}) { _ = try StateFile.decode(state, rom: entry.game.id,core:entry.game.coreID) }
            guard (entry.ram?.count ?? 0) <= 4*1024*1024, (entry.rtc?.count ?? 0)<=4096 else { throw VetaError.message("SRAM inválida.") }
        }
        for entry in backup.entries where !games.contains(where: { $0.id == entry.game.id }) {
            // Restore every file in a private sibling directory before publishing
            // the game. A failed profile/state write never indexes half a backup.
            let stagingRoot=root.appendingPathComponent(".backup-import-"+UUID().uuidString,isDirectory:true)
            let staging=Library(root:stagingRoot)
            do {
                try staging.restoreBackupEntry(entry)
                let destination=directory(entry.game.id)
                guard !FileManager.default.fileExists(atPath:destination.path) else {throw VetaError.message("Ya existe una carpeta sin registrar para este juego. Sus archivos se conservaron.")}
                // The intent survives process termination between move and index.
                try Data(entry.game.id.utf8).write(to:stagingRoot.appendingPathComponent("moving-game"),options:.atomic)
                try FileManager.default.moveItem(at:staging.directory(entry.game.id),to:destination)
                let next=games+[entry.game]
                try JSONEncoder().encode(next).write(to:root.appendingPathComponent("library.json"),options:.atomic)
                games=next
                try? FileManager.default.removeItem(at:stagingRoot)
            } catch {
                // Cleanup only this staged entry. Existing games always win.
                try? recoverInterruptedImports()
                throw error
            }
        }
        return nil
    }
    private func restoreBackupEntry(_ entry:NativeBackup.Entry)throws {
        var game:Game
        if let tracks=entry.tracks {
            let staging=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true)
            defer{try? FileManager.default.removeItem(at:staging)}
            let cue=staging.appendingPathComponent("disc.cue");try entry.rom.write(to:cue)
            for (name,data) in tracks {try data.write(to:staging.appendingPathComponent(name))}
            try importURLs([cue],console:entry.game.console)
            guard let restored=games.first(where:{$0.id==entry.game.id}) else{throw VetaError.message("No se pudo restaurar el disco.")};game=restored
        } else if let name=entry.game.contentName,NativeGameFile.isStreamedContent(entry.game) {
            let staging=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:staging)}
            let url=staging.appendingPathComponent(name)
            let importBytes = entry.game.console == .threeDS ? (ThreeDSImportNormalization.originalContent(entry.rom,id:entry.game.id) ?? entry.rom):entry.rom
            try importBytes.write(to:url);game=try importNativeFile(url,console:entry.game.console)
        } else {game = try add(data: entry.rom, name: entry.game.name,console:entry.game.console)}
        game.dsEngine=entry.game.dsEngine
        _ = try prepareSessionSaves(for:game)
        if let files=entry.coreSaves {try restoreCoreSaves(files,for:game)}
        if let other=entry.otherDSEngine {try restoreEngineArchive(other,game:entry.game)}
        if let states=entry.executionStates {try restoreExecutionStates(states,game:game)}
        if let storage=entry.webEngineStorage {try restoreWebEngineStorage(storage,game:game)}
        if let profile=entry.profile {try GameProfileStore(library:self,game:game).write(profile,console:false)}
        if let cheats=entry.nesCheats {try NESCheatStore(url:file(game,"cheats-nes.json")).write(cheats)}
        if let states=entry.additionalStates {for (slot,data) in states {try data.write(to:file(game,slot+".vstate"),options:.atomic)}}
        if let i = games.firstIndex(where: { $0.id == game.id }) { games[i] = entry.game }
        for (name, data) in [("quick.vstate", entry.quick), ("auto.vstate", entry.auto), ("battery.sav", entry.ram),("clock.rtc",entry.rtc),("cover.vcover",entry.cover)] {
            if let data { try data.write(to: file(game,name), options: .atomic) }
        }
        try persist()
    }
    private func recoverInterruptedImports()throws {
        let fm=FileManager.default
        for staging in try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) where staging.lastPathComponent.hasPrefix(".backup-import-") {
            let info=try staging.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard info.isDirectory == true,info.isSymbolicLink != true else {continue}
            let intent=staging.appendingPathComponent("moving-game")
            if fm.fileExists(atPath:intent.path),let id=String(data:try Data(contentsOf:intent),encoding:.utf8),Self.validGameID(id),!games.contains(where:{$0.id==id}),fm.fileExists(atPath:directory(id).path) {
                try fm.removeItem(at:directory(id))
            }
            try fm.removeItem(at:staging)
        }
    }
    private var deletionDirectory:URL {root.appendingPathComponent("DeletedGames",isDirectory:true)}
    private static func validGameID(_ id:String)->Bool {id.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
    // Move first, commit the index atomically, then reclaim the files. If the app
    // exits between those steps, the persisted index decides whether to restore
    // the game or finish deleting it at the next launch.
    private func recoverInterruptedDeletions()throws {
        let fm=FileManager.default
        guard fm.fileExists(atPath:deletionDirectory.path) else{return}
        for staged in try fm.contentsOfDirectory(at:deletionDirectory,includingPropertiesForKeys:nil) where Self.validGameID(staged.lastPathComponent) {
            let id=staged.lastPathComponent,original=directory(id)
            if games.contains(where:{$0.id==id}) && !fm.fileExists(atPath:original.path) {try fm.moveItem(at:staged,to:original)}
            else {try fm.removeItem(at:staged)}
        }
    }
    func remove(_ game:Game)throws {
        _ = try removeGames(ids:[game.id],console:game.console)
    }
    /// One index commit for the entire selection. Until that commit, every staged
    /// directory still belongs to the old index and can be recovered on launch.
    @discardableResult func removeGames(ids:Set<String>,console:GameConsole)throws -> [Game] {
        guard ids.allSatisfy(Self.validGameID) else {
            throw VetaError.message("No se pudo identificar el juego que quieres eliminar.")
        }
        let selected=games.filter {ids.contains($0.id)}
        guard selected.allSatisfy({$0.console == console}) else {
            throw VetaError.message("La selección incluye juegos de otra consola. No se eliminó ningún juego.")
        }
        guard !selected.isEmpty else{return []}
        try recoverInterruptedDeletions()
        #if VETA_JIT_DEVELOPMENT
        do {try recoverPS3Deletions()} catch {self.error=error.localizedDescription}
        for game in selected {try preparePS3Deletion(game)}
        #endif
        let fm=FileManager.default
        let next=games.filter {!ids.contains($0.id)}
        let encoded=try JSONEncoder().encode(next)
        try fm.createDirectory(at:deletionDirectory,withIntermediateDirectories:true)
        var moved:[String]=[]
        do {
            for game in selected {
                let original=directory(game.id)
                if fm.fileExists(atPath:original.path) {
                    try fm.moveItem(at:original,to:deletionDirectory.appendingPathComponent(game.id,isDirectory:true))
                    moved.append(game.id)
                }
            }
            try encoded.write(to:root.appendingPathComponent("library.json"),options:.atomic)
        } catch {
            // Attempt every rollback, even if one directory cannot be restored.
            // Any remaining staging entries are recoverable from the old index.
            for id in moved.reversed() {
                try? fm.moveItem(at:deletionDirectory.appendingPathComponent(id),to:directory(id))
            }
            throw error
        }
        games=next
        #if VETA_JIT_DEVELOPMENT
        do {try recoverPS3Deletions()} catch {self.error=error.localizedDescription}
        #endif
        do {try recoverInterruptedDeletions()}
        catch {
            self.error="Los juegos se quitaron de la biblioteca, pero queda espacio por liberar. VETA reintentará la limpieza al abrirse de nuevo."
        }
        return selected
    }
    func update(_ game: Game) {
        if let i = games.firstIndex(where: { $0.id == game.id }) {
            let old = games[i]; games[i] = game
            do { try persist() } catch { games[i] = old; self.error = error.localizedDescription }
        }
    }
    func export() throws -> URL {
        guard !games.contains(where:{$0.console.isStandaloneEngine}) else {throw VetaError.message("El respaldo integrado todavía no incluye las consolas de laboratorio. Conserva sus carpetas y archivos originales.")}
        // The existing JSON format contains base64 ROMs. Bound its total before
        // allocating so a large disc cannot terminate the app through memory pressure.
        var total=0
        for game in games {
            guard let files=FileManager.default.enumerator(at:directory(game.id),includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]) else {continue}
            for case let file as URL in files {
                let info=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard info.isSymbolicLink != true else {throw VetaError.message("El respaldo contiene un enlace no permitido.")}
                if info.isRegularFile == true {total += info.fileSize ?? 0}
            }
        }
        guard total<=128*1024*1024 else{throw VetaError.message("La biblioteca supera los 128 MB del respaldo integrado. Conserva los discos originales; el respaldo de bibliotecas grandes aún está pendiente.")}
        let entries = try games.map { game -> NativeBackup.Entry in
            @MainActor func optional(_ name: String) throws -> Data? {
                let url = file(game,name); return FileManager.default.fileExists(atPath:url.path) ? try Data(contentsOf:url) : nil
            }
            let rom=try Data(contentsOf:romURL(game))
            let tracks:[String:Data]? = game.contentName == "disc.cue" ? try Dictionary(uniqueKeysWithValues:DiscFiles.names(in:rom).map{($0,try Data(contentsOf:file(game,$0)))}):nil
            var states:[String:Data]=[:]
            for slot in NativeSaveStore.slots where slot != "auto" && slot != "quick" {if let data=try optional(slot+".vstate"){states[slot]=data}}
            var archivedGame=game
            archivedGame.videoPresentation=VideoProfileStore(library:self,game:game).resolved()
            let cheats=game.console == .nes ? try NESCheatStore(url:file(game,"cheats-nes.json")).read():nil
            return try .init(game:archivedGame,rom:rom,quick:optional("quick.vstate"),auto:optional("auto.vstate"),ram:optional("battery.sav"),rtc:optional("clock.rtc"),tracks:tracks,coreSaves:coreSaveFiles(game),cover:optional("cover.vcover"),additionalStates:states.isEmpty ? nil:states,profile:GameProfileStore(library:self,game:game).resolved(),otherDSEngine:archiveOtherEngine(game),nesCheats:cheats,executionStates:archiveExecutionStates(game),webEngineStorage:archiveWebEngineStorage(game))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VETA-\(UUID().uuidString.prefix(8)).vetaretro")
        try JSONEncoder().encode(NativeBackup(format:"veta-native",version:6,entries:entries)).write(to:url,options:.atomic)
        return url
    }
}
