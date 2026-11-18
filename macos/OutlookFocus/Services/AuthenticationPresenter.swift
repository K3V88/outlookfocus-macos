import AppKit
import AuthenticationServices
import OutlookFocusCore

@MainActor
final class AuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
  }
  func authenticate(url: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: url, callbackURLScheme: URL(string: MicrosoftAuth.redirectURI)!.scheme
      ) { [weak self] url, error in
        Task { @MainActor in self?.session = nil }
        if let url {
          continuation.resume(returning: url)
        } else {
          continuation.resume(
            throwing: FocusFailure.unavailable(
              (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                ? "Sign-in was cancelled." : "Microsoft sign-in did not complete."))
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = true
      self.session = session
      if !session.start() {
        self.session = nil
        continuation.resume(
          throwing: FocusFailure.unavailable("Could not open Microsoft authentication."))
      }
    }
  }
  func cancel() {
    session?.cancel()
    session = nil
  }
}
