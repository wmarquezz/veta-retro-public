import XCTest
@testable import VetaNative

final class PerformanceTests: XCTestCase {
    @MainActor func testExportPreservesMeasurementsAndSimulatorProvenanceWithoutChangingHistory() throws {
        let suite = "veta-performance-export-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let history = DevicePerformance(defaults: defaults), game = Game(id: "export-fixture", name: "Prueba 日本語")
        history.begin(game: game)
        history.sample(game: game, elapsed: 30, frames: 1500, p95: 7, targetFPS: 60, audioMissing: 0, audioDropped: 0)
        let date = Date(timeIntervalSince1970: 12345)
        let data = try history.exportReport(at: date)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(PerformanceReport.self, from: data)
        XCTAssertEqual(report.schemaVersion, 1); XCTAssertEqual(report.exportedAt, date)
        XCTAssertFalse(report.appBuild.isEmpty); XCTAssertFalse(report.appVersion.isEmpty)
        let row = try XCTUnwrap(report.observations.first)
        XCTAssertEqual(row.gameName, game.name); XCTAssertEqual(row.coreID, game.coreID)
        XCTAssertEqual(row.fps, 50); XCTAssertEqual(row.seconds, 30); XCTAssertEqual(row.targetFPS, 60)
        XCTAssertEqual(row.worstWindowP95, 7)
        #if targetEnvironment(simulator)
        XCTAssertTrue(row.simulator)
        #else
        XCTAssertFalse(row.simulator)
        #endif
        XCTAssertEqual(history.observations.count, 1)
        XCTAssertEqual(DevicePerformance(defaults: defaults).observations.count, 1)
        history.clearHistory()
        // An exported snapshot survives deleting the in-app history.
        XCTAssertEqual(try decoder.decode(PerformanceReport.self, from: data).observations.count, 1)
        XCTAssertTrue(try decoder.decode(PerformanceReport.self, from: history.exportReport()).observations.isEmpty)
    }
    @MainActor func testClearingHistoryPersistsAndDiscardsPartialWindowWithoutRemovingPreferences() throws {
        let suite = "veta-performance-clear-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("es", forKey: AppLanguage.preferenceKey)
        let history = DevicePerformance(defaults: defaults), game = Game(id: "clear-fixture", name: "Fixture")
        history.begin(game: game)
        history.sample(game: game, elapsed: 30, frames: 1800, p95: 2, targetFPS: 60, audioMissing: 0, audioDropped: 0)
        history.sample(game: game, elapsed: 29, frames: 1740, p95: 2, targetFPS: 60, audioMissing: 0, audioDropped: 0)
        history.clearHistory()
        XCTAssertTrue(history.observations.isEmpty)
        XCTAssertTrue(DevicePerformance(defaults: defaults).observations.isEmpty)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "es")
        history.sample(game: game, elapsed: 1, frames: 60, p95: 2, targetFPS: 60, audioMissing: 0, audioDropped: 0)
        XCTAssertTrue(history.observations.isEmpty)
        history.begin(game: game)
        history.sample(game: game, elapsed: 30, frames: 1800, p95: 2, targetFPS: 60, audioMissing: 0, audioDropped: 0)
        XCTAssertEqual(history.observations.count, 1)
    }
    func testWindowsRequireRealElapsedTimeAndIgnoreInvalidSamples() {
        var window = PerformanceWindow()
        window.add(elapsed: .nan, frames: 100, p95: 1, thermal: 0, missing: 0, dropped: 0)
        window.add(elapsed: 0, frames: 100, p95: 1, thermal: 0, missing: 0, dropped: 0)
        XCTAssertEqual(window.elapsed, 0)
        for i in 0..<29 { window.add(elapsed: 1, frames: 50, p95: Double(i), thermal: i > 20 ? 2 : 0, missing: UInt64(i), dropped: 0) }
        XCTAssertFalse(window.isReady)
        window.add(elapsed: 1, frames: 50, p95: 9, thermal: 0, missing: 30, dropped: 2)
        XCTAssertTrue(window.isReady); XCTAssertEqual(window.fps, 50); XCTAssertEqual(window.thermal, 2)
        XCTAssertEqual(window.p95, 28); XCTAssertEqual(window.missing, 30); XCTAssertEqual(window.dropped, 2)
        // Core resets can lower counters; unsigned subtraction must not create huge losses.
        window.add(elapsed: 1, frames: 50, p95: 1, thermal: 0, missing: 0, dropped: 0)
        XCTAssertEqual(window.missing, 30); XCTAssertEqual(window.dropped, 2)
    }
    @MainActor func testRecordsStayLocalSeparateCoresAndExcludePausedWindows() throws {
        let suite = "veta-performance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let history = DevicePerformance(defaults: defaults), game = Game(id: "fixture", name: "Fixture")
        history.begin(game: game)
        history.sample(game: game, elapsed: 15, frames: 900, p95: 2, targetFPS: 60, audioMissing: 0, audioDropped: 0)
        history.end(); XCTAssertTrue(history.observations.isEmpty)
        history.begin(game: game)
        for _ in 0..<30 { history.sample(game: game, elapsed: 1, frames: 60, p95: 2, targetFPS: 60, audioMissing: 0, audioDropped: 0) }
        XCTAssertEqual(history.observations.count, 1)
        XCTAssertEqual(DevicePerformance(defaults: defaults).observations.first?.fps, 60)
        var ds = Game(id: "same", name: "DS", console: .ds)
        for engine in DSGameEngine.allCases {
            ds.dsEngine = engine; history.begin(game: ds)
            history.sample(game: ds, elapsed: 30, frames: 1800, p95: 3, targetFPS: 60, audioMissing: 0, audioDropped: 0)
        }
        XCTAssertEqual(history.observations.count, 3)
    }
}
