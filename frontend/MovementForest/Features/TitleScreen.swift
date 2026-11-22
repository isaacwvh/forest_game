import SwiftUI

/// Entry intent is resolved before exposing any first-use actions.
@MainActor
struct TitleScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject var auth: AuthenticationStore
    let catalog: any AssetCatalogProviding
    @State private var signingIn = false
    @State private var confirmingNew = false
    @State private var showsLoading = false
    #if DEBUG
    @State private var accountFixture = false
    #endif
    @Environment(\.dynamicTypeSize) private var textSize
    private static let artwork = PresentationAssets.image("auth/title-background-v1.png", maximumPixels: 2000)
    private var working: Bool { auth.busy || connection.switching || connection.connecting || auth.restoring }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                JournalTheme.paper.ignoresSafeArea()
                if let image = Self.artwork {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .accessibilityHidden(true)
                }
                ScrollView {
                    VStack(spacing: 16) {
                        if Self.artwork == nil {
                            Text("forestivity").font(.system(.largeTitle, design: .serif).weight(.bold))
                            Text("Good things grow with you.").font(.system(.body, design: .serif))
                        }
                        if auth.restoring {
                            if showsLoading { ProgressView("Finding your garden…") }
                        } else if auth.restoreUnavailable {
                            Button("Try again") { auth.retryRestore() }.buttonStyle(TitlePrimaryButtonStyle())
                            Text("Saved sign-in unavailable.").font(.callout)
                        } else if auth.user != nil {
                            Button(primaryTitle) {
                                if auth.recoveringPassword || connection.accountRequired { signingIn = true }
                                else { Task { await connection.enterGarden(assets: catalog) } }
                            }.buttonStyle(TitlePrimaryButtonStyle()).disabled(working)
                                .accessibilityIdentifier("title.primary")
                            if working {
                                if showsLoading { ProgressView("Connecting to your garden…") }
                            } else if connection.status != nil, !auth.recoveringPassword, !connection.accountRequired {
                                Text("Couldn’t connect. Tap Continue to retry.").font(.footnote)
                                    .multilineTextAlignment(.center).accessibilityIdentifier("title.connectionRetry")
                            }
                        } else {
                            Button(auth.configuration.guestEnabled ? "Play" : "Sign in") {
                                if auth.configuration.guestEnabled {
                                    if auth.hasHistory { confirmingNew = true }
                                    else { Task { await connection.startGuest(assets: catalog) } }
                                } else { signingIn = true }
                            }.buttonStyle(TitlePrimaryButtonStyle()).disabled(working).accessibilityIdentifier("title.primary")
                            if auth.configuration.guestEnabled {
                                Button("Sign in to an existing garden") { signingIn = true }
                                    .buttonStyle(.journalSecondary).disabled(working).accessibilityIdentifier("title.signIn")
                            }
                            if working, showsLoading { ProgressView("Preparing your garden…") }
                            if let message = connection.status, !working { Text(message).font(.footnote).multilineTextAlignment(.center) }
                        }
                    }
                    .frame(maxWidth: 330).padding(16)
                    .background(JournalTheme.paper.opacity(textSize.isAccessibilitySize ? 0.98 : 0), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24).padding(.top, geometry.size.height * 0.49).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }
            }.foregroundStyle(JournalTheme.ink)
        }
        .ignoresSafeArea().accessibilityIdentifier("auth.title")
        #if DEBUG
        .task {
            accountFixture = ProcessInfo.processInfo.arguments.contains("--fixture-auth") &&
                ProcessInfo.processInfo.arguments.contains("--auth-account")
        }
        .sheet(isPresented: $accountFixture) {
            NavigationStack { AccountScreen(connection: connection, catalog: catalog) }
        }
        #endif
        .task(id: working) {
            showsLoading = false
            guard working else { return }
            // Delay only the indicator, never successful entry into the garden.
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            showsLoading = true
        }
        .task(id: connection.stagedPasswordRecovery) {
            if connection.stagedPasswordRecovery { signingIn = true }
        }
        .onChange(of: auth.recoveringPassword) { if $0 { signingIn = true } }
        .sheet(isPresented: $signingIn, onDismiss: { Task { await connection.cancelStagedAccount() } }) {
            NavigationStack {
                if auth.recoveringPassword || connection.accountRequired {
                    AccountScreen(connection: connection, catalog: catalog)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { signingIn = false } } }
                } else {
                    AccountSignInScreen(connection: connection, auth: auth, catalog: catalog) { signingIn = false }
                }
            }
        }
        .alert("Start a new garden?", isPresented: $confirmingNew) {
            Button("Cancel", role: .cancel) { }
            Button("Start new", role: .destructive) { Task { await connection.startGuest(assets: catalog) } }
        } message: { Text(auth.lastWasGuest ? "Your previous guest may be unrecoverable." : "Your previous garden stays with its account.") }
    }
    private var primaryTitle: String {
        if auth.recoveringPassword { return "Reset password" }
        if connection.accountRequired { return "Finish garden setup" }
        return "Continue your garden"
    }
}

private struct TitlePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.title2, design: .serif).weight(.semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(JournalTheme.paper).padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(JournalTheme.action.opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.7), in: Capsule())
    }
}

@MainActor
struct AccountSignInScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject var auth: AuthenticationStore
    let catalog: any AssetCatalogProviding
    let done: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var allowGuestExit = false
    @State private var emailEntry = false
    private var busy: Bool { connection.switching || connection.connecting || auth.busy || auth.candidate?.busy == true }
    private var needsWarning: Bool { auth.needsGuestExitWarning && !allowGuestExit }
    private var showingEmailEntry: Bool {
        emailEntry && !needsWarning && connection.stagedProfile == nil && !connection.stagedMissingGarden && !connection.stagedPasswordRecovery
    }

    var body: some View {
        AuthJournalPage {
            if needsWarning {
                AuthHeading(title: "Keep access to this garden")
                Text("This guest garden may be lost after switching accounts.").font(.callout)
                Button("Back to sign-in methods") { done() }.buttonStyle(.journalPrimary)
                Button("Continue to sign in") { allowGuestExit = true }.buttonStyle(.journalSecondary)
                Button("Keep this garden") { done() }.buttonStyle(.journalQuiet)
            } else if connection.stagedPasswordRecovery, let recovery = auth.candidate {
                StagedPasswordRecoveryView(auth: recovery, connection: connection)
            } else if let profile = connection.stagedProfile {
                AuthHeading(title: "Your garden is here")
                AuthIdentityHeader(name: profile.displayName, username: profile.username)
                Button("Open this garden") {
                    Task { await connection.commitStagedAccount(assets: catalog); if !connection.titleVisible { done() } }
                }.buttonStyle(.journalPrimary).accessibilityIdentifier("account.openGarden")
                Button("Use another account") { Task { await connection.cancelStagedAccount() } }.buttonStyle(.journalQuiet)
            } else if connection.stagedMissingGarden {
                AuthHeading(title: "No garden on this account")
                Button("Create a garden") {
                    Task { await connection.createStagedGarden(assets: catalog); if !connection.titleVisible { done() } }
                }.buttonStyle(.journalPrimary)
                Button("Use another account") { Task { await connection.cancelStagedAccount() } }.buttonStyle(.journalQuiet)
            } else if emailEntry {
                AuthHeading(title: "Sign in with email")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Email").font(.subheadline.weight(.medium))
                    TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().journalAuthInput()
                        .accessibilityIdentifier("account.email")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password").font(.subheadline.weight(.medium))
                    SecureField("Password", text: $password).textContentType(.password).journalAuthInput()
                        .accessibilityIdentifier("account.password")
                }
                Button {
                    let value = password; password = ""
                    Task { await connection.stageEmail(email: email, password: value) }
                } label: { Label("Sign in with email", systemImage: "envelope").frame(maxWidth: .infinity) }
                    .buttonStyle(.journalPrimary).disabled(email.isEmpty || password.isEmpty).accessibilityIdentifier("account.submit")
                Button("Forgot password?") { Task { await connection.requestStagedPasswordReset(email: email) } }
                    .buttonStyle(.journalQuiet).disabled(email.isEmpty)
                Button("Resend confirmation email") { Task { await auth.resendConfirmation(email: email) } }
                    .buttonStyle(.journalQuiet).disabled(email.isEmpty)
            } else {
                AuthHeading(title: "Welcome back")
                if auth.configuration.googleEnabled {
                    AuthProviderButton(title: "Continue with Google", google: true) { Task { await connection.stageGoogle() } }
                        .accessibilityIdentifier("account.googleSignIn")
                }
                AuthProviderButton(title: "Sign in with email") { emailEntry = true }
                    .accessibilityIdentifier("account.emailSignIn")
            }
            if busy { ProgressView("Please wait…") }
            if let status = connection.status, !busy { Text(status).font(.callout) }
            if let message = auth.message, !busy { Text(message).font(.callout).accessibilityIdentifier("account.status") }
        }
        .disabled(busy).navigationTitle(showingEmailEntry ? "Email sign-in" : "Sign in")
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(showingEmailEntry ? "Back" : "Cancel") {
                password = ""
                if showingEmailEntry { emailEntry = false }
                else { Task { await connection.cancelStagedAccount(); done() } }
            }.disabled(busy)
        } }
        .interactiveDismissDisabled(busy)
        .onAppear { connection.signInPresentationChanged(true) }
        .onDisappear { password = ""; connection.signInPresentationChanged(false) }
        .preference(key: EntryPresentationBlocker.self, value: true)
    }
}

private struct StagedPasswordRecoveryView: View {
    @ObservedObject var auth: AuthenticationStore
    @ObservedObject var connection: GardenConnection
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AuthHeading(title: "Reset password")
            if !auth.recoveringPassword {
                Button("Retry garden verification") {
                    Task { await connection.finishStagedPasswordRecovery(password: "") }
                }.buttonStyle(.journalPrimary)
            } else {
            AuthPasswordFields(password: $password, confirmation: $confirmation)
            Button("Save password") {
                let value = password; password = ""; confirmation = ""
                Task { await connection.finishStagedPasswordRecovery(password: value) }
            }.buttonStyle(.journalPrimary).disabled(auth.busy || password.count < 8 || password != confirmation)
            }
            AuthFeedback(auth: auth)
        }.onDisappear { password = ""; confirmation = "" }
    }
}

extension View {
    func journalAuthForm() -> some View {
        self.scrollContentBackground(.hidden).background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
    }
}
