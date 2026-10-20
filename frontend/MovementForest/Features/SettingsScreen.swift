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
                Text("Health observations stay in memory on this device and are not uploaded. A connected development garden saves plant arrangements to your own API.")
                Text("The app remembers only whether you have tried connecting Health. That preference is not proof of permission.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Accessibility") {
                Text("Plant details are also available through the Plants button. Wind animation follows your iPhone’s Reduce Motion setting.")
            }
            #if DEBUG
            Section("Development") {
                NavigationLink("Garden connection") { GardenConnectionScreen(connection: connection, catalog: catalog) }
                    .accessibilityIdentifier("settings.connection")
                NavigationLink("Developer tools") { DeveloperToolsScreen(catalog: catalog, activity: activity) }
                    .accessibilityIdentifier("settings.developer")
            }
            #endif
            Section { Text("Frontend baseline · iOS 16 and later").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Settings")
    }
}
