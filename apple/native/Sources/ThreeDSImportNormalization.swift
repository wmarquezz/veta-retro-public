import Foundation
import CryptoKit

/// Repairs only a proven plaintext main NCCH whose encryption flag is stale.
/// This does not decrypt data or alter accessory partitions. Original URLs are
/// never passed to apply; the importer owns the staging copy and its lifetime.
enum ThreeDSImportNormalization {
    struct Patch: Equatable { let offset: UInt64; let original: UInt8; let replacement: UInt8 }
    static func patch(for url: URL) throws -> Patch? {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let bytes = info.fileSize, bytes >= 512 else { return nil }
        let size = UInt64(bytes), file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size-offset else { return Data() }
            try file.seek(toOffset: offset)
            return try file.read(upToCount: count) ?? Data()
        }
        func word(_ data: Data, _ at: Int) -> UInt64 {
            (0..<4).reduce(UInt64(0)) { $0 | UInt64(data[at+$1]) << (8*$1) }
        }
        func magic(_ data: Data, _ text: String) -> Bool {
            data.count == 512 && data.subdata(in: 256..<260) == Data(text.utf8)
        }
        let outer = try read(0,512)
        var base: UInt64 = 0, partitionSize = size
        if magic(outer,"NCSD") {
            base = word(outer,0x120)*512; partitionSize = word(outer,0x124)*512
            guard base >= 512, base <= size, partitionSize >= 512, partitionSize <= size-base else { return nil }
        } else if !magic(outer,"NCCH") { return nil }
        let header = try read(base,512)
        guard magic(header,"NCCH"), header[0x18f] & 4 == 0,
              word(header,0x104)*512 == partitionSize,
              word(header,0x180) == 1024 else { return nil }
        // Require all three independent stored digests, not just an extension,
        // filename, readable text, or a guessed encryption flag.
        func matches(_ offset: UInt64, _ length: UInt64, _ hashAt: Int) throws -> Bool {
            guard length > 0, length <= 16*1024*1024, offset >= 512,
                  offset <= partitionSize, length <= partitionSize-offset else { return false }
            var hasher = SHA256(), remaining = length
            try file.seek(toOffset: base+offset)
            while remaining > 0 {
                let n = Int(min(remaining,1024*1024))
                guard let data = try file.read(upToCount:n), data.count == n else { return false }
                hasher.update(data:data); remaining -= UInt64(n)
            }
            return Data(hasher.finalize()) == header.subdata(in:hashAt..<hashAt+32)
        }
        let exefs = word(header,0x1a0)*512, exefsSize = word(header,0x1a4)*512
        let romfs = word(header,0x1b0)*512, romfsSize = word(header,0x1b4)*512
        let exefsHashSize = word(header,0x1a8)*512, romfsHashSize = word(header,0x1b8)*512
        guard exefs >= 0xa00, exefsSize > 0, exefs <= partitionSize, exefsSize <= partitionSize-exefs,
              romfs >= exefs+exefsSize, romfsSize > 0, romfs <= partitionSize, romfsSize <= partitionSize-romfs,
              exefsHashSize <= exefsSize, romfsHashSize <= romfsSize,
              try matches(512,1024,0x160),
              try matches(exefs,exefsHashSize,0x1c0),
              try matches(romfs,romfsHashSize,0x1e0) else { return nil }
        return Patch(offset:base+0x18f,original:header[0x18f],replacement:header[0x18f]|4)
    }
    @discardableResult static func apply(toStagedCopy url: URL) throws -> Bool {
        guard let patch = try patch(for:url) else { return false }
        let file = try FileHandle(forUpdating:url); defer { try? file.close() }
        try file.seek(toOffset:patch.offset)
        guard try file.read(upToCount:1) == Data([patch.original]) else { throw CocoaError(.fileReadCorruptFile) }
        try file.seek(toOffset:patch.offset); try file.write(contentsOf:Data([patch.replacement])); try file.synchronize()
        return true
    }
    // Backups retain the original content ID for save/cloud compatibility.
    // Accept only the exact original SHA after reversing our single-bit change.
    static func matchesOriginalIdentity(_ data: Data, id: String) -> Bool {
        originalContent(data,id:id) != nil
    }
    static func originalContent(_ data: Data, id: String) -> Data? {
        guard data.count >= 512 else { return nil }
        func word(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[at+$1]) << (8*$1) } }
        let magic = data.subdata(in:256..<260)
        let base: Int
        if magic == Data("NCSD".utf8) { base=word(0x120)*512 }
        else if magic == Data("NCCH".utf8) { base=0 }
        else { return nil }
        guard base >= 0, base <= data.count-512,
              data.subdata(in:base+256..<base+260) == Data("NCCH".utf8),
              data[base+0x18f] & 4 != 0 else { return nil }
        var original=data; original[base+0x18f] &= ~4
        return SHA256.hash(data:original).map { String(format:"%02x",$0) }.joined() == id ? original:nil
    }
    static func digest(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom:url);defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount:1024*1024), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
