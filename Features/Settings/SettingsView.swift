import SwiftUI

public struct SettingsView: View {
  private let syncStatusText: String?
  private let isSyncing: Bool
  private let onSyncNow: (() -> Void)?
  private let onLogout: (() -> Void)?

  public init(
    syncStatusText: String? = nil,
    isSyncing: Bool = false,
    onSyncNow: (() -> Void)? = nil,
    onLogout: (() -> Void)? = nil
  ) {
    self.syncStatusText = syncStatusText
    self.isSyncing = isSyncing
    self.onSyncNow = onSyncNow
    self.onLogout = onLogout
  }

  public var body: some View {
    List {
      Section("Account") {
        Text("Signed in member account")
          .font(.body)
      }

      Section("Notifications") {
        Text("Push/email preference controls will appear here.")
          .foregroundStyle(.secondary)
      }

      if let syncStatusText {
        Section("Sync") {
          HStack {
            Text("Status")
            Spacer()
            Text(syncStatusText)
              .foregroundStyle(.secondary)
          }

          if let onSyncNow {
            Button(action: onSyncNow) {
              if isSyncing {
                ProgressView()
              } else {
                Text("Sync now")
              }
            }
            .disabled(isSyncing)
          }
        }
      }

      if let onLogout {
        Section {
          Button(role: .destructive, action: onLogout) {
            Text("Log out")
          }
        }
      }
    }
    .listStyle(.insetGrouped)
  }
}
