import SwiftUI

struct SettingsScreen: View {
    let catalog: any AssetCatalogProviding
    @ObservedObject var activity: ActivityStore
    @ObservedObject var connection: GardenConnection
    var sampleGarden: GardenSnapshot? = nil
    var body: some View {
        List {
            Section {
                NavigationLink("Account and sign-in") { AccountScreen(connection: connection, catalog: catalog) }
                    .accessibilityIdentifier("settings.account")
                NavigationLink("Game help") {
                    GameHelpScreen(connection: connection, catalog: catalog, sampleGarden: sampleGarden)
                }.accessibilityIdentifier("settings.gameHelp")
                NavigationLink("Your data") { dataInformation }
            }
            #if DEBUG || INTERNAL_TOOLS
            Section("Development") {
                NavigationLink("Developer tools") { DeveloperToolsScreen(catalog: catalog, activity: activity, connection: connection) }
                    .accessibilityIdentifier("settings.developer")
            }
            #endif
        }.navigationTitle("Settings")
    }

    private var dataInformation: some View {
        List {
            Section("Health and activity sync") {
                Text("Health reads stay on this iPhone until you enable activity sync in Activity.")
                Text("Full sync saves daily steps, walking/running distance, active energy, flights climbed and recorded workout details on this iPhone for retries, then uploads them to calculate growth. Existing steps-only consent stays steps-only until you enable optional inputs.")
                Text("You can pause future uploads in Activity. Health access and activity uploads are separate choices.")
            }
            Section("Saved garden and requests") {
                Text("Your confirmed garden is cached for offline viewing. Pausing sync retains unresolved requests; reconnect and re-enable sync to confirm them. Saved requests remain separate for each account.")
            }
        }.navigationTitle("Your data")
    }
}

/// Read-only help uses the connected stores; it never starts sessions or owns requests.
@MainActor
private struct GameHelpScreen: View {
    @ObservedObject var connection: GardenConnection
    let catalog: any AssetCatalogProviding
    let sampleGarden: GardenSnapshot?
    var body: some View {
        List {
            Section {
                DisclosureGroup("Garden controls") {
                    Text("Drag to orbit · Pinch to zoom · Two fingers to pan")
                    Text("Tap a plant to select it, then open Plant details. Tap empty ground to clear selection.")
                    Text("VoiceOver: use the garden scene’s Actions menu for camera controls. Inspect owned plants in My plants without selecting a 3D model.")
                    Text("Animations follow your iPhone’s Reduce Motion setting.")
                }.accessibilityIdentifier("help.controls")
                DisclosureGroup("Planting and storage") {
                    Text("My plants shows planted and stored copies. To plant: Edit → Storage → plant details → Place.")
                    Text("Use Edit to move, rotate or store plants. Done exits editing. Stored plants keep their identity and growth.")
                }
                DisclosureGroup("Visitors") {
                    Text("Tap butterflies in your open garden to welcome them. Tokens update after confirmation.")
                    Text("Placed plants provide attraction; higher stages attract more. Stored plants provide none.")
                    Text("Visits accumulate more slowly while away, up to storage capacity. Collect stored visits to receive tokens. Earned visits stay until collected.")
                    Text("Active visitors pause while editing or browsing other pages. Missed active visitors do not become stored visits.")
                }.accessibilityIdentifier("help.visitors")
                DisclosureGroup("Packs") {
                    Text("Exchange visitor tokens for unopened packs. Use the information button to inspect contents and odds without spending tokens.")
                    Text("Confirm a purchase, then open packs from Packs. Each opening saves one new sprout in storage. Older packs retain their original contents and odds.")
                    Text("Opening: confirm, tap to tear, tap to reveal, then Continue. Your confirmed plant is saved even if the animation is interrupted. Retry an interrupted request to recover its original result.")
                }
                DisclosureGroup("Growth and skills") {
                    Text("Eligible activity waters each planted copy according to its activity multipliers. Stored plants preserve progress without growing. Activity does not award visitor tokens.")
                    Text("Fully grown planted sources activate garden skills. Garden info shows current skills and bonuses; expand a skill for its description and source. Bonuses follow their stacking rules and caps.")
                }
            }
            if let visitors = connection.visitors { VisitorInformationSection(store: visitors) }
            if connection.editor == nil, let garden = sampleGarden {
                Section {
                    NavigationLink("Explore sample plants") { GardenPlantList(garden: garden, catalog: catalog) }
                        .accessibilityIdentifier("garden.samplePlants")
                }
            }
        }.navigationTitle("Game help")
    }
}
