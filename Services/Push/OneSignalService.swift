import Foundation
import OneSignalFramework

public final class OneSignalService {
  public init() {}

  public func configure(appID: String) {
    OneSignal.initialize(appID, withLaunchOptions: nil)
  }

  public func setExternalUserId(_ auth0Sub: String) {
    OneSignal.login(auth0Sub)
  }

  public func logout() {
    OneSignal.logout()
  }
}
