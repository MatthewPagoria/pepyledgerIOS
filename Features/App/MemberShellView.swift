import SwiftUI

public struct MemberShellView: View {
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
    TabView {
      shell("Dashboard", systemImage: "house", view: DashboardView())
      shell("Peptides", systemImage: "testtube.2", view: PeptidesView())
      shell("Log", systemImage: "list.bullet.rectangle", view: LogView())
      shell("Cycles", systemImage: "arrow.triangle.2.circlepath", view: CyclesView())
      shell("Inventory", systemImage: "shippingbox", view: InventoryView())
      shell("Calculator", systemImage: "function", view: CalculatorView())
      shell("Essentials", systemImage: "staroflife", view: EssentialsView())
      shell("Library", systemImage: "books.vertical", view: PeptideLibraryView())
      shell("Billing", systemImage: "creditcard", view: BillingView())
      shell("Support", systemImage: "questionmark.bubble", view: SupportView())
      shell(
        "Settings",
        systemImage: "gearshape",
        view: SettingsView(
          syncStatusText: syncStatusText,
          isSyncing: isSyncing,
          onSyncNow: onSyncNow,
          onLogout: onLogout
        )
      )
    }
  }

  private func shell<Content: View>(
    _ title: String,
    systemImage: String,
    view: Content
  ) -> some View {
    NavigationStack {
      view
        .navigationTitle(title)
    }
    .tabItem {
      Label(title, systemImage: systemImage)
    }
  }
}
