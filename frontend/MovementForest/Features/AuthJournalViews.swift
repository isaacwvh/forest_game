import SwiftUI

extension View {
    func journalAuthInput() -> some View {
        textFieldStyle(.plain).font(.body).padding(12).frame(minHeight: 48)
            .background(JournalTheme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(JournalTheme.vine.opacity(0.5), lineWidth: 1) }
    }
}

struct AuthJournalPage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(20).frame(maxWidth: .infinity)
        }
        .background(JournalPageBackground().ignoresSafeArea())
        .foregroundStyle(JournalTheme.ink).tint(JournalTheme.action)
        .toolbarBackground(JournalTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AuthHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(.largeTitle, design: .serif).weight(.semibold))
            .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            .padding(.top, 12)
    }
}

struct AuthIdentityHeader: View {
    let name: String
    let username: String?
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        let layout = textSize >= .xxxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) :
            AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            Group {
                if let portrait = ProfileIllustration.images[.portrait] {
                    Image(uiImage: portrait).resizable().scaledToFit()
                } else { Image(systemName: "leaf.fill").foregroundStyle(JournalTheme.action) }
            }.frame(width: 54, height: 54).padding(9)
                .background(JournalTheme.sage, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(.title, design: .serif).weight(.semibold))
                if let username = username {
                    Text("@\(username)").font(.subheadline).foregroundStyle(JournalTheme.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AuthStatusBand: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
            .fixedSize(horizontal: false, vertical: true).padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(JournalTheme.sage, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AuthProviderIcon: View {
    var google = false
    private static let googleImage = PresentationAssets.image("auth/google-g.png", maximumPixels: 64)
    var body: some View {
        Group {
            if google, let image = Self.googleImage {
                Image(uiImage: image).resizable().scaledToFit()
                    .padding(3).background(.white, in: RoundedRectangle(cornerRadius: 4))
            } else { Image(systemName: google ? "person.crop.circle" : "envelope").font(.title3) }
        }.frame(width: 26, height: 26).accessibilityHidden(true)
    }
}

struct AuthProviderButton: View {
    let title: String
    var google = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AuthProviderIcon(google: google)
                Text(title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                Color.clear.frame(width: 26, height: 1).accessibilityHidden(true)
            }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 50)
                .foregroundStyle(google ? Color(red: 0.122, green: 0.122, blue: 0.122) : JournalTheme.action)
                .background(google ? Color.white : JournalTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(google ? Color(red: 0.455, green: 0.467, blue: 0.459) : JournalTheme.vine, lineWidth: 1) }
                .opacity(enabled ? 1 : 0.55)
        }.buttonStyle(.plain)
    }
}

struct AuthMethodRow: View {
    let title: String
    var detail: String? = nil
    var google = false
    var state = "Linked"
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(spacing: 12) {
            let layout = textSize >= .xxxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) :
                AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                AuthProviderIcon(google: google)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium))
                    if let detail = detail { Text(detail).font(.subheadline).foregroundStyle(JournalTheme.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Label(state, systemImage: "checkmark").font(.footnote.weight(.medium)).foregroundStyle(JournalTheme.action)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }
}

struct AuthFeedback: View {
    @ObservedObject var auth: AuthenticationStore
    var body: some View {
        if auth.busy { ProgressView("Please wait…") }
        if let message = auth.message {
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.status")
        }
    }
}

struct AuthPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New password").font(.subheadline.weight(.medium))
                SecureField("At least 8 characters", text: $password).textContentType(.newPassword)
                    .journalAuthInput().accessibilityIdentifier("account.newPassword")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Confirm password").font(.subheadline.weight(.medium))
                SecureField("Confirm password", text: $confirmation).textContentType(.newPassword)
                    .journalAuthInput().accessibilityIdentifier("account.confirmPassword")
            }
        }
    }
}

struct EmailLinkScreen: View {
    @ObservedObject var auth: AuthenticationStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var editingEmail = false
    private var validPassword: Bool { password.count >= 8 && password == confirmation }
    var body: some View {
        AuthJournalPage {
            if auth.emailLinkVerified {
                AuthHeading(title: "Set a password")
                if let email = auth.emailLinkAddress { Text(email).foregroundStyle(JournalTheme.secondary) }
                AuthPasswordFields(password: $password, confirmation: $confirmation)
                Button("Link with email") {
                    let value = password; password = ""; confirmation = ""
                    Task { if await auth.updatePassword(value) { dismiss() } }
                }.buttonStyle(.journalPrimary).disabled(!validPassword || auth.busy)
                    .accessibilityIdentifier("account.finishEmailLink")
            } else if let address = auth.emailLinkAddress, !editingEmail {
                AuthHeading(title: "Verify your email")
                Text(address).foregroundStyle(JournalTheme.secondary).textSelection(.enabled)
                TextField("Verification code", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    .journalAuthInput().accessibilityIdentifier("account.emailCode")
                Button("Verify email") {
                    let value = code; code = ""
                    Task { await auth.verifyLinkedEmail(code: value) }
                }.buttonStyle(.journalPrimary).disabled(auth.busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Check verification") { Task { await auth.refreshLinkedEmail() } }.buttonStyle(.journalQuiet).disabled(auth.busy)
                Button("Resend email") { Task { await auth.linkEmail(address) } }.buttonStyle(.journalQuiet).disabled(auth.busy)
                Button("Use another email") { email = address; editingEmail = true }.buttonStyle(.journalQuiet).disabled(auth.busy)
            } else {
                AuthHeading(title: "Link with email")
                TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().journalAuthInput()
                    .accessibilityIdentifier("account.linkEmailAddress")
                Button("Continue") {
                    Task { await auth.linkEmail(email); editingEmail = false }
                }.buttonStyle(.journalPrimary).disabled(auth.busy || !email.contains("@"))
            }
            AuthFeedback(auth: auth)
        }.navigationTitle("Link with email")
            .onAppear { email = auth.emailLinkAddress ?? auth.user?.email ?? "" }
            .onDisappear { password = ""; confirmation = ""; code = "" }
            .onChange(of: scenePhase) { phase in
                if phase == .active, auth.emailLinkAddress != nil, !auth.busy {
                    Task { await auth.refreshLinkedEmail() }
                }
            }
    }
}

struct PasswordSettingsScreen: View {
    @ObservedObject var auth: AuthenticationStore
    @State private var password = ""
    @State private var confirmation = ""
    @State private var email = ""
    var body: some View {
        AuthJournalPage {
            AuthHeading(title: auth.recoveringPassword ? "Reset password" : "Email & password")
            if let address = auth.user?.email { Text(address).foregroundStyle(JournalTheme.secondary).textSelection(.enabled) }
            AuthPasswordFields(password: $password, confirmation: $confirmation)
            Button("Save password") {
                let value = password; password = ""; confirmation = ""
                Task { await auth.updatePassword(value) }
            }.buttonStyle(.journalPrimary).disabled(auth.busy || password.count < 8 || password != confirmation)
            if !auth.recoveringPassword {
                DisclosureGroup("Change email") {
                    TextField("New email", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().journalAuthInput().padding(.vertical, 8)
                    Button("Send verification email") { Task { await auth.updateEmail(email) } }
                        .buttonStyle(.journalSecondary).disabled(auth.busy || !email.contains("@"))
                }
            }
            AuthFeedback(auth: auth)
        }.navigationTitle("Email & password")
            .onDisappear { password = ""; confirmation = "" }
    }
}
