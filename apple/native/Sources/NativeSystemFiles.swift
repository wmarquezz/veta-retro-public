#if VETA_JIT_DEVELOPMENT
import Foundation
import Darwin
import CryptoKit

// Structural checks only: a correctly sized image is not proof of firmware
// compatibility. Never resolve backing files outside the selected directory.
enum XboxSystemFiles {
    static let openBIOSHash="8bf516fcb453f18925ad0aad75ff923bd5f225420be6b0175d0fe818f0653314"
    static let required=["mcpx_1.0.bin","flash.bin","xbox_hdd.qcow2"]
    static let optional="xbox_eeprom.bin"
    static func validate(_ folder:URL)throws->[String] {
        let fm=FileManager.default
        let invalid=VetaError.message("La carpeta Xbox requiere flash.bin y xbox_hdd.qcow2. MCPX de 512 bytes es obligatorio salvo con OXOS 0.3.3 verificado; EEPROM de 256 bytes es opcional.")
        let attrs=try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard attrs.isDirectory == true,attrs.isSymbolicLink != true else {throw invalid}
        var names=required
        let mcpx=folder.appendingPathComponent("mcpx_1.0.bin")
        if !fm.fileExists(atPath:mcpx.path) {
            let bios=folder.appendingPathComponent("flash.bin")
            let attributes=try bios.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attributes.isRegularFile==true,attributes.isSymbolicLink != true,attributes.fileSize==1048576 else {throw invalid}
            let digest=SHA256.hash(data:try Data(contentsOf:bios)).map{String(format:"%02x",$0)}.joined()
            guard digest==openBIOSHash else {throw invalid}
            names.removeAll{$0=="mcpx_1.0.bin"}
        }
        if fm.fileExists(atPath:folder.appendingPathComponent(optional).path) {names.append(optional)}
        for name in names {
            let path=folder.appendingPathComponent(name)
            let attrs=try path.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile == true,attrs.isSymbolicLink != true,let size=attrs.fileSize else {throw invalid}
            switch name {
            case "mcpx_1.0.bin":guard size==512 else {throw invalid}
            case "flash.bin":guard [262144,524288,1048576].contains(size) else {throw invalid}
            case optional:guard size==256 else {throw invalid}
            default:
                guard size>=72,size<=64*1024*1024*1024 else {throw invalid}
                let file=try FileHandle(forReadingFrom:path);defer{try? file.close()}
                let header=try file.read(upToCount:104) ?? Data()
                guard header.count>=72,header.prefix(4)==Data([0x51,0x46,0x49,0xfb]) else {throw invalid}
                func be(_ offset:Int,_ count:Int)->UInt64 {header[offset..<offset+count].reduce(0){($0<<8)|UInt64($1)}}
                let version=be(4,4)
                guard [2,3].contains(version),be(8,8)==0,be(16,4)==0 else {throw invalid}
                // QCOW2 v3's external-data-file feature needs a second file and
                // is intentionally not accepted by this self-contained import.
                if version==3 {guard header.count>=104,be(72,8) & 4 == 0 else {throw invalid}}
            }
        }
        return names
    }
    static func install(from source:URL,to destination:URL,beforeCommit:(()throws->Void)?=nil)throws {
        let scoped=source.startAccessingSecurityScopedResource();defer{if scoped {source.stopAccessingSecurityScopedResource()}}
        let names=try validate(source),fm=FileManager.default,parent=destination.deletingLastPathComponent()
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let staging=parent.appendingPathComponent(".xbox-system-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        defer{try? fm.removeItem(at:staging)}
        for name in names {try fm.copyItem(at:source.appendingPathComponent(name),to:staging.appendingPathComponent(name))}
        // Preserve an existing console identity when no replacement EEPROM is
        // supplied; changing BIOS/HDD alone should not discard that identity.
        let oldEEPROM=destination.appendingPathComponent(optional)
        if !names.contains(optional),fm.fileExists(atPath:oldEEPROM.path) {
            let attrs=try oldEEPROM.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isRegularFile == true,attrs.isSymbolicLink != true,attrs.fileSize==256 else {throw VetaError.message("No se pudo reemplazar la carpeta de sistema Xbox; se conservaron los archivos anteriores.")}
            try fm.copyItem(at:oldEEPROM,to:staging.appendingPathComponent(optional))
        }
        _ = try validate(staging)
        try beforeCommit?()
        if fm.fileExists(atPath:destination.path) {
            let attrs=try destination.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard attrs.isDirectory == true,attrs.isSymbolicLink != true else {throw VetaError.message("No se pudo reemplazar la carpeta de sistema Xbox; se conservaron los archivos anteriores.")}
            // APFS swaps both directory names atomically: failure leaves the
            // old installation intact; success puts it at staging for cleanup.
            let result=staging.path.withCString {a in destination.path.withCString {b in renameatx_np(AT_FDCWD,a,AT_FDCWD,b,UInt32(RENAME_SWAP))}}
            guard result==0 else {throw VetaError.message("No se pudo reemplazar la carpeta de sistema Xbox; se conservaron los archivos anteriores.")}
        } else {try fm.moveItem(at:staging,to:destination)}
    }
}
#endif
