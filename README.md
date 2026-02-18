# pepyledgerIOS

iPhone app shell (iOS 16+) that mirrors the PepyLedger web UI via `WKWebView`.

## Runnable milestone status

This repo now includes a real Xcode project and shared scheme for local simulator runs:

- Project: `pepyledgerIOS.xcodeproj`
- App target: `pepyledgerIOS`
- Scheme: `pepyledgerIOS` (shared)
- Bundle ID: `com.pepyledger.ios`
- Deployment target: iOS 16+

## Module layout

- `App`: SwiftUI app entrypoint and environment wiring
- `Domain`: entities, contracts, and use-case interfaces
- `Data`: persistence + network adapters
- `Features`: screen-specific view models and views
- `Services`: Auth0, RevenueCat, OneSignal integrations
- `UI`: shared design system primitives

## Current scaffold coverage

- App launches into a full-screen `WKWebView` (`WebAppRootView`) and loads `WEB_APP_BASE_URL`.
- Navigation policy keeps trusted web/auth hosts in-app and opens non-trusted external links using iOS handlers.
- Auth redirects to Auth0 `/authorize` are elevated to `ASWebAuthenticationSession` so Google sign-in is not blocked by embedded-webview policy.
- Loading/error overlay is handled natively (spinner + retry), while product UI/UX is rendered by the website.
- Native scaffold modules (`Features`, `Data`, `Services`) are retained in-repo in this phase but are not app-root driven.

## Local config notes

Config files are in `App/Config`.

1. Copy `App/Config/Local.xcconfig.example` to `App/Config/Local.xcconfig`.
2. Set:
   - `WEB_APP_BASE_URL` (default `https://pepyledger.com`)
   - `AUTH0_DOMAIN` (used to treat tenant host as trusted in-webview during auth redirects)
   - optional legacy keys kept for compatibility with existing modules:
     - `SUPABASE_URL`
     - `AUTH0_CLIENT_ID`
     - `AUTH0_AUDIENCE`
     - `AUTH0_CALLBACK_SCHEME`
3. Keep `Local.xcconfig` uncommitted (ignored by `.gitignore`).

Runtime keys are passed via `App/Info.plist`:

- `WEB_APP_BASE_URL`
- `SUPABASE_URL`
- `AUTH0_DOMAIN`
- `AUTH0_CLIENT_ID`
- `AUTH0_AUDIENCE`
- `AUTH0_CALLBACK_SCHEME`

## Auth0 web contract (mirror mode)

Because the app mirrors the website, Auth0 should be configured for the web origin:

- Allowed Callback URLs: `https://pepyledger.com/auth/callback`
- Allowed Logout URLs: `https://pepyledger.com`
- Allowed Web Origins: `https://pepyledger.com`

For Google social login, ensure the Google connection is enabled for this Auth0 application in
`Auth0 Dashboard -> Authentication -> Social -> Google -> Applications`.
The iOS shell now routes the auth transaction through `ASWebAuthenticationSession` and then returns the callback URL to the in-app webview.

## Local simulator run

1. Ensure full Xcode is selected:
   - `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. Open `pepyledgerIOS.xcodeproj`.
3. Select scheme `pepyledgerIOS` and an iPhone simulator.
4. Run the app.
5. Verify milestone behavior:
   - cold launch loads `WEB_APP_BASE_URL` in-app
   - no top/bottom letterbox black bars on modern iPhones
   - website UI is identical to browser UI
   - Auth0/Google login completes in mirrored web flow
   - external links (mailto/tel/non-trusted domains) open via iOS handlers

## Tests

- Data sync tests: `Tests/DataTests/GRDBSyncStoreTests.swift`
  - retry/backoff on mutation failure
  - stale `in_flight` recovery
  - `STALE_MUTATION` acknowledgment behavior
  - `ACCOUNT_SCOPE_AMBIGUOUS` stop behavior
- Web navigation policy tests: `Tests/ServicesTests/WebNavigationPolicyTests.swift`
  - same-host and trusted auth hosts remain in webview
  - non-trusted external links open externally
  - `mailto:` and `tel:` use system handlers

## Tooling

- Swift Package dependencies: Auth0, RevenueCat, OneSignal, GRDB
- Fastlane lanes: `test`, `beta`, `release`, `metadata`
- GitHub Actions workflows: PR build/test, TestFlight beta, release gate
- Fastlane now uses explicit project/scheme wiring for non-interactive CI:
  - `IOS_PROJECT` (default `pepyledgerIOS.xcodeproj`)
  - `IOS_SCHEME` (default `pepyledgerIOS`)

## Build assumptions

- iPhone-only launch target
- iOS deployment target: 16.0
- Primary UI/auth source of truth is the website at `WEB_APP_BASE_URL`
- Native bridge features (downloads/share/push) are deferred in this phase
