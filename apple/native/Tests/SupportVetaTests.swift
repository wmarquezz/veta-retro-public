import XCTest
import StoreKit
import StoreKitTest
@testable import VetaNative

@MainActor final class SupportVetaTests: XCTestCase {
    private var session: SKTestSession!
    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "VetaSupport", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // Some simulator runtimes reject configuration writes (SKInternalErrorDomain 3).
        // Never leave an unattended purchase test waiting for an interactive sheet.
        try XCTSkipUnless(session.disableDialogs, "StoreKitTest did not apply disableDialogs; automated purchase/error injection is unavailable on this runtime. Use the preview scheme for manual testing.")
    }
    override func tearDownWithError() throws {
        session?.clearTransactions()
        session?.resetToDefaultState()
        session = nil
    }
    private func loadedStore() async -> VetaSupportStore {
        let store = VetaSupportStore(listenForTransactions: false)
        await store.load()
        return store
    }
    func testThreeApprovedAmountsAreRepeatableConsumables() async throws {
        let store = await loadedStore()
        XCTAssertEqual(store.products.count, 3)
        for (tier, price) in zip(VetaContribution.allCases, ["4990", "9990", "15990"]) {
            let product = try XCTUnwrap(store.product(for: tier))
            XCTAssertEqual(product.price, Decimal(string: price))
            XCTAssertEqual(product.type, .consumable)
            XCTAssertNil(product.subscription)
            XCTAssertFalse(product.displayPrice.isEmpty)
            await store.purchase(tier)
            XCTAssertEqual(store.feedback, .thanks)
            XCTAssertFalse(store.busy)
        }
        await store.purchase(.small)
        XCTAssertEqual(store.feedback, .thanks)
        XCTAssertEqual(session.allTransactions().filter { $0.productIdentifier == VetaContribution.small.id && $0.state == .purchased }.count, 2)
        XCTAssertTrue(FeatureAccess.catalog.allSatisfy { $0.classification == .free && FeatureAccess.isAccessible($0.id) })
        var unfinished = 0
        for await _ in StoreKit.Transaction.unfinished { unfinished += 1 }
        XCTAssertEqual(unfinished, 0)
    }
    func testCancellationNeverThanksOrBlocksUse() async throws {
        let store = await loadedStore()
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await store.purchase(.medium)
        XCTAssertEqual(store.feedback, .cancelled)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(session.allTransactions().isEmpty)
        XCTAssertTrue(FeatureAccess.catalog.allSatisfy { FeatureAccess.isAccessible($0.id) })
    }
    func testFailedPurchaseCanBeRetriedWithoutAutomaticPayment() async throws {
        let store = await loadedStore()
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        await store.purchase(.large)
        XCTAssertEqual(store.feedback, .failed)
        XCTAssertFalse(store.busy)
        XCTAssertTrue(session.allTransactions().isEmpty)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        await store.purchase(.large)
        XCTAssertEqual(store.feedback, .thanks)
        XCTAssertEqual(session.allTransactions().count, 1)
    }
    func testProductLookupFailureAndRecovery() async throws {
        let store = VetaSupportStore(listenForTransactions: false)
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await store.load()
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.products.isEmpty)
        await store.purchase(.small)
        XCTAssertEqual(store.feedback, .unavailable)
        XCTAssertTrue(session.allTransactions().isEmpty)
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        await store.load()
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.products.count, 3)
    }
    func testPendingApprovalIsDeliveredByTransactionListener() async throws {
        let store = VetaSupportStore.shared
        await store.load()
        session.askToBuyEnabled = true
        await store.purchase(.small)
        XCTAssertEqual(store.feedback, .pending)
        let pending = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        let deadline = Date().addingTimeInterval(8)
        while store.feedback != .thanks && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(store.feedback, .thanks)
        XCTAssertFalse(store.busy)
    }
    func testUnverifiedPurchaseDoesNotDisplayThanks() async throws {
        let store = await loadedStore()
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        await store.purchase(.small)
        XCTAssertEqual(store.feedback, .unverified)
        XCTAssertFalse(store.busy)
    }
}
