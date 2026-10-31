import Foundation
import CryptoKit

/// Route only verified cartridge contents; keep all other engines and states unchanged.
enum CartridgeCompatibility {
    static let gameGear: Set<String> = ["e42930c5938c63c9ea1f03bdda6361f4eced09d2a544d62c1d2c9c7fdd7db88d", "e4217d26e10b04071b61ff39c7412f90da9631fcf7da6bfd9afdba2a5fcdf443", "8eb6eeafbb41623e1cd887f411388f073213d5fbc9e8d3d88272e9760c7ba769", "4b1ad1f3e8d4b67822b6e21f078b8612bcd0531ef7c83a722072c2682189ab00", "7d43e89e70a7a2e0bc2552c834e32d3f46c3287e566930e5e4f1daf4091d600d"]
    static let superGrafx: Set<String> = ["5f3b430e34c79218a9f89a403a286037b2fb172b528373df5ba70aedbecd36d7", "5006f2da9cb645312a0c589044df50d3f97106d2d2291bf9883dacf98960c2fe"]
    static func coreID(id: String, console: GameConsole) -> String? {
        if console == .gbc && id == "9f9944ec409482ebc467655acdbf58234129e88b7eed913cc52810761b51f6cd" { return "sameboy-1506d804-v1" }
        if console == .gameGear && gameGear.contains(id) { return "gearsystem-d18766b3-v1" }
        if console == .pcEngine && superGrafx.contains(id) { return "supergrafx-9c11dcd2-v1" }
        return nil
    }
    static func frameworkName(id: String, console: GameConsole) -> String? {
        guard let core = coreID(id:id,console:console) else { return nil }
        if core.hasPrefix("sameboy-") { return "SameBoyCore" }
        if core.hasPrefix("gearsystem-") { return "GearsystemCore" }
        return "SuperGrafxCore"
    }
    static func isKnownHeaderlessGameGear(_ data: Data, console: GameConsole) -> Bool {
        guard console == .gameGear, data.count == 262144 else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == "4b1ad1f3e8d4b67822b6e21f078b8612bcd0531ef7c83a722072c2682189ab00"
    }
}
