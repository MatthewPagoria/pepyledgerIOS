import Foundation
import Services

@MainActor
final class AuthSessionStore: ObservableObject {
  enum State: Equatable {
    case unavailable(String)
    case unauthenticated
    case authenticating
    case authenticated(AuthSession)
    case failed(String)
  }

  @Published private(set) var state: State = .unauthenticated

  private let authService: Auth0Service

  init(authService: Auth0Service) {
    self.authService = authService
  }

  func restoreSessionIfPossible() async {
    do {
      let session = try await authService.refreshSessionIfNeeded()
      state = .authenticated(session)
    } catch {
      state = .unauthenticated
    }
  }

  func login() async {
    state = .authenticating
    do {
      let session = try await authService.login()
      state = .authenticated(session)
    } catch {
      state = .failed(Self.userFacingAuthErrorMessage(from: error))
    }
  }

  func logout() async {
    await authService.logout()
    state = .unauthenticated
  }

  func markUnavailable(_ message: String) {
    state = .unavailable(message)
  }

  var session: AuthSession? {
    if case .authenticated(let session) = state {
      return session
    }
    return nil
  }

  private static func userFacingAuthErrorMessage(from error: Error) -> String {
    let message = error.localizedDescription
    let lowercase = message.lowercased()
    if lowercase.contains("service not found: https") || lowercase.contains("invalid authority") {
      return "Auth0 domain is invalid. Set AUTH0_DOMAIN to host only (no https://), for example dev-tenant.us.auth0.com."
    }
    return message
  }
}
