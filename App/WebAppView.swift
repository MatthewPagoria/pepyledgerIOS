import SwiftUI
import WebKit
import UIKit
import Services

private enum WebViewLoadState: Equatable {
  case loading
  case loaded
  case failed(String)
}

private enum WebAppRuntimeConfiguration {
  private static let defaultBaseURL = URL(string: "https://pepyledger.com")!
  private static let webBaseURLKey = "WEB_APP_BASE_URL"
  private static let auth0DomainKey = "AUTH0_DOMAIN"

  static let trustedHostSuffixes = [".auth0.com"]

  static var baseURL: URL {
    guard
      let raw = Bundle.main.object(forInfoDictionaryKey: webBaseURLKey) as? String,
      let normalized = normalizedURL(raw)
    else {
      return defaultBaseURL
    }
    return normalized
  }

  static var trustedHosts: Set<String> {
    var hosts = Set<String>()
    if let host = baseURL.host?.lowercased() {
      hosts.insert(host)
    }
    hosts.insert("accounts.google.com")
    if
      let rawAuth0Domain = Bundle.main.object(forInfoDictionaryKey: auth0DomainKey) as? String,
      let auth0URL = normalizedURL(rawAuth0Domain),
      let auth0Host = auth0URL.host?.lowercased()
    {
      hosts.insert(auth0Host)
    }
    return hosts
  }

  private static func normalizedURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let url = URL(string: trimmed), isValidWebURL(url) {
      return url
    }
    if let httpsURL = URL(string: "https://\(trimmed)"), isValidWebURL(httpsURL) {
      return httpsURL
    }
    return nil
  }

  private static func isValidWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
      return false
    }
    return scheme == "http" || scheme == "https"
  }
}

struct WebAppRootView: View {
  @State private var loadState: WebViewLoadState = .loading
  @State private var reloadToken = 0

  private let baseURL = WebAppRuntimeConfiguration.baseURL
  private let trustedHosts = WebAppRuntimeConfiguration.trustedHosts
  private let trustedHostSuffixes = WebAppRuntimeConfiguration.trustedHostSuffixes

  var body: some View {
    ZStack {
      WebAppView(
        baseURL: baseURL,
        trustedHosts: trustedHosts,
        trustedHostSuffixes: trustedHostSuffixes,
        reloadToken: reloadToken,
        loadState: $loadState
      )
      .ignoresSafeArea()

      switch loadState {
      case .loading:
        ProgressView("Loading PepyLedger…")
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .allowsHitTesting(false)
      case .loaded:
        EmptyView()
      case .failed(let message):
        VStack(spacing: 12) {
          Text("Unable to load PepyLedger")
            .font(.headline)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Retry") {
            reloadToken += 1
            loadState = .loading
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
    }
    .background(Color(uiColor: .systemBackground).ignoresSafeArea())
  }
}

private struct WebAppView: UIViewRepresentable {
  let baseURL: URL
  let trustedHosts: Set<String>
  let trustedHostSuffixes: [String]
  let reloadToken: Int
  @Binding var loadState: WebViewLoadState

  func makeCoordinator() -> Coordinator {
    Coordinator(
      baseURL: baseURL,
      policy: WebNavigationPolicy(
        trustedHosts: trustedHosts,
        trustedHostSuffixes: trustedHostSuffixes
      ),
      loadState: $loadState
    )
  }

  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.allowsInlineMediaPlayback = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    let webpagePreferences = WKWebpagePreferences()
    webpagePreferences.allowsContentJavaScript = true
    config.defaultWebpagePreferences = webpagePreferences

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear

    context.coordinator.attach(webView: webView)
    context.coordinator.handleReloadToken(reloadToken)
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {
    context.coordinator.handleReloadToken(reloadToken)
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let baseURL: URL
    private let policy: WebNavigationPolicy
    private var loadState: Binding<WebViewLoadState>
    private weak var webView: WKWebView?
    private var lastReloadToken: Int?

    init(baseURL: URL, policy: WebNavigationPolicy, loadState: Binding<WebViewLoadState>) {
      self.baseURL = baseURL
      self.policy = policy
      self.loadState = loadState
    }

    func attach(webView: WKWebView) {
      self.webView = webView
    }

    func handleReloadToken(_ reloadToken: Int) {
      guard lastReloadToken != reloadToken else { return }
      lastReloadToken = reloadToken
      loadState.wrappedValue = .loading
      webView?.load(URLRequest(url: baseURL))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      loadState.wrappedValue = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loadState.wrappedValue = .loaded
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      applyLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      applyLoadFailure(error)
    }

    private func applyLoadFailure(_ error: Error) {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        return
      }
      loadState.wrappedValue = .failed(error.localizedDescription)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.allow)
        return
      }

      let navigationType: WebNavigationPolicy.NavigationType =
        navigationAction.navigationType == .linkActivated ? .linkActivated : .other
      let context = WebNavigationPolicy.Context(
        navigationType: navigationType,
        targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
        targetFrameIsNil: navigationAction.targetFrame == nil
      )

      switch policy.decision(for: url, context: context) {
      case .allowInWebView:
        decisionHandler(.allow)
      case .openInWebView(let nextURL):
        webView.load(URLRequest(url: nextURL))
        decisionHandler(.cancel)
      case .openExternally(let externalURL), .openInSystemHandler(let externalURL):
        UIApplication.shared.open(externalURL, options: [:], completionHandler: nil)
        decisionHandler(.cancel)
      }
    }

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      guard let url = navigationAction.request.url else { return nil }
      let navigationType: WebNavigationPolicy.NavigationType =
        navigationAction.navigationType == .linkActivated ? .linkActivated : .other
      let context = WebNavigationPolicy.Context(
        navigationType: navigationType,
        targetFrameIsMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
        targetFrameIsNil: true
      )

      switch policy.decision(for: url, context: context) {
      case .allowInWebView, .openInWebView:
        webView.load(URLRequest(url: url))
      case .openExternally(let externalURL), .openInSystemHandler(let externalURL):
        UIApplication.shared.open(externalURL, options: [:], completionHandler: nil)
      }
      return nil
    }
  }
}
