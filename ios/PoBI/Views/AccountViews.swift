import AuthenticationServices
import CryptoKit
import SwiftUI

/// "Sign in with Apple", used on Profile and on the first screen.
/// A guest's progress is kept; if the Apple ID already has an account, the player is asked first.
struct AppleSignInButton: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var pending: (idToken: String, nonce: String)?
    @State private var confirmSwitch = false
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 8) {
            SignInWithAppleButton(.signIn) { request in
                nonce = Self.randomNonce()
                request.requestedScopes = []
                request.nonce = Self.sha256(nonce)
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let tokenData = credential.identityToken,
                          let idToken = String(data: tokenData, encoding: .utf8) else {
                        failure = "Apple didn't send a sign-in token. Try again."
                        return
                    }
                    finish(idToken: idToken, nonce: nonce, replace: false)
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        failure = error.localizedDescription
                    }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 44)
            .disabled(working)
            .overlay { if working { ProgressView() } }
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "This Apple ID already has a Plate or Break It account. Switch to it?",
            isPresented: $confirmSwitch, titleVisibility: .visible
        ) {
            Button("Switch and replace this phone's progress", role: .destructive) {
                if let pending { finish(idToken: pending.idToken, nonce: pending.nonce, replace: true) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The ratings and check-ins on this phone (\(store.ratings.count) ratings) are from a guest account and will be removed. The Apple ID's account will be shown instead.")
        }
    }

    private func finish(idToken: String, nonce: String, replace: Bool) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let result = try await store.signInWithApple(idToken: idToken, nonce: nonce, replaceThisPhone: replace)
                if result == .needsConfirmation {
                    pending = (idToken, nonce)
                    confirmSwitch = true
                } else {
                    pending = nil
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The Account section of Profile: sign in, or how you're signed in, and deleting the account.
struct AccountSection: View {
    @EnvironmentObject private var store: GameStore
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var failure: String?

    var body: some View {
        Section {
            switch store.account {
            case .guest:
                AppleSignInButton()
            case .apple:
                Label("Signed in with Apple", systemImage: "apple.logo")
            case .appleSignInLost:
                Text("Your Apple sign-in ran out. Sign in again to keep sending your visits.")
                    .font(.footnote)
                AppleSignInButton()
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                if deleting {
                    HStack { ProgressView(); Text("Deleting…") }
                } else {
                    Text("Delete account")
                }
            }
            .disabled(deleting || store.account == .appleSignInLost)
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        } footer: {
            switch store.account {
            case .guest:
                Text("You're playing as a guest on this phone. Sign in with Apple to keep your ratings if you change or reset your iPhone. Everything you've done so far stays.")
            case .apple, .appleSignInLost:
                Text("Sign in with the same Apple ID on another iPhone to carry on there.")
            }
        }
        .confirmationDialog(
            "Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) { delete() }
        } message: {
            Text("This deletes your ratings, check-ins, team, nickname, friends and receipt photos from the game server and this phone. It can't be undone. Your allergy list stays on this phone.")
        }
    }

    private func delete() {
        deleting = true
        failure = nil
        Task {
            defer { deleting = false }
            do {
                try await store.deleteAccount()
            } catch {
                failure = "Couldn't delete the account: \(error.localizedDescription)"
            }
        }
    }
}
