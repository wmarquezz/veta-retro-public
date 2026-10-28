import SwiftUI
import UniformTypeIdentifiers

struct PerformanceWindow {
    private(set) var elapsed: Double = 0
    private(set) var frames: UInt64 = 0
    private(set) var p95: Double = 0
    private(set) var thermal: Int = 0
    private(set) var missing: UInt64 = 0
    private(set) var dropped: UInt64 = 0
    private var previousMissing: UInt64?
    private var previousDropped: UInt64?
    init(missing: UInt64? = nil, dropped: UInt64? = nil) { previousMissing = missing; previousDropped = dropped }
    mutating func add(elapsed: Double, frames: UInt64, p95: Double, thermal: Int, missing: UInt64, dropped: UInt64) {
        guard elapsed.isFinite, elapsed > 0, elapsed < 60, p95.isFinite, p95 >= 0 else { return }
        self.elapsed += elapsed; self.frames += frames; self.p95 = max(self.p95, p95); self.thermal = max(self.thermal, thermal)
        if let old = previousMissing, missing >= old { self.missing += missing - old }
        if let old = previousDropped, dropped >= old { self.dropped += dropped - old }
        previousMissing = missing; previousDropped = dropped
    }
    var isReady: Bool { elapsed >= 30 }
    var fps: Double { elapsed > 0 ? Double(frames) / elapsed : 0 }
}
struct PerformanceObservation: Codable, Identifiable {
    var id: String { gameID + ":" + coreID }
    let gameID: String
    let gameName: String
    let coreID: String
    let consoleName: String
    let date: Date
    let seconds: Double
    let fps: Double
    let targetFPS: Double
    let worstWindowP95: Double
    let peakThermalState: Int
    let audioMissing: UInt64
    let audioDropped: UInt64
    let simulator: Bool
    let os: String
}
struct PerformanceReport: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let appBuild: String
    let observations: [PerformanceObservation]
}
struct PerformanceReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
@MainActor final class DevicePerformance: ObservableObject {
    static let shared = DevicePerformance()
    @Published private(set) var observations: [PerformanceObservation] = []
    private var window = PerformanceWindow()
    private var active: String?
    private let defaults: UserDefaults
    private let key = "native.performanceHistory.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), data.count <= 128 * 1024,
           let rows = try? JSONDecoder().decode([PerformanceObservation].self, from: data) { observations = Array(rows.prefix(40)) }
    }
    func begin(game: Game) { active = game.id + ":" + game.coreID; window = PerformanceWindow(missing: veta_audio_underruns(), dropped: veta_audio_dropped()) }
    func end() { active = nil; window = PerformanceWindow() }
    func clearHistory() {
        observations = []
        defaults.removeObject(forKey: key)
        // Do not republish samples collected before the user's deletion.
        end()
    }
    func exportReport(at date: Date = Date(), bundle: Bundle = .main) throws -> Data {
        let report = PerformanceReport(schemaVersion: 1, exportedAt: date,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            observations: observations)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
    func sample(game: Game, elapsed: Double, frames: UInt64, p95: Double, targetFPS: Double, audioMissing: UInt64, audioDropped: UInt64) {
        guard active == game.id + ":" + game.coreID, targetFPS.isFinite, targetFPS > 0 else { return }
        window.add(elapsed: elapsed, frames: frames, p95: p95, thermal: ProcessInfo.processInfo.thermalState.rawValue, missing: audioMissing, dropped: audioDropped)
        guard window.isReady else { return }
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        let row = PerformanceObservation(gameID: game.id, gameName: game.name, coreID: game.coreID, consoleName: game.console.name,
            date: Date(), seconds: window.elapsed, fps: window.fps, targetFPS: targetFPS, worstWindowP95: window.p95,
            peakThermalState: window.thermal, audioMissing: window.missing, audioDropped: window.dropped,
            simulator: simulator, os: ProcessInfo.processInfo.operatingSystemVersionString)
        observations.removeAll { $0.id == row.id }; observations.insert(row, at: 0); observations = Array(observations.prefix(40))
        if let data = try? JSONEncoder().encode(observations) { defaults.set(data, forKey: key) }
        window = PerformanceWindow(missing: audioMissing, dropped: audioDropped)
    }
}
struct PerformanceHistoryView: View {
    @ObservedObject private var history = DevicePerformance.shared
    @State private var report: PerformanceReportDocument?
    @State private var exporting = false
    @State private var confirmClear = false
    @State private var exportFailed = false
    var body: some View {
        List {
            Section {
                Text("VETA registra ventanas de 30 segundos mientras juegas. Los datos quedan en este dispositivo y no se envían a ningún servidor.")
                Text("Estas medidas describen una sesión; no garantizan compatibilidad ni rendimiento de todos los juegos. La temperatura y la carga del equipo pueden cambiar el resultado.").font(.footnote)
            }.listRowBackground(VetaTheme.panel)
            if !history.observations.isEmpty {
                Section {
                    Button {
                        do { report = PerformanceReportDocument(data: try history.exportReport()); exporting = true }
                        catch { exportFailed = true }
                    } label: { Label("Exportar informe", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("performance-export")
                    Button("Borrar historial", role: .destructive) { confirmClear = true }
                        .accessibilityIdentifier("performance-clear")
                } footer: {
                    Text("El informe incluye los nombres de los juegos y las mediciones guardadas. Tú eliges dónde guardarlo.")
                }.listRowBackground(VetaTheme.panel)
            }
            if history.observations.isEmpty { Text("Juega al menos 30 segundos sin pausar para registrar una medición.").listRowBackground(VetaTheme.panel) }
            ForEach(history.observations) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: row.gameName).font(.headline)
                    Text(verbatim: row.consoleName + " · " + row.coreID).font(.caption)
                    Text(row.date, style: .date).font(.caption)
                    Text(verbatim: String(format: "%.1f / %.2f FPS · %.1f s · max p95 %.2f ms", row.fps, row.targetFPS, row.seconds, row.worstWindowP95)).font(.caption.monospaced())
                    Text(verbatim: L10n.format("Audio: %d muestras faltantes, %d descartadas", Int(row.audioMissing), Int(row.audioDropped))).font(.caption)
                    Text(verbatim: L10n.format("Temperatura máxima: %@", L10n.text(["Normal", "Elevada", "Alta", "Crítica"][min(3, max(0, row.peakThermalState))]))).font(.caption)
                    if row.simulator { Text("Medido en simulador: no valida el iPhone.").font(.caption).foregroundStyle(VetaTheme.orange) }
                }.listRowBackground(VetaTheme.panel)
            }
        }.vetaForm().tint(VetaTheme.mint).navigationTitle("Rendimiento observado").navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $exporting, document: report, contentType: .json, defaultFilename: "VETA-rendimiento") { result in
                if case .failure(let error) = result {
                    let failure = error as NSError
                    if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError { exportFailed = true }
                }
                report = nil
            }
            .confirmationDialog("¿Borrar el historial de rendimiento?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Borrar historial", role: .destructive) { history.clearHistory() }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Se eliminarán las mediciones de este dispositivo. Los informes que hayas exportado se conservan.")
            }
            .alert("No se pudo exportar el informe.", isPresented: $exportFailed) { Button("Aceptar", role: .cancel) { } }
    }
}
