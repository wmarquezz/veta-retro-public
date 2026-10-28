import Foundation

/// Presentation only: does not change clock speed, save states, or pause engines.
struct ThermalNoticeState {
    enum Level: Int { case none, high, critical }
    private(set) var level: Level = .none
    private(set) var collapsed = false
    var visible: Bool { level != .none }

    mutating func update(_ state: ProcessInfo.ThermalState) {
        let next: Level
        switch state {
        case .serious: next = .high
        case .critical: next = .critical
        case .nominal, .fair: next = .none
        @unknown default: next = .none
        }
        // A worse condition merits a fresh recommendation. Cooling resets it.
        if next.rawValue > level.rawValue || next == .none { collapsed = false }
        level = next
    }
    mutating func minimize() { if visible { collapsed = true } }
    mutating func expand() { collapsed = false }
}
