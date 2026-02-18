import SwiftUI
import WebKit
import UIKit
import AuthenticationServices
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
  static let authHostSuffixes = [".auth0.com"]

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
    if
      let rawAuth0Domain = Bundle.main.object(forInfoDictionaryKey: auth0DomainKey) as? String,
      let auth0URL = normalizedURL(rawAuth0Domain),
      let auth0Host = auth0URL.host?.lowercased()
    {
      hosts.insert(auth0Host)
    }
    return hosts
  }

  static var authHosts: Set<String> {
    var hosts = Set<String>()
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

private struct NativeWebAuthenticationRequest {
  let startURL: URL
  let expectedCallbackURL: URL
}

private enum NativeWebAuthenticationError: LocalizedError {
  case unableToStart
  case missingCallback

  var errorDescription: String? {
    switch self {
    case .unableToStart:
      return "Unable to present the secure sign-in flow."
    case .missingCallback:
      return "Secure sign-in did not return a callback URL."
    }
  }
}

private final class NativeWebAuthenticationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  func start(
    request: NativeWebAuthenticationRequest,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    cancel()

    if #available(iOS 17.4, *) {
      let callback = callbackMatcher(for: request.expectedCallbackURL)
      let session = ASWebAuthenticationSession(url: request.startURL, callback: callback) { callbackURL, error in
        if let error {
          completion(.failure(error))
          return
        }
        guard let callbackURL else {
          completion(.failure(NativeWebAuthenticationError.missingCallback))
          return
        }
        completion(.success(Self.rebasedCallbackURL(callbackURL, expected: request.expectedCallbackURL)))
      }
      configure(session)
      guard session.start() else {
        completion(.failure(NativeWebAuthenticationError.unableToStart))
        return
      }
      self.session = session
      return
    }

    let callbackScheme = request.expectedCallbackURL.scheme
    let session = ASWebAuthenticationSession(
      url: request.startURL,
      callbackURLScheme: callbackScheme
    ) { callbackURL, error in
      if let error {
        completion(.failure(error))
        return
      }
      guard let callbackURL else {
        completion(.failure(NativeWebAuthenticationError.missingCallback))
        return
      }
      completion(.success(Self.rebasedCallbackURL(callbackURL, expected: request.expectedCallbackURL)))
    }
    configure(session)
    guard session.start() else {
      completion(.failure(NativeWebAuthenticationError.unableToStart))
      return
    }
    self.session = session
  }

  func cancel() {
    session?.cancel()
    session = nil
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let activeScenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }

    for scene in activeScenes {
      if let keyWindow = scene.windows.first(where: \.isKeyWindow) {
        return keyWindow
      }
      if let firstWindow = scene.windows.first {
        return firstWindow
      }
    }

    return ASPresentationAnchor()
  }

  private func configure(_ session: ASWebAuthenticationSession) {
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
  }

  @available(iOS 17.4, *)
  private func callbackMatcher(for callbackURL: URL) -> ASWebAuthenticationSession.Callback {
    if
      let scheme = callbackURL.scheme?.lowercased(),
      (scheme == "http" || scheme == "https"),
      let host = callbackURL.host
    {
      let path = callbackURL.path.isEmpty ? "/" : callbackURL.path
      return .https(host: host, path: path)
    }

    let fallbackScheme = callbackURL.scheme?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let fallbackScheme, !fallbackScheme.isEmpty {
      return .customScheme(fallbackScheme)
    }
    return .customScheme("com.pepyledger.ios")
  }

  private static func rebasedCallbackURL(_ callbackURL: URL, expected: URL) -> URL {
    guard
      let expectedScheme = expected.scheme?.lowercased(),
      expectedScheme == "http" || expectedScheme == "https"
    else {
      return callbackURL
    }

    if
      callbackURL.host?.lowercased() == expected.host?.lowercased(),
      callbackURL.path == expected.path
    {
      return callbackURL
    }

    guard
      var expectedComponents = URLComponents(url: expected, resolvingAgainstBaseURL: false),
      let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    else {
      return callbackURL
    }

    expectedComponents.percentEncodedQuery = callbackComponents.percentEncodedQuery
    expectedComponents.fragment = callbackComponents.fragment
    return expectedComponents.url ?? callbackURL
  }
}

struct WebAppRootView: View {
  @State private var loadState: WebViewLoadState = .loading
  @State private var reloadToken = 0

  private let baseURL = WebAppRuntimeConfiguration.baseURL
  private let trustedHosts = WebAppRuntimeConfiguration.trustedHosts
  private let trustedHostSuffixes = WebAppRuntimeConfiguration.trustedHostSuffixes
  private let authHosts = WebAppRuntimeConfiguration.authHosts
  private let authHostSuffixes = WebAppRuntimeConfiguration.authHostSuffixes

  var body: some View {
    ZStack {
      WebAppView(
        baseURL: baseURL,
        trustedHosts: trustedHosts,
        trustedHostSuffixes: trustedHostSuffixes,
        authHosts: authHosts,
        authHostSuffixes: authHostSuffixes,
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
  let authHosts: Set<String>
  let authHostSuffixes: [String]
  let reloadToken: Int
  @Binding var loadState: WebViewLoadState

  func makeCoordinator() -> Coordinator {
    Coordinator(
      baseURL: baseURL,
      policy: WebNavigationPolicy(
        trustedHosts: trustedHosts,
        trustedHostSuffixes: trustedHostSuffixes
      ),
      authHosts: authHosts,
      authHostSuffixes: authHostSuffixes,
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
    private let authHosts: Set<String>
    private let authHostSuffixes: [String]
    private let nativeWebAuthentication = NativeWebAuthenticationCoordinator()
    private var loadState: Binding<WebViewLoadState>
    private weak var webView: WKWebView?
    private var lastReloadToken: Int?
    private var isAuthenticating = false

    init(
      baseURL: URL,
      policy: WebNavigationPolicy,
      authHosts: Set<String>,
      authHostSuffixes: [String],
      loadState: Binding<WebViewLoadState>
    ) {
      self.baseURL = baseURL
      self.policy = policy
      self.authHosts = Set(authHosts.map(Self.normalizedHost(_:)))
      self.authHostSuffixes = authHostSuffixes.map { suffix in
        let normalized = Self.normalizedHost(suffix)
        return normalized.hasPrefix(".") ? normalized : ".\(normalized)"
      }
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

      if let authRequest = nativeAuthRequest(for: url) {
        decisionHandler(.cancel)
        startNativeWebAuthentication(authRequest, webView: webView)
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

      if let authRequest = nativeAuthRequest(for: url) {
        startNativeWebAuthentication(authRequest, webView: webView)
        return nil
      }

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

    private func startNativeWebAuthentication(
      _ request: NativeWebAuthenticationRequest,
      webView: WKWebView
    ) {
      guard !isAuthenticating else { return }
      isAuthenticating = true
      loadState.wrappedValue = .loading

      nativeWebAuthentication.start(request: request) { [weak self, weak webView] result in
        DispatchQueue.main.async {
          guard let self else { return }
          self.isAuthenticating = false

          switch result {
          case .success(let callbackURL):
            guard let scheme = callbackURL.scheme?.lowercased() else {
              self.loadState.wrappedValue = .failed("Secure sign-in returned an invalid callback URL.")
              return
            }

            if scheme == "http" || scheme == "https" {
              webView?.load(URLRequest(url: callbackURL))
              return
            }

            UIApplication.shared.open(callbackURL, options: [:], completionHandler: nil)
            self.loadState.wrappedValue = .loaded
          case .failure(let error):
            if self.isUserCanceledAuthentication(error) {
              self.loadState.wrappedValue = .loaded
              return
            }
            self.loadState.wrappedValue = .failed(error.localizedDescription)
          }
        }
      }
    }

    private func nativeAuthRequest(for url: URL) -> NativeWebAuthenticationRequest? {
      guard
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        isAuthHost(url.host)
      else {
        return nil
      }

      let path = url.path.lowercased()
      guard path == "/authorize" || path.hasSuffix("/authorize") else {
        return nil
      }

      guard
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let redirectURI = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
        let callbackURL = URL(string: redirectURI)
      else {
        return nil
      }

      return NativeWebAuthenticationRequest(
        startURL: url,
        expectedCallbackURL: callbackURL
      )
    }

    private func isAuthHost(_ host: String?) -> Bool {
      guard let host else { return false }
      let normalized = Self.normalizedHost(host)
      if authHosts.contains(normalized) {
        return true
      }
      for suffix in authHostSuffixes where normalized.hasSuffix(suffix) {
        return true
      }
      return false
    }

    private func isUserCanceledAuthentication(_ error: Error) -> Bool {
      let nsError = error as NSError
      return nsError.domain == ASWebAuthenticationSessionErrorDomain && nsError.code == 1
    }

    private static func normalizedHost(_ value: String) -> String {
      value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
  }
}
