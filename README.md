# pepyledgerIOS

Native iPhone app (iOS 16+) for full member parity with the web platform.

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

- SwiftUI member shell with tabs for: Dashboard, Peptides, Log, Cycles, Inventory, Calculator, Essentials, Peptide Library, Billing, Support, Settings.
- Billing surface wired to a unified-status view model placeholder (`get-subscription-status` contract).
- GRDB sync store implemented with:
  - entity table mirroring for `peptides`, `vials`, `oilBottles`, `pillPacks`, `doseLogs`, `cycles`, `scheduleRules`, `dashboardNotes`
  - outbox queue (`clientMutationId`, retry backoff, stale `in_flight` reset)
  - `sync-pull` tombstone-first import
  - `sync-mutate` drain semantics with `STALE_MUTATION` ack + fresh-pull signal and `ACCOUNT_SCOPE_AMBIGUOUS` stop
  - `sync-push` snapshot client
- App startup wiring includes auth-gated launch/foreground sync bootstrap in `AppEnvironment`.
- Auth path uses native Auth0 WebAuth first-class flow (`Auth0Service`) with session persistence.
- App routing is deterministic:
  - unauthenticated/auth failure -> `LoginView`
  - authenticated -> `MemberShellView`
- Settings includes manual `Sync now` and `Log out` actions.

## Local config notes

Config files are in `App/Config`.

1. Copy `App/Config/Local.xcconfig.example` to `App/Config/Local.xcconfig`.
2. Set:
   - `SUPABASE_URL`
   - `AUTH0_DOMAIN`
   - `AUTH0_CLIENT_ID`
   - `AUTH0_AUDIENCE`
   - `AUTH0_CALLBACK_SCHEME` (default `com.pepyledger.ios`)
3. Keep `Local.xcconfig` uncommitted (ignored by `.gitignore`).

Runtime keys are passed via `App/Info.plist`:

- `SUPABASE_URL`
- `AUTH0_DOMAIN`
- `AUTH0_CLIENT_ID`
- `AUTH0_AUDIENCE`
- `AUTH0_CALLBACK_SCHEME`

## Auth0 callback/logout contract

For bundle ID `com.pepyledger.ios`, set these allowed URLs in Auth0:

- Callback URL: `com.pepyledger.ios://<AUTH0_DOMAIN>/ios/com.pepyledger.ios/callback`
- Logout URL: `com.pepyledger.ios://<AUTH0_DOMAIN>/ios/com.pepyledger.ios/callback`

If the app shows `unauthorized_client` or callback mismatch, verify these values first.

## Local simulator run

1. Ensure full Xcode is selected:
   - `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. Open `pepyledgerIOS.xcodeproj`.
3. Select scheme `pepyledgerIOS` and an iPhone simulator.
4. Run the app.
5. Verify milestone behavior:
   - cold launch shows login screen
   - Auth0 login succeeds
   - app transitions to member shell
   - sync banner transitions to ready after pull
   - foreground transition re-runs sync without crash

## Tests

- Data sync tests: `Tests/DataTests/GRDBSyncStoreTests.swift`
  - retry/backoff on mutation failure
  - stale `in_flight` recovery
  - `STALE_MUTATION` acknowledgment behavior
  - `ACCOUNT_SCOPE_AMBIGUOUS` stop behavior

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
- Billing on iOS uses StoreKit products via RevenueCat
- Backend integration uses existing Supabase edge APIs (`sync-*`, `get-subscription-status`, notification endpoints)
