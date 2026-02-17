import Foundation
import Domain

@MainActor
public final class BillingViewModel: ObservableObject {
  @Published public private(set) var status: BillingStatus?

  public init() {}

  public func refresh() async {
    // TODO: call get-subscription-status and hide paywall when hasAccess is true.
  }
}
