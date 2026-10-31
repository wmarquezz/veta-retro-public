import XCTest
final class CloudCatalogUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait}
    private func shot(_ name:String){let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)}
    func testCompactRowPreviewDoesNotSelectGame() {
        let app = XCUIApplication()
        app.launchArguments = ["--catalog-preview", "-native.language", "es"]
        app.launch()
        let open = app.buttons["catalog-open-catalog-console:gba"]
        XCTAssertTrue(open.waitForExistence(timeout: 20)); open.tap()
        let game = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog-game-")).firstMatch
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog-cover-")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 5)); XCTAssertTrue(cover.exists)
        XCTAssertGreaterThanOrEqual(cover.frame.height, 44)
        XCTAssertLessThanOrEqual(cover.frame.height, 60)
        XCTAssertEqual(game.value as? String, "Sin seleccionar")
        shot("209-compact-portrait")
        cover.tap(); XCTAssertTrue(app.navigationBars["Vista previa"].waitForExistence(timeout: 5))
        shot("209-cover-preview"); app.buttons["Cerrar"].tap()
        XCTAssertEqual(game.value as? String, "Sin seleccionar")
        game.tap(); XCTAssertEqual(game.value as? String, "Seleccionado")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(cover.waitForExistence(timeout: 5)); app.collectionViews.firstMatch.swipeUp(); XCTAssertTrue(cover.isHittable); shot("209-compact-landscape")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
    }
    func testCompactRowWithLargestText() {
        let app = XCUIApplication()
        app.launchArguments = ["--catalog-preview", "-native.language", "es", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let open = app.buttons["catalog-open-catalog-console:gba"]
        XCTAssertTrue(app.buttons["Seleccionar todo"].waitForExistence(timeout: 20))
        for _ in 0..<5 { if open.exists && open.isHittable { break }; app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(open.isHittable); open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog-cover-")).firstMatch
        for _ in 0..<6 { if cover.exists && cover.isHittable { break }; app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(cover.isHittable)
        shot("209-largest-text"); cover.tap()
        XCTAssertTrue(app.navigationBars["Vista previa"].waitForExistence(timeout: 5)); app.buttons["Cerrar"].tap(); app.terminate()
    }
    func testCatalogSearchInstalledAndConsoleImport() {
        let app=XCUIApplication();app.launchArguments=["--catalog-preview","-native.language","es"];app.launch()
        let gb=app.buttons["catalog-select-catalog-console:gb"],gba=app.buttons["catalog-select-catalog-console:gba"]
        XCTAssertTrue(gba.waitForExistence(timeout:20));XCTAssertFalse(gb.isEnabled);XCTAssertTrue(gba.isEnabled)
        shot("206-catalog-consoles")
        let search=app.searchFields.firstMatch;search.tap();search.typeText("A_KANOID")
        let installed=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","catalog-game-")).firstMatch
        XCTAssertTrue(installed.waitForExistence(timeout:5));XCTAssertFalse(installed.isEnabled);shot("206-catalog-installed")
        search.tap();search.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:8)+"\n")
        XCTAssertTrue(gba.waitForExistence(timeout:5));gba.tap()
        app.buttons["Importar selección"].tap();let alert=app.alerts["Descargar e importar"]
        XCTAssertTrue(alert.waitForExistence(timeout:5));alert.buttons["Importar"].tap()
        let imported=NSPredicate(format:"enabled == false");expectation(for:imported,evaluatedWith:gba);waitForExpectations(timeout:30)
        XCTAssertFalse(app.buttons["Importar disponibles"].isEnabled);shot("206-catalog-imported")
        XCUIDevice.shared.orientation = .landscapeLeft;shot("206-catalog-landscape")
        app.terminate();XCUIDevice.shared.orientation = .portrait
    }
}
