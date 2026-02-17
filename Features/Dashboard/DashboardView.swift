import SwiftUI

public struct DashboardView: View {
  public init() {}

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Dashboard")
        .font(.title.bold())
      Text("Native member parity surface")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding()
  }
}
