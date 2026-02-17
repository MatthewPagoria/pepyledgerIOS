import Foundation
import SwiftUI
import Domain
import Data
import Services

@MainActor
final class AppEnvironment: ObservableObject {
  enum SyncState: Equatable {
    case idle
    case disabled(String)
    case syncing
    case ready(Date)
    case blocked(String)
    case failed(String)
  }

  @Published private(set) var authState: AuthSessionStore.State
  @Published private(set) var syncState: SyncState = .idle

  private let authSessionStore: AuthSessionStore
  private let syncRepository: SyncRepository?
  private var started = false

  init() {
    let fallbackConfiguration = Auth0Configuration(
      domain: "",
      clientID: "",
      audience: nil,
      callbackScheme: "com.pepyledger.ios"
    )
    let configuredAuth = AppEnvironment.makeAuth0Configuration()
    let authConfiguration = configuredAuth ?? fallbackConfiguration
    let authService = Auth0Service(configuration: authConfiguration)
    let authStore = AuthSessionStore(authService: authService)

    authSessionStore = authStore
    authState = authStore.state
    syncRepository = AppEnvironment.makeSyncRepository(authService: authService)

    if configuredAuth == nil {
      authStore.markUnavailable(
        "Missing Auth0 config. Set AUTH0_DOMAIN and AUTH0_CLIENT_ID in Info.plist/xcconfig."
      )
      authState = authStore.state
    }

    if syncRepository == nil {
      if case .unavailable = authState {
        syncState = .disabled("Sync unavailable until auth and SUPABASE_URL are configured.")
      } else {
        syncState = .disabled("Sync disabled until SUPABASE_URL is configured.")
      }
    }
  }

  func startIfNeeded() async {
    guard !started else { return }
    started = true

    if case .unavailable = authState {
      return
    }

    await authSessionStore.restoreSessionIfPossible()
    authState = authSessionStore.state
    if isAuthenticated {
      await syncNow(reason: "launch")
    }
  }

  func login() async {
    if case .unavailable = authState {
      return
    }

    authState = .authenticating
    await authSessionStore.login()
    authState = authSessionStore.state
    if isAuthenticated {
      await syncNow(reason: "post_login")
    }
  }

  func logout() async {
    await authSessionStore.logout()
    authState = authSessionStore.state
    if let syncRepository {
      try? await syncRepository.clearAllForAccountSwitch()
    }
    syncState = .idle
  }

  func handleSceneBecameActive() async {
    if isAuthenticated {
      await syncNow(reason: "foreground")
      return
    }

    if case .unavailable = authState {
      return
    }

    await authSessionStore.restoreSessionIfPossible()
    authState = authSessionStore.state
    if isAuthenticated {
      await syncNow(reason: "restored_session")
    }
  }

  func syncNow(reason: String) async {
    guard isAuthenticated else { return }
    guard let syncRepository else {
      syncState = .disabled("Sync disabled until SUPABASE_URL is configured.")
      return
    }

    syncState = .syncing
    do {
      let pullResult = try await syncRepository.pull()
      if pullResult.accountScope?.ambiguous == true {
        syncState = .blocked("ACCOUNT_SCOPE_AMBIGUOUS: writes paused until account scope is repaired.")
        return
      }

      var drainResult = try await syncRepository.pushPendingMutations(maxBatch: 250)
      if drainResult.requiresFreshPull {
        let freshPull = try await syncRepository.pull()
        if freshPull.accountScope?.ambiguous == true {
          syncState = .blocked("ACCOUNT_SCOPE_AMBIGUOUS: writes paused until account scope is repaired.")
          return
        }
        drainResult = try await syncRepository.pushPendingMutations(maxBatch: 250)
      }

      if drainResult.accountScopeAmbiguous {
        syncState = .blocked("ACCOUNT_SCOPE_AMBIGUOUS: writes paused until account scope is repaired.")
        return
      }

      syncState = .ready(Date())
      _ = reason
    } catch {
      syncState = .failed(error.localizedDescription)
    }
  }

  var isAuthenticated: Bool {
    if case .authenticated = authState {
      return true
    }
    return false
  }

  var syncStatusText: String {
    switch syncState {
    case .idle:
      return "Idle"
    case .disabled(let message):
      return "Disabled: \(message)"
    case .syncing:
      return "Syncing..."
    case .ready(let date):
      return "Ready at \(timeFormatter.string(from: date))"
    case .blocked(let message):
      return "Blocked: \(message)"
    case .failed(let message):
      return "Failed: \(message)"
    }
  }

  var isSyncInProgress: Bool {
    if case .syncing = syncState {
      return true
    }
    return false
  }

  private static func makeSyncRepository(authService: Auth0Service) -> SyncRepository? {
    guard let supabaseURL = configuredSupabaseURL() else {
      return nil
    }

    let endpointClient = SyncEndpointClient(baseURL: supabaseURL) {
      try await authService.accessToken()
    }

    do {
      return try GRDBSyncStore(
        path: try syncDatabasePath(),
        endpointClient: endpointClient
      )
    } catch {
      return nil
    }
  }

  private static func makeAuth0Configuration() -> Auth0Configuration? {
    guard let rawDomain = stringConfigValue("AUTH0_DOMAIN"), !rawDomain.isEmpty else {
      return nil
    }
    let domain = normalizedAuth0Domain(rawDomain)
    guard !domain.isEmpty else {
      return nil
    }
    guard let clientID = stringConfigValue("AUTH0_CLIENT_ID"), !clientID.isEmpty else {
      return nil
    }
    let audience = stringConfigValue("AUTH0_AUDIENCE")
    let callbackScheme = stringConfigValue("AUTH0_CALLBACK_SCHEME") ?? "com.pepyledger.ios"
    return Auth0Configuration(
      domain: domain,
      clientID: clientID,
      audience: audience,
      callbackScheme: callbackScheme
    )
  }

  private static func normalizedAuth0Domain(_ value: String) -> String {
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
    return domain
  }

  private static func configuredSupabaseURL() -> URL? {
    if let value = ProcessInfo.processInfo.environment["SUPABASE_URL"], !value.isEmpty {
      return URL(string: value)
    }
    if let value = stringConfigValue("SUPABASE_URL"), !value.isEmpty {
      return URL(string: value)
    }
    return nil
  }

  private static func stringConfigValue(_ key: String) -> String? {
    if let plistValue = Bundle.main.object(forInfoDictionaryKey: key) as? String, !plistValue.isEmpty {
      return plistValue
    }
    if let envValue = ProcessInfo.processInfo.environment[key], !envValue.isEmpty {
      return envValue
    }
    return nil
  }

  private static func syncDatabasePath() throws -> String {
    let fileManager = FileManager.default
    let baseURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
      fileManager.temporaryDirectory
    try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    return baseURL.appendingPathComponent("pepyledger_sync.sqlite").path
  }
}

struct SyncStatusBanner: View {
  let state: AppEnvironment.SyncState

  var body: some View {
    switch state {
    case .idle:
      EmptyView()
    case .ready(let date):
      banner(text: "Sync ready at \(timeFormatter.string(from: date))", color: .green)
    case .disabled(let message):
      banner(text: message, color: .gray)
    case .syncing:
      banner(text: "Syncing...", color: .blue)
    case .blocked(let message):
      banner(text: message, color: .orange)
    case .failed(let message):
      banner(text: "Sync failed: \(message)", color: .red)
    }
  }

  private func banner(text: String, color: Color) -> some View {
    Text(text)
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(color.opacity(0.9))
      .clipShape(Capsule())
      .padding(.top, 8)
  }
}

private let timeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.timeStyle = .short
  formatter.dateStyle = .none
  return formatter
}()
