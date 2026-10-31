import Foundation
import CryptoKit

/// Correct the boot checksums of one verified translation, on the staged copy.
/// Payload, source identity, source files and every other cartridge stay intact.
enum N64ImportNormalization {
    static let originalID = "545edea3dee2227d931ac7401902645df05b42c7bf682291fdbb19969fd992cb"
    static let correctedID = "fae3097fcbe0983dc0b29ab14242a8461575cd885392133ae2721c7ba45e46e0"
    static let originalCRC = Data([0x40,0xd5,0xd2,0xde,0x78,0x48,0x9f,0x0f])
    static let correctedCRC = Data([0x97,0x86,0xf4,0xaa,0x81,0x51,0x66,0x03])
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined() }
    @discardableResult static func apply(toStagedCopy url: URL, originalID id: String) throws -> Bool {
        guard id == originalID else { return false }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == 16*1024*1024, digest(data) == originalID else { return false }
        let file = try FileHandle(forUpdating: url); defer { try? file.close() }
        try file.seek(toOffset:16); try file.write(contentsOf:correctedCRC); try file.synchronize()
        return true
    }
    static func matchesOriginalIdentity(_ data: Data, id: String) -> Bool {
        id == originalID && data.count == 16*1024*1024 && digest(data) == correctedID
    }
    static func originalContent(_ data: Data, id: String) -> Data? {
        guard matchesOriginalIdentity(data,id:id) else { return nil }
        var original=data; original.replaceSubrange(16..<24,with:originalCRC); return original
    }
}
