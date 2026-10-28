import XCTest
#if VETA_JIT_DEVELOPMENT
@testable import VetaJITLab
#else
@testable import VetaNative
#endif

final class ReadinessLocalizationTests: XCTestCase {
    // Check the actual host bundle, not a synthetic "all included" snapshot.
    // A replaced core must pass the same gate used by the normal library launch.
    func testReplacementCoresPassInstalledBundlePreflight() throws {
        let root = try XCTUnwrap(Bundle.main.privateFrameworksURL)
        let atari = FileManager.default.fileExists(atPath: root.appendingPathComponent("TIACore.framework/TIACore").path) ? "TIACore" : "StellaCore"
        let readiness = DeviceReadiness.capture()
        for (console, name): (GameConsole, String) in [(.atari2600,atari),(.snes,"BSNESCore"),(.megaDrive,"JGenesisCore"),(.masterSystem,"JGenesisCore"),(.gameGear,"JGenesisCore")] {
            XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("\(name).framework/\(name)").path),name)
            XCTAssertEqual(DeviceReadiness.frameworkName(for:console),name)
            XCTAssertTrue(readiness.snapshot.includedConsoles.contains(console),console.rawValue)
            XCTAssertTrue(readiness.assess(console:console).canAttemptLaunch,console.rawValue)
        }
    }
    private func snapshot(jit: Bool = false, experimental: Bool = false, simulator: Bool = false) -> DeviceReadiness.Snapshot {
        .init(metalAvailable: true, physicalMemory: 8 * 1024 * 1024 * 1024, processorCount: 6,
              osVersion: .init(majorVersion: 16, minorVersion: 4, patchVersion: 0), simulator: simulator,
              jitAvailable: jit, experimentalBuild: experimental, includedConsoles: Set(GameConsole.allCases))
    }
    func testPublicBuildCannotTreatJITAsAnEntitlement() {
        let publicBuild = DeviceReadiness(snapshot: snapshot(jit: true))
        XCTAssertFalse(publicBuild.assess(console: .ps2).canAttemptLaunch)
        XCTAssertEqual(publicBuild.assess(console: .ps2).status, .requiresJIT)
        XCTAssertTrue(publicBuild.assess(console: .nes).canAttemptLaunch)
        let experimental = DeviceReadiness(snapshot: snapshot(jit: true, experimental: true))
        XCTAssertTrue(experimental.assess(console: .ps2).canAttemptLaunch)
        XCTAssertEqual(experimental.assess(console: .ps2).status, .experimental)
    }
    func testSimulatorNeverCountsAsPhysicalValidation() {
        let assessment = DeviceReadiness(snapshot: snapshot(simulator: true)).assess(console: .gamecube)
        XCTAssertTrue(assessment.canAttemptLaunch)
        XCTAssertTrue(assessment.reasons.contains("El simulador no acredita rendimiento en un iPhone."))
        XCTAssertTrue(assessment.reasons.contains("Compatibilidad del juego no validada."))
    }
    func testMissingCoreAndEmptyFileBlockLaunchWithoutCreatingFiles() throws {
        var facts = snapshot(simulator: true)
        facts.includedConsoles.remove(.ps2)
        let checker = DeviceReadiness(snapshot: facts)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let game = folder.appendingPathComponent("test.elf")
        try Data().write(to: game)
        let result = checker.preflight(console: .ps2, gameURL: game, systemDirectory: folder.appendingPathComponent("System"))
        XCTAssertFalse(result.canLaunch)
        XCTAssertEqual(result.blockers.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["test.elf"])
        facts.includedConsoles.insert(.ps2)
        try Data([1, 2, 3]).write(to: game)
        XCTAssertTrue(DeviceReadiness(snapshot: facts).preflight(console: .ps2, gameURL: game, systemDirectory: folder).canLaunch)
    }
    func testSelectedDSEngineChecksItsOwnFrameworkAndMinimumOS() {
        var facts = snapshot(simulator: true)
        var game = Game(id: "ds-test", name: "DS", console: .ds)
        game.dsEngine = .melonDS
        XCTAssertFalse(DeviceReadiness(snapshot: facts).assess(game: game).canAttemptLaunch)
        facts.includedDSEngines.insert(.melonDS)
        XCTAssertFalse(DeviceReadiness(snapshot: facts).assess(game: game).canAttemptLaunch) // iOS 16.4
        facts.osVersion = .init(majorVersion: 17, minorVersion: 0, patchVersion: 0)
        facts.includedConsoles.remove(.ds)
        facts.includedDSEngines.remove(.desmume)
        let alternate = DeviceReadiness(snapshot: facts).assess(game: game)
        XCTAssertTrue(alternate.canAttemptLaunch)
        XCTAssertEqual(alternate.status, .experimental)
        game.dsEngine = .desmume
        XCTAssertFalse(DeviceReadiness(snapshot: facts).assess(game: game).canAttemptLaunch)
    }
    func testDevelopmentCatalogHasNoInventedPaidEntitlements() {
        XCTAssertTrue(FeatureAccess.developmentUnlocked)
        XCTAssertEqual(Set(FeatureAccess.catalog.map(\.id)).count, FeatureAccess.catalog.count)
        XCTAssertTrue(FeatureAccess.catalog.allSatisfy { $0.classification == .undecided && FeatureAccess.isAccessible($0.id) })
        XCTAssertFalse(FeatureAccess.isAccessible("unknown-product-id"))
    }
    func testEightCompleteCatalogsAndFallback() {
        let spanish = L10n.catalog(.spanish)
        XCTAssertGreaterThan(spanish.count, 150)
        for language in AppLanguage.allCases {
            let catalog = L10n.catalog(language)
            XCTAssertEqual(Set(catalog.keys), Set(spanish.keys), language.rawValue)
            XCTAssertTrue(L10n.missingKeys(required: Set(spanish.keys), catalog: catalog).isEmpty, language.rawValue)
        }
        XCTAssertEqual(L10n.text("missing.test.key", language: .arabic), "missing.test.key")
        XCTAssertEqual(L10n.text("Ajustes", language: .english), "Settings")
        XCTAssertEqual(L10n.text("Ajustes", language: .chinese), "设置")
        XCTAssertEqual(AppLanguage.arabic.layoutDirection, .rightToLeft)
        XCTAssertEqual(AppLanguage.french.layoutDirection, .leftToRight)
    }
    func testDynamicLabelsUseSelectedLanguageAndPreserveGameNames() {
        XCTAssertEqual(L10n.gameCount(1, language: .english), "1 game")
        XCTAssertEqual(L10n.gameCount(3, language: .french), "3 jeux")
        XCTAssertEqual(L10n.format("Jugar %@", "Thwaite", language: .english), "Play Thwaite")
        XCTAssertEqual(L10n.format("Carcasa de %@", "NES", language: .chinese), "NES 外壳")
        XCTAssertEqual(L10n.format("¿Agregar %@?", "Game Boy", language: .arabic), "إضافة \u{2068}Game Boy\u{2069}؟")
    }
    func testAutomaticLanguageUsesSupportedSystemPreferencesUntilExplicitlySelected() {
        XCTAssertEqual(AppLanguage.resolve(stored: nil, preferredLanguages: ["es-CL", "en-US"]), .spanish)
        XCTAssertEqual(AppLanguage.resolve(stored: nil, preferredLanguages: ["de-DE", "fr-CA"]), .german)
        XCTAssertEqual(AppLanguage.resolve(stored: nil, preferredLanguages: ["it-IT", "en-US"]), .italian)
        XCTAssertEqual(AppLanguage.resolve(stored: nil, preferredLanguages: ["zh-Hans-CN"]), .chinese)
        XCTAssertEqual(AppLanguage.resolve(stored: nil, preferredLanguages: ["zh-Hant-TW", "en-US"]), .english)
        XCTAssertEqual(AppLanguage.resolve(stored: "ar", preferredLanguages: ["es-CL"]), .arabic)
        XCTAssertEqual(AppLanguage.resolve(stored: nil, preferredLanguages: ["ja-JP"]), .english)
    }
    func testLegacyErrorsLocalizeContextWithoutChangingFilenamesOrUnknownEngineDetails() {
        XCTAssertEqual(L10n.text("Falta la pista Intro.bin.", language: .english), "Track Intro.bin is missing.")
        XCTAssertEqual(L10n.text("No se pudo guardar al pausar: Abre un juego primero.", language: .english), "Could not save when pausing: Open a game first.")
        XCTAssertEqual(L10n.text("Audio: Engine code -47", language: .french), "Audio : Engine code -47")
    }
    @MainActor func testLanguageSelectionPersistsWithoutChangingSystemLanguage() {
        let suite = "veta.localization.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LocalizationSettings(defaults: defaults, preferredLanguages: ["es-CL"])
        let systemLanguages = defaults.stringArray(forKey: "AppleLanguages")
        XCTAssertEqual(settings.selectedLanguage, .spanish)
        settings.selectedLanguage = .arabic
        XCTAssertEqual(LocalizationSettings(defaults: defaults).selectedLanguage, .arabic)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), systemLanguages)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
    }
}
