import SwiftUI

/// The title routes explicit intent; rendering it never creates an account.
@MainActor
struct TitleScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject var auth: AuthenticationStore
    let catalog: any AssetCatalogProviding
    @State private var signingIn = false
    @State private var confirmingNew = false
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
                        .ignoresSafeArea().accessibilityHidden(true)
                }
                ScrollView {
                    VStack(spacing: 12) {
                        if Self.artwork == nil {
                            Text("forestivity").font(.system(.largeTitle, design: .serif).weight(.bold))
                            Text("Good things grow with you.").font(.system(.body, design: .serif))
                        }
                        if auth.restoring {
                            ProgressView("Finding your garden…")
                        } else if auth.restoreUnavailable {
                            Text("Saved sign-in unavailable.").font(.callout)
                            Button("Try again") { auth.retryRestore() }.buttonStyle(.journalPrimary)
                        } else {
                            if auth.user == nil && auth.lastWasGuest {
                                Text("Guest access was lost. Sign in to a linked garden or start new.")
                                    .font(.callout).multilineTextAlignment(.center)
                            }
                            Button(primaryTitle) {
                                if auth.recoveringPassword || connection.accountRequired { signingIn = true }
                                else if auth.user != nil { Task { await connection.enterGarden(assets: catalog) } }
                                else if !auth.hasHistory && auth.configuration.guestEnabled {
                                    Task { await connection.startGuest(assets: catalog) }
                                } else { signingIn = true }
                            }.buttonStyle(TitlePrimaryButtonStyle()).accessibilityIdentifier("title.primary")
                            if auth.user != nil || auth.hasHistory || !auth.configuration.guestEnabled {
                                if auth.user != nil {
                                    Button("Sign in another way") { signingIn = true }.buttonStyle(.journalQuiet)
                                }
                                if auth.configuration.guestEnabled {
                                    Button("Start a new garden") { confirmingNew = true }.buttonStyle(.journalQuiet)
                                        .accessibilityIdentifier("title.newGarden")
                                }
                            } else {
                                Button("I already have a garden") { signingIn = true }.buttonStyle(.journalQuiet)
                            }
                            if working { ProgressView("Please wait…") }
                            if let message = connection.status, !working, !message.hasPrefix("Signed in as ") {
                                Text(message).font(.footnote).multilineTextAlignment(.center)
                            }
                        }
                    }
                    .frame(maxWidth: 330)
                    .padding(16)
                    .background(JournalTheme.paper.opacity(textSize.isAccessibilitySize ? 0.98 : 0), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)
                    .padding(.top, geometry.size.height * 0.49)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                }.disabled(working && !auth.restoring)
            }.foregroundStyle(JournalTheme.ink)
                .accessibilityLabel("Forestivity. Good things grow with you.")
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
        } message: {
            Text(auth.user?.isAnonymous == true ? "This guest garden may be lost unless you link it first." :
                (auth.lastWasGuest ? "Your old guest may be unrecoverable." : "Your previous garden stays with its account."))
        }
    }

    private var primaryTitle: String {
        if auth.recoveringPassword { return "Reset password" }
        if connection.accountRequired { return "Finish garden setup" }
        return auth.entryAction == .continueGarden ? "Continue your garden" :
            (auth.entryAction == .play ? "Play" : "Sign back in")
    }
}

private struct TitlePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.title2, design: .serif).weight(.semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(JournalTheme.paper)
            .padding(.horizontal, 28).padding(.vertical, 12)
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
    private var busy: Bool { connection.switching || connection.connecting || auth.busy }
    private var needsWarning: Bool { auth.user?.isAnonymous == true && !allowGuestExit }

    var body: some View {
        Form {
            if needsWarning {
                Section {
                    Label("This guest garden may be lost after switching accounts.", systemImage: "exclamationmark.triangle")
                    Button("Continue to sign in") { allowGuestExit = true }.buttonStyle(.journalSecondary)
                    Button("Keep this garden") { done() }.buttonStyle(.journalQuiet)
                }
            } else if let profile = connection.stagedProfile {
                Section("Garden found") {
                    Text(profile.displayName).font(.system(.title2, design: .serif))
                    Text("@\(profile.username)").font(.footnote).foregroundStyle(JournalTheme.secondary)
                    Button("Open this garden") {
                        Task { await connection.commitStagedAccount(assets: catalog); if !connection.titleVisible { done() } }
                    }.buttonStyle(.journalPrimary).accessibilityIdentifier("account.openGarden")
                    Button("Use another account") { Task { await connection.cancelStagedAccount() } }.buttonStyle(.journalQuiet)
                }
            } else if connection.stagedMissingGarden {
                Section {
                    Text("No garden on this account.")
                    Button("Create a garden") {
                        Task { await connection.createStagedGarden(assets: catalog); if !connection.titleVisible { done() } }
                    }.buttonStyle(.journalPrimary)
                    Button("Use another account") { Task { await connection.cancelStagedAccount() } }.buttonStyle(.journalQuiet)
                }
            } else {
                if auth.configuration.googleEnabled {
                    Section {
                        Button("Continue with Google") { Task { await connection.stageGoogle() } }
                            .buttonStyle(.journalSecondary).accessibilityIdentifier("account.googleSignIn")
                    }
                }
                Section("Email and password") {
                    TextField("Email", text: $email).textContentType(.username)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("account.email")
                    SecureField("Password", text: $password).textContentType(.password)
                        .accessibilityIdentifier("account.password")
                    Button("Sign in") {
                        let value = password; password = ""
                        Task { await connection.stageEmail(email: email, password: value) }
                    }.buttonStyle(.journalPrimary).disabled(email.isEmpty || password.isEmpty)
                        .accessibilityIdentifier("account.submit")
                    Button("Forgot password?") { Task { await auth.resetPassword(email: email) } }
                        .buttonStyle(.journalQuiet).disabled(email.isEmpty)
                    Text("Open recovery email on this iPhone.").font(.footnote)
                }
                if auth.user == nil {
                    Section {
                        NavigationLink("Create an email account") {
                            AccountScreen(connection: connection, catalog: catalog)
                        }
                        Button("Resend confirmation") { Task { await auth.resendConfirmation(email: email) } }
                            .buttonStyle(.journalQuiet).disabled(email.isEmpty)
                    }
                }
            }
            if busy { Section { ProgressView("Please wait…") } }
            if let status = connection.status, !busy { Section { Text(status).font(.callout) } }
            if let message = auth.message, !busy { Section { Text(message).font(.callout) } }
        }
        .journalAuthForm()
        .disabled(busy)
        .navigationTitle("Sign back in").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { Task { await connection.cancelStagedAccount(); done() } }.disabled(busy)
        } }
        .interactiveDismissDisabled(busy)
        .onDisappear { password = "" }
        .preference(key: EntryPresentationBlocker.self, value: true)
    }
}

extension View {
    func journalAuthForm() -> some View {
        self.scrollContentBackground(.hidden)
            .background(JournalPageBackground().ignoresSafeArea())
            .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
    }
}
