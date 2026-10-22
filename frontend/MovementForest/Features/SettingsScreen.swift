import SwiftUI

struct SettingsScreen: View {
    let catalog: any AssetCatalogProviding
    @ObservedObject var activity: ActivityStore
    @ObservedObject var connection: GardenConnection
    var body: some View {
        List {
            Section("Movement Forest") {
                Text("An early version of your forest.").font(.headline)
                Text("Explore your forest, arrange your plants and inspect activity from Apple Health.")
                    .foregroundStyle(.secondary)
            }
            Section("Your data") {
                Text("Health reads stay local until you separately enable step sync in Activity. When enabled, daily step totals and observation dates are saved on this iPhone for reliable retries and uploaded to your connected backend. Recorded workouts remain local diagnostics.")
                Text("Your confirmed garden is cached for offline viewing. Pausing sync retains unresolved requests; reconnect and re-enable sync to confirm them. Disconnecting keeps each account’s pending operations separate.")
                Text("The app remembers only whether you have tried connecting Health. That preference is not proof of permission.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Your account") {
                NavigationLink("Account and sign-in") { AccountScreen(connection: connection, catalog: catalog) }
                    .accessibilityIdentifier("settings.account")
            }
            Section("Accessibility") {
                Text("Plant details are also available through the Plants button. Wind animation follows your iPhone’s Reduce Motion setting.")
            }
            #if DEBUG
            Section("Development") {
                if connection.authentication == nil && connection.configurationIssue == nil {
                    NavigationLink("Garden connection") { GardenConnectionScreen(connection: connection, catalog: catalog) }
                    .accessibilityIdentifier("settings.connection")
                }
                NavigationLink("Developer tools") { DeveloperToolsScreen(catalog: catalog, activity: activity) }
                    .accessibilityIdentifier("settings.developer")
            }
            #endif
            Section { Text("Frontend baseline · iOS 16 and later").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Settings")
    }
}
