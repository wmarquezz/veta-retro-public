import XCTest

/// Run against a simulator seeded with 500 disposable Atari entries and one NES
/// entry. Never run this destructive fixture test against a user's device/library.
final class BulkGameManagementUITests:XCTestCase {
    override func setUp() {continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait}
    private func shot(_ name:String) {let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)}
    private func reveal(_ element:XCUIElement,app:XCUIApplication) {
        for _ in 0..<12 {
            if element.isHittable{return}
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    func testSelectSearchCancelDeleteSubsetAndWholeConsole()throws {
        #if targetEnvironment(simulator)
        let app=XCUIApplication()
        app.launchArguments=["-native.language","es","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-Consolas"].waitForExistence(timeout:15));app.buttons["tab-Consolas"].tap()
        let atari=app.buttons["console-games-atari2600"]
        XCTAssertTrue(atari.waitForExistence(timeout:5));atari.tap()
        app.buttons["manage-console-games"].tap()
        let count=app.staticTexts["bulk-selection-count"],remove=app.buttons["bulk-delete"]
        XCTAssertTrue(count.waitForExistence(timeout:5));XCTAssertEqual(count.label,"0 seleccionados de 500 juegos")
        XCTAssertFalse(remove.isEnabled);shot("203-management-portrait")
        app.buttons["Fixture 000"].tap();app.buttons["Fixture 001"].tap()
        XCTAssertEqual(count.label,"2 seleccionados de 500 juegos")
        remove.tap();XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:3));shot("203-delete-confirmation")
        app.alerts.buttons["Cancelar"].tap();XCTAssertEqual(count.label,"2 seleccionados de 500 juegos")
        remove.tap();app.alerts.buttons["bulk-confirm-delete"].firstMatch.tap()
        XCTAssertTrue(count.waitForExistence(timeout:5));XCTAssertEqual(count.label,"0 seleccionados de 498 juegos")
        XCTAssertFalse(app.buttons["Fixture 000"].exists);XCTAssertFalse(app.buttons["Fixture 001"].exists)
        app.buttons["bulk-close"].tap();app.terminate();app.launch()
        let menu=app.buttons["manage-library-games"];reveal(menu,app:app);menu.tap();app.buttons["Atari 2600"].tap()
        XCTAssertEqual(count.label,"0 seleccionados de 498 juegos")
        let search=app.textFields["bulk-game-search"];search.tap();search.typeText("Fixture 010\n")
        app.buttons["Fixture 010"].tap()
        XCTAssertEqual(count.label,"1 seleccionados de 498 juegos")
        app.buttons["bulk-select-all"].tap()
        XCTAssertEqual(count.label,"498 seleccionados de 498 juegos")
        app.buttons["bulk-deselect-all"].tap();XCTAssertFalse(remove.isEnabled)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval:1)
        shot("203-management-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["bulk-close"].tap();app.terminate()
        app.launchArguments=["-native.language","es","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();reveal(menu,app:app);menu.tap();app.buttons["Atari 2600"].tap()
        XCTAssertTrue(remove.waitForExistence(timeout:5));shot("203-management-large-text")
        let selectAll=app.buttons["bulk-select-all"];reveal(selectAll,app:app);selectAll.tap()
        XCTAssertTrue(remove.isEnabled);remove.tap();shot("203-confirmation-large-text")
        app.alerts.buttons["bulk-confirm-delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout:10))
        reveal(menu,app:app);menu.tap()
        XCTAssertFalse(app.buttons["Atari 2600"].exists)
        XCTAssertTrue(app.buttons["Nintendo Entertainment System"].exists || app.buttons["NES"].exists)
        shot("203-atari-removed-nes-kept")
        app.terminate()
        #else
        throw XCTSkip("Destructive UI fixture tests are simulator-only")
        #endif
    }
}
