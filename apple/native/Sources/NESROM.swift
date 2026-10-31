import Foundation

/// Repair only the positively identified legacy dump; never infer a mapper
/// from a filename or change an unknown cartridge. Original files stay intact.
enum NESROM {
    static func normalize(_ data: Data) -> Data {
        guard data.count == 98320,
              sha256(data) == "b7a856d52a79f6af49c508b3ae289f3b54bab5bb4b49e73d2fc2a210d9b1eb5f" else { return data }
        // FCEUmm database: payload CRC32 CB53C523, Color Dreams mapper 11.
        // The old header incorrectly splits 96 KiB into 32 KiB PRG + 32 KiB CHR.
        var corrected = data
        corrected[4] = 4 // 64 KiB PRG
        corrected[5] = 4 // 32 KiB CHR
        corrected[6] = 0xb1 // mapper 11, vertical mirroring
        corrected[7] = 0
        return corrected
    }
}
