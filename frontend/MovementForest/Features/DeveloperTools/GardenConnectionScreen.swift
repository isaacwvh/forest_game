import SwiftUI

#if DEBUG || INTERNAL_TOOLS
@MainActor
struct GardenConnectionScreen: View {
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    @State private var url = ""
    @State private var token = ""
    @State private var username = ""
    @State private var displayName = ""
    var body: some View {
        Form {
            Section("Private development API") {
                TextField("HTTPS API address", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("connection.url")
                SecureField("Bearer token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("connection.token")
                Button(connection.connecting ? "Connecting…" : "Connect and load garden") {
                    Task {
                        await connection.connect(url: url, token: token, assets: catalog)
                        token = ""
                    }
                }.disabled(connection.busy)
                    .accessibilityIdentifier("connection.connect")
                if let status = connection.status { Text(status).font(.callout).accessibilityIdentifier("connection.status") }
            }
            if connection.accountRequired {
                Section("Create your account") {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Display name", text: $displayName)
                    Button("Create account and starter") { Task {
                        await connection.createAccount(username: username, displayName: displayName, assets: catalog)
                    } }.disabled(connection.busy || username.count < 3 || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("The game timezone is set from this iPhone when the account is created. Your starter enters storage.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Use your private HTTPS development address. Your computer must be awake with the API running. Development tokens expire after 30 minutes; generate a replacement on the backend computer.")
                Text("Your token is stored in Keychain. Step uploads require a separate opt-in in Activity. Reconnecting the same account resumes unresolved garden and activity requests.")
            }.font(.footnote).foregroundStyle(.secondary)
            if connection.editor != nil || !connection.savedURL.isEmpty {
                Section {
                    Button("Disconnect and view sample garden", role: .destructive) { connection.disconnect() }
                        .disabled(connection.busy)
                    Text("Pending saves stay associated with their original account and API address.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Garden connection")
            .onAppear { url = connection.savedURL }
    }
}
#endif
