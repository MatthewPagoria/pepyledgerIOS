import SwiftUI

public struct FeaturePlaceholderView: View {
  private let title: String
  private let subtitle: String

  public init(title: String, subtitle: String) {
    self.title = title
    self.subtitle = subtitle
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title2.bold())
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding()
  }
}
