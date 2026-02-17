import Foundation
import RevenueCat

public final class RevenueCatService {
  public init() {}

  public func configure(appUserID: String) {
    Purchases.configure(withAPIKey: "REPLACE_ME", appUserID: appUserID)
  }

  public func refreshCustomerInfo() async throws -> CustomerInfo {
    try await Purchases.shared.customerInfo()
  }
}
