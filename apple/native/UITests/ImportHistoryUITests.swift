import XCTest
final class ImportHistoryUITests:XCTestCase {
    override func setUp() {continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait}
    private func shot(_ name:String) {let a=XCTAttachment(screenshot:XCUIScreen.main.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)}
    func testHistoryListsRejectedFilesAndReasonsAfterRelaunch() {
        let app=XCUIApplication();app.launchArguments=["-native.language","es"]
        app.launch();XCTAssertTrue(app.buttons["toolbar-import"].waitForExistence(timeout:15));app.buttons["toolbar-import"].tap()
        let history=app.buttons["import-history"]
        for _ in 0..<8 {if history.isHittable {break};app.swipeUp()}
        XCTAssertTrue(history.isHittable);history.tap()
        let report=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","import-report-")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout:5));shot("204-import-history");report.tap()
        XCTAssertTrue(app.staticTexts["Broken.zip"].waitForExistence(timeout:5));XCTAssertTrue(app.staticTexts["Invalid.nes"].exists)
        XCTAssertTrue(app.staticTexts["El ZIP contiene otro ZIP. Descomprímelo antes de importar."].exists)
        shot("204-import-issues")
        XCUIDevice.shared.orientation = .landscapeLeft;Thread.sleep(forTimeInterval:1);shot("204-history-landscape")
        app.terminate();XCUIDevice.shared.orientation = .portrait
        app.launchArguments=["-native.language","es","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();app.buttons["toolbar-import"].tap()
        for _ in 0..<12 {if history.isHittable {break};app.swipeUp()}
        XCTAssertTrue(history.isHittable);history.tap();XCTAssertTrue(report.waitForExistence(timeout:5));shot("204-history-large-text")
        app.terminate()
    }
}
