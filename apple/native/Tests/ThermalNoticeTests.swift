import XCTest
@testable import VetaNative

final class ThermalNoticeTests: XCTestCase {
    func testOnlyHighAndCriticalConditionsShowAdvice() {
        var state = ThermalNoticeState()
        XCTAssertFalse(state.visible)
        state.update(.nominal); XCTAssertFalse(state.visible)
        state.update(.fair); XCTAssertFalse(state.visible)
        state.update(.serious); XCTAssertTrue(state.visible); XCTAssertEqual(state.level,.high)
        state.update(.critical); XCTAssertEqual(state.level,.critical); XCTAssertTrue(state.visible)
    }
    func testMinimizedWarningDoesNotRepeatButEscalationReopensIt() {
        var state = ThermalNoticeState()
        state.update(.serious); state.minimize(); XCTAssertTrue(state.collapsed)
        state.update(.serious); XCTAssertTrue(state.collapsed)
        state.update(.critical); XCTAssertFalse(state.collapsed)
        state.minimize(); state.update(.critical); XCTAssertTrue(state.collapsed)
        state.update(.serious); XCTAssertTrue(state.collapsed)
        state.expand(); XCTAssertFalse(state.collapsed)
    }
    func testCoolingResetsWarningForNextEpisode() {
        var state = ThermalNoticeState()
        state.update(.critical); state.minimize()
        state.update(.fair); XCTAssertFalse(state.visible); XCTAssertFalse(state.collapsed)
        state.update(.serious); XCTAssertTrue(state.visible); XCTAssertFalse(state.collapsed)
        state.update(.nominal); state.minimize(); XCTAssertFalse(state.visible); XCTAssertFalse(state.collapsed)
    }
}
