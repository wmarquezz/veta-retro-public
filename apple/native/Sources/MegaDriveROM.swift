import Foundation

/// Normalize legacy Super Magic Drive dumps once, before hashing or storage.
/// The source file is never modified; BIN/GEN/MD and SMD copies share one game ID.
enum MegaDriveROM {
    static let maximum = 32 * 1024 * 1024
    static func isCartridge(_ data: Data) -> Bool {
        guard data.count >= 512, data.count <= maximum, data.count.isMultiple(of: 2) else { return false }
        // Some licensed cartridges shift the manufacturer field by a few bytes.
        if data[0x100..<0x120].range(of: Data("SEGA".utf8)) != nil { return true }
        // Early EA and unlicensed cartridges can omit that field entirely.
        // Require plausible 68000 reset vectors instead of accepting arbitrary data.
        func word(_ start: Int) -> UInt32 {
            data[start..<start+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let stack = word(0) & 0x00ffffff, reset = word(4)
        return stack >= 0xff0000 && stack.isMultiple(of: 2)
            && reset >= 8 && reset < UInt32(data.count) && reset.isMultiple(of: 2)
    }
    static func normalize(_ data: Data, extension ext: String) throws -> Data {
        guard ["smd", "md", "gen", "bin"].contains(ext.lowercased()) else { return data }
        if isCartridge(data) { return data }
        let copierHeader = data.count >= 512 && data[8] == 0xaa && data[9] == 0xbb && data[10] == 6
        guard ext.lowercased() == "smd" || copierHeader else { return data }
        guard data.count > 512, data.count <= maximum + 512,
              (data.count - 512).isMultiple(of: 16384) else { throw invalid }
        var decoded = Data(count: data.count - 512)
        decoded.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                let input = source.bindMemory(to: UInt8.self)
                let output = destination.bindMemory(to: UInt8.self)
                for block in stride(from: 0, to: output.count, by: 16384) {
                    for i in 0..<8192 {
                        output[block + i * 2] = input[512 + block + 8192 + i]
                        output[block + i * 2 + 1] = input[512 + block + i]
                    }
                }
            }
        }
        guard isCartridge(decoded) else { throw invalid }
        return decoded
    }
    static var invalid: VetaError {
        .message("La ROM Mega Drive está incompleta o usa un formato no compatible.")
    }
}
