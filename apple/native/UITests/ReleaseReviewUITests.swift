import XCTest

final class ReleaseReviewUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    private func start(large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-native.language", "es"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        return app
    }
    private func reveal(_ item: XCUIElement, app: XCUIApplication) {
        for _ in 0..<30 {
            if item.isHittable { return }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        shot("202-unreachable-control")
        XCTAssertTrue(item.isHittable, item.description)
    }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func testPublicSettingsScreensAndUnavailableFeatures() {
        for entry in ["feature-access", "device-readiness", "Mandos y jugadores", "personal-skins-main", "Jugar juntos", "TV y pantalla completa", "support-veta", "privacy-details", "publication-support", "language-settings"] {
            let app = start()
            app.buttons["open-settings"].tap()
            let target = app.buttons[entry]; reveal(target, app: app); target.tap()
            if entry == "feature-access" { XCTAssertTrue(app.staticTexts["Funciones gratuitas"].exists); XCTAssertFalse(app.staticTexts["Multijugador en línea"].exists) }
            if entry == "Jugar juntos" { XCTAssertTrue(app.buttons["Crear sala cercana"].exists); XCTAssertFalse(app.buttons["Buscar partida por Game Center"].exists) }
            shot("202-settings-" + entry)
            XCUIDevice.shared.orientation = .landscapeLeft
            shot("202-landscape-" + entry)
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
    }
    func testImportHelpSharedLinkAndLargeText() {
        let app = start(large: true)
        app.buttons["toolbar-import"].tap()
        XCTAssertTrue(app.buttons["import-source-files"].waitForExistence(timeout: 5))
        shot("202-import-large-text")
        let shared = app.buttons["import-source-shared"]; reveal(shared, app: app); shared.tap()
        XCTAssertTrue(app.textFields["shared-link-url"].waitForExistence(timeout: 5))
        let open = app.buttons["shared-link-open"]; reveal(open, app: app)
        XCTAssertFalse(open.isEnabled)
        shot("202-shared-large-text")
        app.buttons["Cerrar"].tap()
        XCTAssertTrue(app.buttons["toolbar-import"].waitForExistence(timeout: 5)); app.buttons["toolbar-import"].tap()
        let help = app.buttons["import-source-help"]; reveal(help, app: app); help.tap()
        shot("202-import-help-large-text")
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("202-import-help-large-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }
}
