import SwiftUI
import Features

@main
struct pepyledgerIOSApp: App {
  @StateObject private var appEnvironment = AppEnvironment()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ZStack(alignment: .top) {
        Color(uiColor: .systemBackground)
          .ignoresSafeArea()
        switch appEnvironment.authState {
        case .authenticated:
          MemberShellView(
            syncStatusText: appEnvironment.syncStatusText,
            isSyncing: appEnvironment.isSyncInProgress,
            onSyncNow: {
              Task { await appEnvironment.syncNow(reason: "settings_manual") }
            },
            onLogout: {
              Task { await appEnvironment.logout() }
            }
          )
          SyncStatusBanner(state: appEnvironment.syncState)
        case .authenticating, .unauthenticated, .failed, .unavailable:
          LoginView(state: appEnvironment.authState) {
            Task { await appEnvironment.login() }
          }
        }
      }
      .task {
        await appEnvironment.startIfNeeded()
      }
      .onChange(of: scenePhase) { nextPhase in
        guard nextPhase == .active else { return }
        Task {
          await appEnvironment.handleSceneBecameActive()
        }
      }
    }
  }
}
