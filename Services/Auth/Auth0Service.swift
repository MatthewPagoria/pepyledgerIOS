import Foundation
import Auth0

public struct Auth0Configuration: Sendable, Equatable {
  public let domain: String
  public let clientID: String
  public let audience: String?
  public let callbackScheme: String
  public let scope: String

  public init(
    domain: String,
    clientID: String,
    audience: String?,
    callbackScheme: String,
    scope: String = "openid profile email offline_access"
  ) {
    self.domain = domain
    self.clientID = clientID
    self.audience = audience
    self.callbackScheme = callbackScheme
    self.scope = scope
  }
}

public struct AuthSession: Codable, Sendable, Equatable {
  public let accessToken: String
  public let idToken: String?
  public let refreshToken: String?
  public let tokenType: String?
  public let scope: String?
  public let expiresAt: Date?
  public let createdAt: Date

  public init(
    accessToken: String,
    idToken: String?,
    refreshToken: String?,
    tokenType: String?,
    scope: String?,
    expiresAt: Date?,
    createdAt: Date = Date()
  ) {
    self.accessToken = accessToken
    self.idToken = idToken
    self.refreshToken = refreshToken
    self.tokenType = tokenType
    self.scope = scope
    self.expiresAt = expiresAt
    self.createdAt = createdAt
  }
}

public enum Auth0ServiceError: Error, LocalizedError {
  case misconfigured(String)
  case noCachedSession
  case expiredSession
  case webAuth(String)
  case logoutFailed(String)

  public var errorDescription: String? {
    switch self {
    case .misconfigured(let detail):
      return "Auth0 configuration is invalid: \(detail)"
    case .noCachedSession:
      return "No authenticated session is available."
    case .expiredSession:
      return "Session expired. Sign in again."
    case .webAuth(let message):
      return message
    case .logoutFailed(let message):
      return message
    }
  }
}

public final class Auth0Service {
  private let configuration: Auth0Configuration
  private let normalizedDomain: String
  private let defaultBundleID = "com.pepyledger.ios"
  private let storageKey = "pepyledger.auth.session"
  private let userDefaults: UserDefaults
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private var session: AuthSession?

  public init(configuration: Auth0Configuration, userDefaults: UserDefaults = .standard) {
    let sanitizedDomain = Self.normalizedDomain(from: configuration.domain)
    self.configuration = Auth0Configuration(
      domain: sanitizedDomain,
      clientID: configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
      audience: configuration.audience?.trimmingCharacters(in: .whitespacesAndNewlines),
      callbackScheme: configuration.callbackScheme.trimmingCharacters(in: .whitespacesAndNewlines),
      scope: configuration.scope
    )
    self.normalizedDomain = sanitizedDomain
    self.userDefaults = userDefaults
    session = Self.loadSession(from: userDefaults, key: storageKey, decoder: decoder)
  }

  public func login() async throws -> AuthSession {
    guard !normalizedDomain.isEmpty else {
      throw Auth0ServiceError.misconfigured("AUTH0_DOMAIN is empty")
    }
    guard !configuration.clientID.isEmpty else {
      throw Auth0ServiceError.misconfigured("AUTH0_CLIENT_ID is empty")
    }
    guard !configuration.callbackScheme.isEmpty else {
      throw Auth0ServiceError.misconfigured("callback scheme is empty")
    }

    let callbackURL = try makeRedirectURL(path: "callback")

    var webAuth = Auth0
      .webAuth(clientId: configuration.clientID, domain: normalizedDomain)
      .scope(configuration.scope)
      .redirectURL(callbackURL)

    if let audience = normalizedAudience {
      webAuth = webAuth.audience(audience)
    }

    let credentials: Credentials
    do {
      credentials = try await webAuth.start()
    } catch {
      throw Auth0ServiceError.webAuth(error.localizedDescription)
    }

    let authenticated = AuthSession(
      accessToken: credentials.accessToken,
      idToken: credentials.idToken,
      refreshToken: credentials.refreshToken,
      tokenType: credentials.tokenType,
      scope: credentials.scope,
      expiresAt: credentials.expiresIn
    )

    session = authenticated
    persistSession(authenticated)
    return authenticated
  }

  public func logout() async {
    var webAuth = Auth0.webAuth(clientId: configuration.clientID, domain: normalizedDomain)
    if let audience = normalizedAudience {
      webAuth = webAuth.audience(audience)
    }
    if let callbackURL = try? makeRedirectURL(path: "callback") {
      webAuth = webAuth.redirectURL(callbackURL)
    }

    do {
      try await webAuth.clearSession()
    } catch {
      // Continue local session cleanup even if browser session clearing fails.
    }

    session = nil
    userDefaults.removeObject(forKey: storageKey)
  }

  public func accessToken() async throws -> String {
    if let staticToken = ProcessInfo.processInfo.environment["PEPYLEDGER_STATIC_AUTH_TOKEN"], !staticToken.isEmpty {
      return staticToken
    }

    let current = try await refreshSessionIfNeeded()
    return current.accessToken
  }

  public func refreshSessionIfNeeded() async throws -> AuthSession {
    let current = session ?? Self.loadSession(from: userDefaults, key: storageKey, decoder: decoder)
    guard let current else {
      throw Auth0ServiceError.noCachedSession
    }

    if let expiresAt = current.expiresAt, expiresAt <= Date().addingTimeInterval(30) {
      guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
        session = nil
        userDefaults.removeObject(forKey: storageKey)
        throw Auth0ServiceError.expiredSession
      }
      do {
        let renewedCredentials = try await Auth0
          .authentication(clientId: configuration.clientID, domain: normalizedDomain)
          .renew(withRefreshToken: refreshToken, audience: normalizedAudience, scope: configuration.scope)
          .start()

        let renewedSession = AuthSession(
          accessToken: renewedCredentials.accessToken,
          idToken: renewedCredentials.idToken ?? current.idToken,
          refreshToken: renewedCredentials.refreshToken ?? refreshToken,
          tokenType: renewedCredentials.tokenType ?? current.tokenType,
          scope: renewedCredentials.scope ?? current.scope,
          expiresAt: renewedCredentials.expiresIn
        )
        session = renewedSession
        persistSession(renewedSession)
        return renewedSession
      } catch {
        session = nil
        userDefaults.removeObject(forKey: storageKey)
        throw Auth0ServiceError.webAuth(error.localizedDescription)
      }
    }

    session = current
    return current
  }

  private var normalizedAudience: String? {
    guard let audience = configuration.audience, !audience.isEmpty else {
      return nil
    }
    return audience
  }

  private func makeRedirectURL(path: String) throws -> URL {
    let bundleID = Bundle.main.bundleIdentifier ?? defaultBundleID
    let value = "\(configuration.callbackScheme)://\(normalizedDomain)/ios/\(bundleID)/\(path)"
    guard let url = URL(string: value) else {
      throw Auth0ServiceError.misconfigured("Invalid redirect URL: \(value)")
    }
    return url
  }

  private static func normalizedDomain(from value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
      return host
    }

    var domain = trimmed
    if domain.hasPrefix("https://") {
      domain.removeFirst("https://".count)
    } else if domain.hasPrefix("http://") {
      domain.removeFirst("http://".count)
    }
    if let slash = domain.firstIndex(of: "/") {
      domain = String(domain[..<slash])
    }
    return domain.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func persistSession(_ session: AuthSession) {
    if let data = try? encoder.encode(session) {
      userDefaults.set(data, forKey: storageKey)
    }
  }

  private static func loadSession(
    from defaults: UserDefaults,
    key: String,
    decoder: JSONDecoder
  ) -> AuthSession? {
    guard let data = defaults.data(forKey: key) else {
      return nil
    }
    return try? decoder.decode(AuthSession.self, from: data)
  }
}
