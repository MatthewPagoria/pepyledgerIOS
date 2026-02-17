import SwiftUI

public struct BillingView: View {
  @StateObject private var viewModel = BillingViewModel()

  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Billing")
        .font(.title2.bold())
      if let status = viewModel.status {
        Text(status.hasAccess ? "Access active" : "Access inactive")
          .font(.headline)
        Text("Primary source: \(status.primarySource.rawValue)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        Text("Loading unified entitlement status…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Button("Refresh status") {
        Task { await viewModel.refresh() }
      }
      .buttonStyle(.borderedProminent)
      Spacer()
    }
    .padding()
    .task {
      await viewModel.refresh()
    }
  }
}
