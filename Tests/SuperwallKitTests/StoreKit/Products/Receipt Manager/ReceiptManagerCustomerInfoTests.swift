import Foundation
import XCTest

@testable import SuperwallKit

final class ReceiptManagerCustomerInfoTests: XCTestCase {
  @MainActor
  func testExpiredDeviceEntitlementDoesNotReplaceExternalEntitlement() async throws {
    try await checkExternalEntitlementSurvivesRefresh(deviceIsActive: false)
  }

  @MainActor
  func testActiveDeviceEntitlementKeepsProductMappingsAndExternalMetadata() async throws {
    try await checkExternalEntitlementSurvivesRefresh(deviceIsActive: true)
  }

  @MainActor
  private func checkExternalEntitlementSurvivesRefresh(deviceIsActive: Bool) async throws {
    let fixture = ReceiptRefreshFixture(deviceIsActive: deviceIsActive)
    let external = fixture.externalEntitlement
    fixture.superwall.subscriptionStatus = .active([external])

    await fixture.refresh()

    let customerInfo = fixture.superwall.customerInfo
    XCTAssertEqual(customerInfo.entitlements.count, 1)
    let pro = try XCTUnwrap(customerInfo.entitlements.first)
    XCTAssertEqual(pro.id, "pro")
    XCTAssertTrue(pro.isActive)
    XCTAssertEqual(pro.store, external.store)
    XCTAssertEqual(pro.expiresAt, external.expiresAt)
    XCTAssertEqual(pro.willRenew, external.willRenew)
    XCTAssertEqual(pro.state, external.state)
    XCTAssertEqual(pro.offerType, external.offerType)
    XCTAssertNil(pro.latestProductId)
    XCTAssertEqual(pro.productIds, ["weekly", "annual"])
    XCTAssertEqual(customerInfo.subscriptions, fixture.snapshot.customerInfo.subscriptions)
    XCTAssertEqual(fixture.superwall.subscriptionStatus, .active([external]))

    // Verify the lookup consumed by product fetching and restore checks, not just
    // the CustomerInfo payload. Both products must still map to the external pro.
    for productId in ["weekly", "annual"] {
      let mapped = fixture.superwall.entitlements.byProductId(productId)
      XCTAssertEqual(mapped.count, 1)
      XCTAssertEqual(mapped.first, pro)
    }
    let savedDeviceInfo = fixture.storage.get(LatestDeviceCustomerInfo.self)
    XCTAssertEqual(savedDeviceInfo, fixture.snapshot.customerInfo)
  }

  @MainActor
  func testStatusUpdateDuringMergeCannotBeOverwrittenByRefresh() async {
    // Exercise both a newly granted entitlement and a revocation. With separate
    // main-actor read/write calls, the storage hook applies the newer status after
    // the old status was captured, and refresh incorrectly overwrites CustomerInfo.
    for initiallyActive in [false, true] {
      let fixture = ReceiptRefreshFixture(deviceIsActive: false)
      let activeStatus = SubscriptionStatus.active([fixture.externalEntitlement])
      fixture.superwall.subscriptionStatus = initiallyActive ? activeStatus : .inactive
      let updatedStatus: SubscriptionStatus = initiallyActive ? .inactive : activeStatus
      let statusApplied = expectation(description: "Concurrent controller update applied")
      fixture.storage.onDeviceRead = {
        if Thread.isMainThread {
          // The atomic merge occupies the main actor, so this update follows it.
          DispatchQueue.main.async {
            fixture.superwall.subscriptionStatus = updatedStatus
            statusApplied.fulfill()
          }
        } else {
          // Reproduce the old interleaving deterministically, without sleeps.
          DispatchQueue.main.sync {
            fixture.superwall.subscriptionStatus = updatedStatus
            statusApplied.fulfill()
          }
        }
      }

      await fixture.refresh()
      await fulfillment(of: [statusApplied], timeout: 5)

      XCTAssertEqual(fixture.superwall.subscriptionStatus, updatedStatus)
      XCTAssertEqual(fixture.superwall.customerInfo.entitlements.first?.isActive, !initiallyActive)
    }
  }

  @MainActor
  func testInactiveExternalControllerDoesNotGrantActiveDeviceEntitlement() async {
    let fixture = ReceiptRefreshFixture(deviceIsActive: true)
    fixture.superwall.subscriptionStatus = .inactive

    await fixture.refresh()

    XCTAssertEqual(fixture.superwall.subscriptionStatus, .inactive)
    XCTAssertTrue(fixture.superwall.customerInfo.entitlements.isEmpty)
    XCTAssertEqual(
      fixture.superwall.customerInfo.subscriptions, fixture.snapshot.customerInfo.subscriptions)
  }

  @MainActor
  func testInternalControllerStillUsesDeviceCustomerInfo() async {
    let fixture = ReceiptRefreshFixture(deviceIsActive: true, hasExternalController: false)

    await fixture.refresh()

    XCTAssertEqual(fixture.superwall.customerInfo, fixture.snapshot.customerInfo)
    XCTAssertEqual(fixture.superwall.entitlements.byProductId("weekly").first?.id, "pro")
  }
}

@MainActor
private final class ReceiptRefreshFixture {
  // Retain the dependencies ReceiptManager holds as unowned references.
  let container: DependencyContainer
  let storage: ReceiptRefreshStorage
  let superwall: Superwall
  let productsManager: ProductsManager
  let manager: ReceiptManager
  let snapshot: PurchaseSnapshot
  // Other container components retain unowned references to these originals.
  private let originalStorage: Storage
  private let originalEntitlementsInfo: EntitlementsInfo
  let externalEntitlement = Entitlement(
    id: "pro",
    isActive: true,
    store: .stripe,
    expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
    willRenew: false,
    state: .subscribed,
    offerType: nil
  )

  init(deviceIsActive: Bool, hasExternalController: Bool = true) {
    let container = DependencyContainer()
    self.originalStorage = container.storage
    self.originalEntitlementsInfo = container.entitlementsInfo
    if hasExternalController {
      container.purchaseController = MockPurchaseController()
    }
    let storage = ReceiptRefreshStorage(factory: container)
    container.storage = storage
    container.entitlementsInfo = EntitlementsInfo(
      storage: storage,
      delegateAdapter: container.delegateAdapter,
      isTesting: true
    )
    let deviceEntitlement = Entitlement(
      id: "pro",
      isActive: deviceIsActive,
      productIds: ["weekly", "annual"],
      latestProductId: "weekly",
      store: .appStore,
      expiresAt: Date(timeIntervalSince1970: 1_751_500_000),
      willRenew: deviceIsActive,
      state: deviceIsActive ? .subscribed : .expired,
      offerType: .trial
    )
    let transaction = SubscriptionTransaction(
      transactionId: "device-transaction",
      productId: "weekly",
      purchaseDate: Date(timeIntervalSince1970: 1_750_000_000),
      willRenew: deviceIsActive,
      isRevoked: false,
      isInGracePeriod: false,
      isInBillingRetryPeriod: false,
      isActive: deviceIsActive,
      expirationDate: deviceEntitlement.expiresAt
    )
    let snapshot = PurchaseSnapshot(
      purchases: [
        Purchase(id: "weekly", isActive: deviceIsActive, purchaseDate: transaction.purchaseDate)
      ],
      customerInfo: CustomerInfo(
        subscriptions: [transaction], nonSubscriptions: [], entitlements: [deviceEntitlement])
    )
    let productsManager = ProductsManager(
      entitlementsInfo: container.entitlementsInfo,
      storeKitVersion: .storeKit1,
      productsFetcher: ProductsFetcherSK1Mock(
        productCompletionResult: .success([]),
        entitlementsInfo: container.entitlementsInfo
      )
    )
    self.container = container
    self.storage = storage
    self.superwall = Superwall(dependencyContainer: container)
    self.productsManager = productsManager
    self.snapshot = snapshot
    self.manager = ReceiptManager(
      storeKitVersion: .storeKit1,
      shouldBypassAppTransactionCheck: true,
      productsManager: productsManager,
      receiptManager: ReceiptSnapshotMock(snapshot: snapshot),
      receiptDelegate: nil,
      factory: container,
      storage: storage
    )
  }

  func refresh() async {
    await manager.loadPurchasedProducts(config: .stub(), superwall: superwall)
  }
}

private final class ReceiptRefreshStorage: Storage {
  var onDeviceRead: (() -> Void)?

  init(factory: DependencyContainer) {
    super.init(
      factory: factory,
      cache: Cache(fileManager: ReceiptRefreshFileManager()),
      coreDataManager: CoreDataManagerFakeDataMock()
    )
  }

  override func get<Key: Storable>(_ keyType: Key.Type) -> Key.Value? where Key.Value: Decodable {
    if keyType == LatestDeviceCustomerInfo.self {
      let callback = onDeviceRead
      onDeviceRead = nil  // A status update also reads storage; only interleave once.
      callback?()
    }
    return super.get(keyType)
  }
}

// Use the real thread-safe cache in memory, without sharing disk state with
// other tests or racing on CacheMock's unsynchronized dictionaries.
private final class ReceiptRefreshFileManager: FileManager, @unchecked Sendable {
  override func urls(
    for directory: FileManager.SearchPathDirectory,
    in domainMask: FileManager.SearchPathDomainMask
  ) -> [URL] {
    return []
  }
}

private final class ReceiptSnapshotMock: ReceiptManagerType {
  let snapshot: PurchaseSnapshot
  var purchases: Set<Purchase> { snapshot.purchases }
  var transactionReceipts: [TransactionReceipt] { [] }
  var latestSubscriptionPeriodType: LatestSubscription.PeriodType? { nil }
  var latestSubscriptionWillAutoRenew: Bool? { nil }
  var latestSubscriptionState: LatestSubscription.State? { nil }

  init(snapshot: PurchaseSnapshot) {
    self.snapshot = snapshot
  }

  func loadPurchases(serverEntitlementsByProductId: [String: Set<Entitlement>]) async
    -> PurchaseSnapshot
  {
    return snapshot
  }

  func loadIntroOfferEligibility(forProducts storeProducts: Set<StoreProduct>) async {}

  func isEligibleForIntroOffer(_ storeProduct: StoreProduct) async -> Bool {
    return false
  }
}
