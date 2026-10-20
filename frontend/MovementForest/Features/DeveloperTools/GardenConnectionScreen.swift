import SwiftUI

#if DEBUG
@MainActor
struct GardenConnectionScreen: View {
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    @State private var url = ""
    @State private var token = ""
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
                }.disabled(connection.connecting || connection.editor?.state.busy == true)
                    .accessibilityIdentifier("connection.connect")
                if let status = connection.status { Text(status).font(.callout).accessibilityIdentifier("connection.status") }
            }
            Section {
                Text("Use your private HTTPS development address. Your computer must be awake with the API running. Development tokens expire after 30 minutes; generate a replacement on the backend computer.")
                Text("Your token is stored in Keychain. Health observations are not uploaded. Reconnecting the same account resumes an unresolved garden save.")
            }.font(.footnote).foregroundStyle(.secondary)
            if connection.editor != nil || !connection.savedURL.isEmpty {
                Section {
                    Button("Disconnect and view sample garden", role: .destructive) { connection.disconnect() }
                        .disabled(connection.connecting || connection.editor?.state.busy == true)
                    Text("Pending saves stay associated with their original account and API address.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Garden connection")
            .onAppear { url = connection.savedURL }
    }
}
#endif
