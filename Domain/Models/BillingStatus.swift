import Foundation

public enum BillingSource: String, Codable {
  case stripe
  case appStore = "app_store"
  case trial
  case lifetime
  case none
}

public struct BillingStatus: Codable, Sendable {
  public let hasAccess: Bool
  public let accessReason: String
  public let primarySource: BillingSource
  public let activeSources: [BillingSource]
  public let hasAppStoreAccess: Bool
  public let appStoreExpiresAt: Date?
  public let unifiedAccessExpiresAt: Date?
}
