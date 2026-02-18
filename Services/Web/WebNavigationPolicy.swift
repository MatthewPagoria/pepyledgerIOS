import Foundation

public struct WebNavigationPolicy: Sendable {
  public enum NavigationType: Sendable {
    case linkActivated
    case other
  }

  public struct Context: Sendable {
    public let navigationType: NavigationType
    public let targetFrameIsMainFrame: Bool
    public let targetFrameIsNil: Bool

    public init(
      navigationType: NavigationType,
      targetFrameIsMainFrame: Bool,
      targetFrameIsNil: Bool
    ) {
      self.navigationType = navigationType
      self.targetFrameIsMainFrame = targetFrameIsMainFrame
      self.targetFrameIsNil = targetFrameIsNil
    }
  }

  public enum Decision: Sendable, Equatable {
    case allowInWebView
    case openInWebView(URL)
    case openExternally(URL)
    case openInSystemHandler(URL)
  }

  private let trustedHosts: Set<String>
  private let trustedHostSuffixes: [String]

  public init(
    trustedHosts: Set<String>,
    trustedHostSuffixes: [String] = []
  ) {
    self.trustedHosts = Set(trustedHosts.map(Self.normalizedHost(_:)))
    self.trustedHostSuffixes = trustedHostSuffixes.map { suffix in
      let normalized = Self.normalizedHost(suffix)
      return normalized.hasPrefix(".") ? normalized : ".\(normalized)"
    }
  }

  public func decision(for url: URL, context: Context) -> Decision {
    guard let scheme = url.scheme?.lowercased() else {
      return .allowInWebView
    }

    if scheme == "mailto" || scheme == "tel" {
      return .openInSystemHandler(url)
    }

    if !context.targetFrameIsMainFrame && !context.targetFrameIsNil {
      return .allowInWebView
    }

    if isTrustedHost(url.host) {
      return context.targetFrameIsNil ? .openInWebView(url) : .allowInWebView
    }

    if scheme == "http" || scheme == "https" {
      if context.targetFrameIsNil || context.navigationType == .linkActivated {
        return .openExternally(url)
      }
      return .allowInWebView
    }

    return .openExternally(url)
  }

  private func isTrustedHost(_ host: String?) -> Bool {
    guard let host else { return false }
    let normalized = Self.normalizedHost(host)
    if trustedHosts.contains(normalized) {
      return true
    }
    for suffix in trustedHostSuffixes where normalized.hasSuffix(suffix) {
      return true
    }
    return false
  }

  private static func normalizedHost(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
