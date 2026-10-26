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
                Text("Health reads stay local until you enable activity sync in Activity. With full sync enabled, daily steps, walking/running distance, active energy, flights climbed and recorded workout details are saved on this iPhone for reliable retries and uploaded to calculate plant growth. Existing steps-only consent stays steps-only until you enable the optional inputs.")
                Text("Your confirmed garden is cached for offline viewing. Pausing sync retains unresolved requests; reconnect and re-enable sync to confirm them. Disconnecting keeps each account’s pending operations separate.")
            }
            Section("Your account") {
                NavigationLink("Account and sign-in") { AccountScreen(connection: connection, catalog: catalog) }
                    .accessibilityIdentifier("settings.account")
            }
            Section("Accessibility") {
                Text("Inspect your copies in My plants, or use the Garden’s Plants list. Arrange plants through Edit → Storage → plant details → Place. Animation follows your iPhone’s Reduce Motion setting.")
            }
            #if DEBUG || INTERNAL_TOOLS
            Section("Development") {
                NavigationLink("Developer tools") { DeveloperToolsScreen(catalog: catalog, activity: activity, connection: connection) }
                    .accessibilityIdentifier("settings.developer")
            }
            #endif
        }.navigationTitle("Settings")
    }
}
