import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

struct AccountScreen: View {
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    var body: some View {
        Group {
            if let auth = connection.authentication {
                ManagedAccountScreen(auth: auth, connection: connection, catalog: catalog)
            } else {
                List {
                    Text("Account sign-in is not configured in this build.").font(.headline)
                    Text("Sign-in is unavailable in this version. You can try again after installing an updated build.")
                    Text("You can continue exploring the sample garden.").foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Account")
    }
}

@MainActor
private struct ManagedAccountScreen: View {
    @ObservedObject var auth: AuthenticationStore
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var creating = false
    @State private var username = ""
    @State private var displayName = ""
    @State private var newEmail = ""
    private var validPassword: Bool { password.count >= 8 && password == confirmation }

    var body: some View {
        Form {
            if auth.recoveringPassword {
                Section("Choose a new password") {
                    passwordFields
                    Button("Save new password") { Task { await auth.updatePassword(password); clearPasswords() } }
                        .disabled(!validPassword || auth.busy)
                }
            } else if let user = auth.user {
                Section("Signed in") {
                    Text(user.email ?? "Your account").textSelection(.enabled)
                    Text("Sign-in methods: \(user.methods.joined(separator: ", "))").font(.footnote).foregroundStyle(.secondary)
                    if let status = connection.status { Text(status).font(.callout) }
                    if connection.connecting { ProgressView("Connecting to your garden…") }
                }
                if connection.accountRequired {
                    Section("Create your game profile") {
                        TextField("Game username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("account.username")
                        TextField("Display name", text: $displayName).accessibilityIdentifier("account.displayName")
                        Text("Your username is for your profile and friends. Use your email to sign in with a password.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Create account and starter") { Task {
                            await connection.createAccount(username: username, displayName: displayName, assets: catalog)
                        } }.disabled(connection.busy || auth.busy || username.count < 3 || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("account.createProfile")
                    }
                } else {
                    Section("Your garden") {
                        if let editor = connection.editor { Text("Playing as \(editor.profile.displayName)") }
                        Button("Reconnect to game") { Task { await connection.connectManaged(assets: catalog) } }
                            .disabled(connection.busy || auth.busy).accessibilityIdentifier("account.reconnect")
                    }
                }
                if auth.configuration.googleEnabled || auth.configuration.appleEnabled {
                    Section("Link another sign-in method") {
                        Text("Linked methods open this same garden. A method already used for a different account cannot merge the two gardens.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if auth.configuration.googleEnabled && !user.methods.contains("google") {
                            Button("Link Google") { Task { await auth.google(link: true) } }.disabled(auth.busy)
                        }
                        if auth.configuration.appleEnabled && !user.methods.contains("apple") {
                            AppleAccountButton(auth: auth, link: true)
                        }
                    }
                }
                Section("Email and password access") {
                    DisclosureGroup("Set or change password") {
                        Text("Use the verified account email shown above to sign in. Setting a password keeps your existing garden.")
                            .font(.footnote)
                        passwordFields
                        Button("Save password") { Task { await auth.updatePassword(password); clearPasswords() } }
                            .disabled(auth.busy || !validPassword)
                    }
                    DisclosureGroup("Change account email") {
                        TextField("New email", text: $newEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Send email verification") { Task { await auth.updateEmail(newEmail) } }
                            .disabled(auth.busy || newEmail.isEmpty)
                    }
                }
            } else {
                Section(creating ? "Create your account" : "Welcome back") {
                    TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("account.email")
                    SecureField("Password", text: $password).textContentType(creating ? .newPassword : .password)
                        .accessibilityIdentifier("account.password")
                    if creating {
                        SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                        Text("Use at least eight characters and follow the password requirements shown here.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(creating ? "Create account" : "Sign in") { Task {
                        if creating { await auth.signUp(email: email, password: password) }
                        else { await auth.signIn(email: email, password: password) }
                        clearPasswords()
                    } }.disabled(auth.busy || email.isEmpty || password.isEmpty || (creating && !validPassword))
                        .accessibilityIdentifier("account.submit")
                    Button(creating ? "Already have an account? Sign in" : "New here? Create an account") {
                        creating.toggle(); clearPasswords()
                    }.disabled(auth.busy)
                }
                if auth.configuration.googleEnabled || auth.configuration.appleEnabled {
                    Section("Or continue with") {
                        if auth.configuration.googleEnabled {
                            Button("Continue with Google") { Task { await auth.google(link: false) } }.disabled(auth.busy)
                        }
                        if auth.configuration.appleEnabled { AppleAccountButton(auth: auth, link: false) }
                    }
                }
                Section("Account help") {
                    Button("Forgot password?") { Task { await auth.resetPassword(email: email) } }.disabled(auth.busy || email.isEmpty)
                    Button("Resend confirmation email") { Task { await auth.resendConfirmation(email: email) } }.disabled(auth.busy || email.isEmpty)
                    Text("Open email links on this iPhone. Health uploads are a separate choice after sign-in.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if auth.busy { Section { ProgressView("Please wait…") } }
            if let message = auth.message { Section { Text(message).accessibilityIdentifier("account.status") } }
            if auth.user != nil {
                Section {
                    Button("Sign out", role: .destructive) { Task { await connection.signOut(); clearPasswords() } }
                        .disabled(auth.busy).accessibilityIdentifier("account.signOut")
                    Text("Saved garden and activity requests remain attached to this account and resume after you sign back in.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var passwordFields: some View {
        Group {
            SecureField("New password", text: $password).textContentType(.newPassword)
            SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
        }
    }
    private func clearPasswords() { password = ""; confirmation = "" }
}

@MainActor
private struct AppleAccountButton: View {
    @ObservedObject var auth: AuthenticationStore
    let link: Bool
    @State private var nonce: String?
    @State private var expectedIdentity: AuthIdentity?
    var body: some View {
        SignInWithAppleButton(link ? .continue : .signIn, onRequest: { request in
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                nonce = nil; auth.report("Apple sign-in could not start. Try again."); return
            }
            let value = bytes.map { String(format: "%02x", $0) }.joined()
            nonce = value; expectedIdentity = auth.user?.identity
            request.requestedScopes = [.email, .fullName]
            request.nonce = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }, onCompletion: { result in
            let value = nonce; nonce = nil
            switch result {
            case .success(let authorization):
                guard let value = value, auth.user?.identity == expectedIdentity,
                      let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                    auth.report("Apple sign-in was not confirmed. Try again."); return
                }
                Task { await auth.apple(idToken: token, nonce: value, link: link) }
            case .failure:
                auth.report("Apple sign-in did not finish. Your garden is unchanged.")
            }
        }).frame(height: 48).disabled(auth.busy)
    }
}
