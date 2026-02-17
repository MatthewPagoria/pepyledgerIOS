import SwiftUI

struct LoginView: View {
  let state: AuthSessionStore.State
  let onLogin: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "lock.shield")
        .font(.system(size: 54, weight: .semibold))
        .foregroundStyle(.blue)
      Text("Sign in to PepyLedger")
        .font(.title3.weight(.semibold))
      Text(subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)

      if case .failed(let message) = state {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding(.horizontal, 24)
          .multilineTextAlignment(.center)
      }
      if case .unavailable(let message) = state {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.orange)
          .padding(.horizontal, 24)
          .multilineTextAlignment(.center)
      }

      Button(action: onLogin) {
        if case .authenticating = state {
          ProgressView()
            .frame(maxWidth: .infinity)
        } else {
          Text("Continue with Auth0")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)
      .padding(.horizontal, 24)

      Spacer()
    }
    .padding(.bottom, 40)
  }

  private var isBusy: Bool {
    if case .authenticating = state { return true }
    return false
  }

  private var subtitle: String {
    switch state {
    case .authenticating:
      return "Opening secure login..."
    case .failed:
      return "Authentication failed. Check callback/audience settings and try again."
    case .unavailable:
      return "Auth configuration is incomplete."
    case .unauthenticated, .authenticated:
      return "Log in with your account to access sync-enabled member features."
    }
  }
}
