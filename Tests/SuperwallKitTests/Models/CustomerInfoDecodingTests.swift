//
//  CustomerInfoDecodingTests.swift
//  SuperwallKit
//
//  Created by Yusuf Tör on 30/09/2025.
//

import Testing
import Foundation
@testable import SuperwallKit

@Suite("CustomerInfo Milliseconds Decoding Tests")
struct CustomerInfoDecodingTests {
  @Test("External purchase controller overrides conflicting cached entitlement metadata")
  func testExternalPurchaseControllerOverridesCachedRenewalState() {
    let cachedEntitlement = Entitlement(
      id: "pro",
      isActive: true,
      productIds: ["legacy_product"],
      latestProductId: "legacy_product",
      store: .appStore,
      expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
      willRenew: true,
      state: .subscribed,
      offerType: .trial
    )
    let storage = StorageMock(
      internalRedeemResponse: RedeemResponse(
        results: [],
        customerInfo: CustomerInfo(
          subscriptions: [],
          nonSubscriptions: [],
          entitlements: [cachedEntitlement]
        )
      )
    )
    let expiresAt = Date(timeIntervalSince1970: 1_735_689_600)
    let entitlement = Entitlement(
      id: "pro",
      isActive: true,
      store: .stripe,
      expiresAt: expiresAt,
      willRenew: false,
      state: .subscribed,
      offerType: nil
    )

    let customerInfo = CustomerInfo.forExternalPurchaseController(
      storage: storage,
      subscriptionStatus: .active([entitlement])
    )

    let preserved = customerInfo.entitlements.first
    #expect(customerInfo.entitlements.count == 1)
    #expect(preserved?.id == "pro")
    #expect(preserved?.store == .stripe)
    #expect(preserved?.expiresAt == expiresAt)
    #expect(preserved?.willRenew == false)
    #expect(preserved?.state == .subscribed)
    #expect(preserved?.offerType == nil)
    #expect(preserved?.productIds == ["legacy_product"])
  }

  @Test("External active entitlement survives a device snapshot holding an expired entitlement of the same id")
  func testExternalActiveEntitlementBeatsExpiredDeviceEntitlement() {
    // Receipt refresh scenario: StoreKit on the device knows an expired "pro"
    // (a lapsed App Store plan) while the external purchase controller grants
    // an active "pro". The external entitlement must win, and must keep the
    // device's product history.
    let storage = StorageMock()
    let expiredOnDevice = Entitlement(
      id: "pro",
      isActive: false,
      productIds: ["weekly_699_7d_trial"],
      latestProductId: "weekly_699_7d_trial",
      store: .appStore,
      expiresAt: Date(timeIntervalSince1970: 1_751_500_000),
      willRenew: false,
      state: .expired,
      offerType: nil
    )
    storage.save(
      CustomerInfo(subscriptions: [], nonSubscriptions: [], entitlements: [expiredOnDevice]),
      forType: LatestDeviceCustomerInfo.self
    )
    let externalExpiresAt = Date(timeIntervalSince1970: 1_780_000_000)
    let external = Entitlement(
      id: "pro",
      isActive: true,
      store: .appStore,
      expiresAt: externalExpiresAt,
      willRenew: true,
      state: .subscribed,
      offerType: nil
    )

    let customerInfo = CustomerInfo.forExternalPurchaseController(
      storage: storage,
      subscriptionStatus: .active([external])
    )

    let pro = customerInfo.entitlements.first
    #expect(customerInfo.entitlements.count == 1)
    #expect(pro?.id == "pro")
    #expect(pro?.isActive == true)
    #expect(pro?.state == .subscribed)
    #expect(pro?.expiresAt == externalExpiresAt)
    #expect(pro?.willRenew == true)
    #expect(pro?.productIds.contains("weekly_699_7d_trial") == true)
  }

  @Test("Decode SubscriptionTransaction with milliseconds using subscriptionsApi decoder")
  func testSubscriptionTransactionMillisecondsDecoding() throws {
    let json = """
    {
      "transactionId": "123456",
      "productId": "test.product",
      "purchaseDate": 1704067200000,
      "willRenew": true,
      "isRevoked": false,
      "isInGracePeriod": false,
      "isInBillingRetryPeriod": false,
      "isActive": true,
      "expirationDate": 1735689600000,
      "store": "APP_STORE",
      "subscriptionGroupId": "12345678"
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let transaction = try decoder.decode(SubscriptionTransaction.self, from: data)

    // Verify dates are correctly decoded from milliseconds
    let expectedPurchaseDate = Date(timeIntervalSince1970: 1704067200.0)
    let expectedExpirationDate = Date(timeIntervalSince1970: 1735689600.0)

    #expect(transaction.transactionId == "123456")
    #expect(transaction.productId == "test.product")
    #expect(transaction.purchaseDate.timeIntervalSince1970 == expectedPurchaseDate.timeIntervalSince1970)
    #expect(transaction.expirationDate?.timeIntervalSince1970 == expectedExpirationDate.timeIntervalSince1970)
    #expect(transaction.willRenew == true)
    #expect(transaction.isRevoked == false)
    #expect(transaction.isActive == true)
    #expect(transaction.subscriptionGroupId == "12345678")
  }

  @Test("Decode SubscriptionTransaction with ISO8601 dates using subscriptionsApi decoder")
  func testSubscriptionTransactionISO8601Decoding() throws {
    let json = """
    {
      "transactionId": "123456",
      "productId": "test.product",
      "purchaseDate": "2024-01-01T00:00:00.000Z",
      "willRenew": true,
      "isRevoked": false,
      "isInGracePeriod": false,
      "isInBillingRetryPeriod": false,
      "isActive": true,
      "expirationDate": "2025-01-01T00:00:00.000Z",
      "store": "APP_STORE"
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let transaction = try decoder.decode(SubscriptionTransaction.self, from: data)

    #expect(transaction.transactionId == "123456")
    #expect(transaction.productId == "test.product")
    #expect(transaction.willRenew == true)
    #expect(transaction.isRevoked == false)
    #expect(transaction.isActive == true)
    #expect(transaction.subscriptionGroupId == nil)
  }

  @Test("Decode NonSubscriptionTransaction with milliseconds using subscriptionsApi decoder")
  func testNonSubscriptionTransactionMillisecondsDecoding() throws {
    let json = """
    {
      "transactionId": "789012",
      "productId": "test.consumable",
      "purchaseDate": 1704067200000,
      "isConsumable": true,
      "isRevoked": false,
      "store": "APP_STORE"
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let transaction = try decoder.decode(NonSubscriptionTransaction.self, from: data)

    let expectedPurchaseDate = Date(timeIntervalSince1970: 1704067200.0)

    #expect(transaction.transactionId == "789012")
    #expect(transaction.productId == "test.consumable")
    #expect(transaction.purchaseDate.timeIntervalSince1970 == expectedPurchaseDate.timeIntervalSince1970)
    #expect(transaction.isConsumable == true)
    #expect(transaction.isRevoked == false)
  }

  @Test("Decode NonSubscriptionTransaction with ISO8601 dates using subscriptionsApi decoder")
  func testNonSubscriptionTransactionISO8601Decoding() throws {
    let json = """
    {
      "transactionId": "789012",
      "productId": "test.consumable",
      "purchaseDate": "2024-01-01T00:00:00.000Z",
      "isConsumable": true,
      "isRevoked": false,
      "store": "APP_STORE"
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let transaction = try decoder.decode(NonSubscriptionTransaction.self, from: data)

    #expect(transaction.transactionId == "789012")
    #expect(transaction.productId == "test.consumable")
    #expect(transaction.isConsumable == true)
    #expect(transaction.isRevoked == false)
  }

  @Test("Decode Entitlement with milliseconds using subscriptionsApi decoder")
  func testEntitlementMillisecondsDecoding() throws {
    let json = """
    {
      "identifier": "premium",
      "type": "SERVICE_LEVEL",
      "isActive": true,
      "productIds": ["test.product"],
      "latestProductId": "test.product",
      "startsAt": 1704067200000,
      "renewedAt": 1706745600000,
      "expiresAt": 1735689600000,
      "isLifetime": false,
      "willRenew": true
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let entitlement = try decoder.decode(Entitlement.self, from: data)

    let expectedStartsAt = Date(timeIntervalSince1970: 1704067200.0)
    let expectedRenewedAt = Date(timeIntervalSince1970: 1706745600.0)
    let expectedExpiresAt = Date(timeIntervalSince1970: 1735689600.0)

    #expect(entitlement.id == "premium")
    #expect(entitlement.isActive == true)
    #expect(entitlement.startsAt?.timeIntervalSince1970 == expectedStartsAt.timeIntervalSince1970)
    #expect(entitlement.renewedAt?.timeIntervalSince1970 == expectedRenewedAt.timeIntervalSince1970)
    #expect(entitlement.expiresAt?.timeIntervalSince1970 == expectedExpiresAt.timeIntervalSince1970)
    #expect(entitlement.willRenew == true)
  }

  @Test("Decode Entitlement with ISO8601 dates using subscriptionsApi decoder")
  func testEntitlementISO8601Decoding() throws {
    let json = """
    {
      "identifier": "premium",
      "type": "SERVICE_LEVEL",
      "isActive": true,
      "productIds": ["test.product"],
      "latestProductId": "test.product",
      "startsAt": "2024-01-01T00:00:00.000Z",
      "renewedAt": "2024-02-01T00:00:00.000Z",
      "expiresAt": "2025-01-01T00:00:00.000Z",
      "isLifetime": false,
      "willRenew": true
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let entitlement = try decoder.decode(Entitlement.self, from: data)

    #expect(entitlement.id == "premium")
    #expect(entitlement.isActive == true)
    #expect(entitlement.willRenew == true)
  }

  @Test("Decode CustomerInfo with milliseconds using subscriptionsApi decoder")
  func testCustomerInfoMillisecondsDecoding() throws {
    let json = """
    {
      "subscriptions": [{
        "transactionId": "123456",
        "productId": "test.product",
        "purchaseDate": 1704067200000,
        "willRenew": true,
        "isRevoked": false,
        "isInGracePeriod": false,
        "isInBillingRetryPeriod": false,
        "isActive": true,
        "expirationDate": 1735689600000,
        "store": "APP_STORE",
        "subscriptionGroupId": "12345678"
      }],
      "nonSubscriptions": [{
        "transactionId": "789012",
        "productId": "test.consumable",
        "purchaseDate": 1704067200000,
        "isConsumable": true,
        "isRevoked": false,
        "store": "APP_STORE"
      }],
      "entitlements": [{
        "identifier": "premium",
        "type": "SERVICE_LEVEL",
        "isActive": true,
        "productIds": ["test.product"],
        "startsAt": 1704067200000,
        "expiresAt": 1735689600000
      }],
      "isBlank": false
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let customerInfo = try decoder.decode(CustomerInfo.self, from: data)

    #expect(customerInfo.subscriptions.count == 1)
    #expect(customerInfo.nonSubscriptions.count == 1)
    #expect(customerInfo.entitlements.count == 1)
    #expect(customerInfo.isPlaceholder == false)

    // Verify dates are properly decoded
    let subscription = customerInfo.subscriptions[0]
    let expectedPurchaseDate = Date(timeIntervalSince1970: 1704067200.0)
    #expect(subscription.purchaseDate.timeIntervalSince1970 == expectedPurchaseDate.timeIntervalSince1970)
  }

  @Test("Decode CustomerInfo with entitlements but no transactions")
  func testCustomerInfoWithEntitlementsButNoTransactions() throws {
    let json = """
    {
      "subscriptions": [],
      "nonSubscriptions": [],
      "entitlements": [{
        "identifier": "premium",
        "type": "SERVICE_LEVEL",
        "isActive": true,
        "productIds": ["test.product"],
        "startsAt": 1704067200000,
        "expiresAt": 1735689600000,
        "store": "STRIPE"
      }],
      "isBlank": false
    }
    """

    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder.subscriptionsApi
    let customerInfo = try decoder.decode(CustomerInfo.self, from: data)

    // Verify no transactions
    #expect(customerInfo.subscriptions.isEmpty)
    #expect(customerInfo.nonSubscriptions.isEmpty)
    #expect(customerInfo.activeSubscriptionProductIds.isEmpty)

    // Verify entitlements are still present and accessible
    #expect(customerInfo.entitlements.count == 1)
    #expect(customerInfo.isPlaceholder == false)

    let entitlement = customerInfo.entitlements[0]
    #expect(entitlement.id == "premium")
    #expect(entitlement.isActive == true)
    #expect(entitlement.productIds == ["test.product"])
    #expect(entitlement.store == .stripe)

    // Verify entitlementsByProductId works correctly
    let entitlementsByProduct = customerInfo.entitlementsByProductId
    #expect(entitlementsByProduct["test.product"]?.contains(entitlement) == true)
  }
}
