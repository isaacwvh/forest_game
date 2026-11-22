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
                if auth.recoveringPassword {
                    PasswordSettingsScreen(auth: auth)
                } else {
                    ManagedAccountScreen(auth: auth, connection: connection, catalog: catalog)
                }
            } else {
                AuthJournalPage { AuthHeading(title: "Sign-in unavailable") }
            }
        }.navigationTitle("Account & save")
    }
}

@MainActor
private struct ManagedAccountScreen: View {
    @ObservedObject var auth: AuthenticationStore
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    @State private var username = ""
    @State private var displayName = ""
    @State private var signingIn = false
    @State private var confirmingLogout = false
    private var busy: Bool { auth.busy || connection.busy }
    private var needsGuestWarning: Bool {
        auth.needsGuestExitWarning
    }
    private var statusTitle: String {
        if auth.emailLinkAddress != nil, auth.user?.hasEmailPassword != true {
            return auth.emailLinkVerified ? "Finish email setup" : "Email verification pending"
        }
        return auth.user?.isAnonymous == true ? "Playing as guest" : "Account linked"
    }

    var body: some View {
        AuthJournalPage {
            if let user = auth.user {
                AuthIdentityHeader(name: connection.editor?.profile.displayName ?? (user.isAnonymous ? "Guest garden" : "Your account"),
                    username: connection.editor?.profile.username)
                AuthStatusBand(title: statusTitle, symbol: needsGuestWarning ? "exclamationmark.triangle" : "checkmark.circle.fill")
                signInMethods(user)
                if connection.accountRequired { profileSetup }
                else if connection.editor != nil { profileEditing }
                if connection.editor == nil, !connection.accountRequired, !connection.connecting {
                    Button("Reconnect") { Task { await connection.connectManaged(assets: catalog) } }
                        .buttonStyle(.journalSecondary).disabled(busy).accessibilityIdentifier("account.reconnect")
                }
                JournalSectionHeading(title: "Account access")
                Button("Open another garden") { signingIn = true }
                    .buttonStyle(.journalSecondary).disabled(busy).accessibilityIdentifier("account.switch")
                Button("Sign out", role: .destructive) {
                    if needsGuestWarning { confirmingLogout = true }
                    else { Task { await connection.signOut() } }
                }.buttonStyle(.journalQuiet).disabled(busy).accessibilityIdentifier("account.signOut")
                if connection.connecting { ProgressView("Connecting…") }
                if let status = connection.status, !connection.connecting { Text(status).font(.callout) }
                AuthFeedback(auth: auth)
            } else {
                AuthHeading(title: "Sign in")
                Button("Sign in to an existing garden") { signingIn = true }.buttonStyle(.journalPrimary)
            }
        }
        .sheet(isPresented: $signingIn, onDismiss: { Task { await connection.cancelStagedAccount() } }) {
            NavigationStack { AccountSignInScreen(connection: connection, auth: auth, catalog: catalog) { signingIn = false } }
        }
        .alert("Leave this guest garden?", isPresented: $confirmingLogout) {
            Button("Keep playing", role: .cancel) { }
            Button("Sign out", role: .destructive) { Task { await connection.signOut() } }
        } message: { Text("Link an account first to keep access.") }
        .accessibilityIdentifier("account.page")
        .onDisappear { auth.clearMessage() }
    }

    @ViewBuilder
    private func signInMethods(_ user: AuthUserInfo) -> some View {
        JournalSectionHeading(title: "Sign-in methods")
        if user.isAnonymous { Text("Link account to save progress").font(.callout).foregroundStyle(JournalTheme.secondary) }
        if user.methods.contains("google") {
            AuthMethodRow(title: "Google", google: true).accessibilityIdentifier("account.googleLinked")
        } else if auth.configuration.googleEnabled {
            AuthProviderButton(title: "Link with Google", google: true) { Task { await auth.google(link: true) } }
                .disabled(busy).accessibilityIdentifier("account.googleLink")
        }
        if user.hasEmailPassword {
            AuthMethodRow(title: "Email & password", detail: user.email, state: "Set up")
                .accessibilityIdentifier("account.emailLinked")
            NavigationLink("Email & password settings") { PasswordSettingsScreen(auth: auth) }
                .buttonStyle(.journalSecondary).disabled(busy).accessibilityIdentifier("account.emailSettings")
        } else {
            NavigationLink { EmailLinkScreen(auth: auth) } label: {
                Label(auth.emailLinkAddress == nil ? "Link with email" : "Finish email setup", systemImage: "envelope")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.journalSecondary).disabled(busy).accessibilityIdentifier("account.emailLink")
        }
        if user.methods.contains("apple") { AuthMethodRow(title: "Apple") }
        else if auth.configuration.appleEnabled { AppleAccountButton(auth: auth, link: true).disabled(connection.busy) }
        ForEach(user.methods.filter { !["google", "email", "apple"].contains($0) }, id: \.self) { method in
            AuthMethodRow(title: method.capitalized)
        }
    }

    private var profileSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            JournalSectionHeading(title: "Your profile")
            profileFields
            Button("Create garden") {
                Task { await connection.createAccount(username: username, displayName: displayName, assets: catalog) }
            }.buttonStyle(.journalPrimary).disabled(busy || !validName).accessibilityIdentifier("account.createProfile")
        }
    }
    private var profileEditing: some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalSectionHeading(title: "Your profile")
            DisclosureGroup("Edit name") {
                profileFields.padding(.top, 12)
                Button("Save name") { Task { await connection.updateProfile(username: username, displayName: displayName) } }
                    .buttonStyle(.journalSecondary).disabled(busy || !validName).padding(.top, 12)
            }.onAppear {
                if let profile = connection.editor?.profile { username = profile.username; displayName = profile.displayName }
            }
        }
    }
    private var validName: Bool { username.count >= 3 && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var profileFields: some View {
        VStack(spacing: 12) {
            TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .journalAuthInput().accessibilityIdentifier("account.username")
            TextField("Display name", text: $displayName).journalAuthInput().accessibilityIdentifier("account.displayName")
        }
    }
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
