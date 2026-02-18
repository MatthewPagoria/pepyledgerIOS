import XCTest
@testable import Services

final class WebNavigationPolicyTests: XCTestCase {
  private let policy = WebNavigationPolicy(
    trustedHosts: [
      "pepyledger.com",
      "dev-og6vg4qwyyef7ntm.us.auth0.com",
      "accounts.google.com",
    ],
    trustedHostSuffixes: [".auth0.com"]
  )

  func testSameHostStaysInWebView() throws {
    let url = try XCTUnwrap(URL(string: "https://pepyledger.com/dashboard"))
    let context = WebNavigationPolicy.Context(
      navigationType: .other,
      targetFrameIsMainFrame: true,
      targetFrameIsNil: false
    )

    let decision = policy.decision(for: url, context: context)
    XCTAssertEqual(decision, .allowInWebView)
  }

  func testExternalLinkOpensOutsideApp() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com"))
    let context = WebNavigationPolicy.Context(
      navigationType: .linkActivated,
      targetFrameIsMainFrame: true,
      targetFrameIsNil: false
    )

    let decision = policy.decision(for: url, context: context)
    XCTAssertEqual(decision, .openExternally(url))
  }

  func testMailToUsesSystemHandler() throws {
    let url = try XCTUnwrap(URL(string: "mailto:support@pepyledger.com"))
    let context = WebNavigationPolicy.Context(
      navigationType: .linkActivated,
      targetFrameIsMainFrame: true,
      targetFrameIsNil: false
    )

    let decision = policy.decision(for: url, context: context)
    XCTAssertEqual(decision, .openInSystemHandler(url))
  }

  func testTelUsesSystemHandler() throws {
    let url = try XCTUnwrap(URL(string: "tel:+15555555555"))
    let context = WebNavigationPolicy.Context(
      navigationType: .linkActivated,
      targetFrameIsMainFrame: true,
      targetFrameIsNil: false
    )

    let decision = policy.decision(for: url, context: context)
    XCTAssertEqual(decision, .openInSystemHandler(url))
  }
}
