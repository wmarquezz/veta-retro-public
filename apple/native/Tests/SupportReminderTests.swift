import XCTest
@testable import VetaNative

@MainActor final class SupportReminderTests: XCTestCase {
    func testAcknowledgementSurvivesNewStoreAndDoesNotChangeAnotherInstallation() {
        let name = "VetaSupportReminderTests." + UUID().uuidString
        let otherName = name + ".other"
        let defaults = UserDefaults(suiteName: name)!
        let other = UserDefaults(suiteName: otherName)!
        defer { defaults.removePersistentDomain(forName: name); other.removePersistentDomain(forName: otherName) }
        let initial = VetaSupportStore(listenForTransactions: false, defaults: defaults)
        XCTAssertFalse(initial.hasContributed)
        initial.recordVerifiedContribution()
        XCTAssertTrue(initial.hasContributed)
        let reopened = VetaSupportStore(listenForTransactions: false, defaults: defaults)
        XCTAssertTrue(reopened.hasContributed)
        XCTAssertFalse(VetaSupportStore(listenForTransactions: false, defaults: other).hasContributed)
        XCTAssertTrue(FeatureAccess.catalog.allSatisfy { FeatureAccess.isAccessible($0.id) })
    }
}
