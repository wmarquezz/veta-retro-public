import XCTest
final class CloudCatalogUITests:XCTestCase {
    override func setUp(){continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait}
    private func shot(_ name:String){let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)}
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
