//
//  TrackedDirectPurchaseTests.swift
//  SuperwallKitTests
//

import Foundation
import Testing
@testable import SuperwallKit

struct TrackedDirectPurchaseTests {
  private func makeProduct() -> StoreProduct {
    let superwallProduct = SuperwallProduct(
      object: "product",
      identifier: "native_checkout_product",
      platform: .custom,
      price: SuperwallProductPrice(amount: 699, currency: "USD"),
      subscription: SuperwallProductSubscription(
        period: .week,
        periodCount: 1,
        trialPeriodDays: 7,
        trialPeriodPrice: nil
      ),
      entitlements: [],
      storefront: "USA"
    )
    return StoreProduct(customProduct: APIStoreProduct(
      superwallProduct: superwallProduct,
      entitlements: [Entitlement(id: "premium", type: .serviceLevel, isActive: false)]
    ))
  }

  @Test
  func directPurchaseWithExternalControllerKeepsNestedTrackingSuppressed() async {
    let dependencyContainer = DependencyContainer(
      purchaseController: MockPurchaseController()
    )
    let product = makeProduct()

    await dependencyContainer.transactionManager.prepareToPurchase(
      product: product,
      purchaseSource: .purchaseFunc(product)
    )

    let source = await dependencyContainer.makePurchasingCoordinator().source
    #expect(source == nil)
  }

  @Test
  func trackedDirectPurchaseWithExternalControllerCreatesTrackingContext() async {
    let dependencyContainer = DependencyContainer(
      purchaseController: MockPurchaseController()
    )
    let product = makeProduct()

    await dependencyContainer.transactionManager.prepareToPurchase(
      product: product,
      purchaseSource: .purchaseFunc(product),
      tracksDirectPurchase: true
    )

    let coordinator = dependencyContainer.makePurchasingCoordinator()
    let source = await coordinator.source
    let trackedProduct = await coordinator.product

    guard case .purchaseFunc? = source else {
      Issue.record("Expected tracked direct purchase context")
      return
    }
    #expect(trackedProduct === product)
  }
}
