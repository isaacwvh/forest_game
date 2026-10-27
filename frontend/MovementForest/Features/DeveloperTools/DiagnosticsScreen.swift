import SwiftUI
import UIKit
import RealityKit

@MainActor
final class LiveGardenDiagnostics {
    static let shared = LiveGardenDiagnostics()
    weak var renderer: RealityGardenRenderer?
}

#if DEBUG || INTERNAL_TOOLS
@MainActor
struct DiagnosticsScreen: View {
    @ObservedObject var connection: GardenConnection
    @ObservedObject private var history = DiagnosticHistory.shared
    @State private var category = "All"
    @State private var query = ""
    @State private var copied = false
    @State private var exported: DiagnosticExport?

    private var categories: [String] { ["All"] + Set(history.events.map(\.category)).sorted() }
    private var filtered: [DiagnosticEvent] {
        Array(history.events.filter {
            ($0.scope == nil || $0.scope == connection.editor?.diagnosticScope) &&
            (category == "All" || $0.category == category) &&
            (query.isEmpty || ($0.outcome + ($0.requestID ?? "")).localizedCaseInsensitiveContains(query))
        }.reversed())
    }
    private var snapshot: [String: String] {
        var result: [String: String] = ["connecting": String(connection.connecting)]
        if let editor = connection.editor {
            result["garden.state"] = String(describing: editor.state)
            result["garden.pendingRequest"] = editor.pendingRequestID ?? "none"
            result["garden.cached"] = String(editor.showingCached)
            result["garden.recoveryLocked"] = String(editor.recoveryLocked)
            result["garden.layoutVersion"] = editor.confirmed.map { String($0.layoutVersion) } ?? "unavailable"
            result["garden.stateVersion"] = editor.confirmed.map { String($0.stateVersion) } ?? "unavailable"
            result["garden.catalogueVersion"] = editor.catalogue?.catalogVersion ?? "unavailable"
            if let pending = editor.pending, let request = try? pending.request, let data = try? request.encoded() {
                result["garden.pendingPayload"] = String(decoding: data, as: UTF8.self)
            }
            result["inventory.loaded"] = String(editor.inventory.count)
            result["inventory.nextCursor"] = editor.nextCursor?.uuidString ?? "none"
        }
        if let sync = connection.activitySync {
            result["activity.pending"] = sync.requestIDs.map(\.uuidString).joined(separator: ", ")
            result["activity.baselineDate"] = sync.status?.device?.baselineDate ?? "unavailable"
            result["activity.baselineReady"] = sync.status?.device.map { String($0.ready) } ?? "unavailable"
            result["activity.recoveryLocked"] = String(sync.recoveryLocked)
        }
        if let visitors = connection.visitors {
            result["visitors.connected"] = String(visitors.connected)
            result["visitors.eligible"] = String(visitors.eligible)
            result["visitors.pending"] = visitors.pending?.id.uuidString ?? "none"
            result["visitors.queuedReward"] = visitors.queuedReward?.id.uuidString ?? "none"
            result["visitors.balance"] = visitors.confirmedTokenBalance ?? "unavailable"
            result["visitors.recoveryLocked"] = String(visitors.recoveryLocked)
        }
        if let collection = connection.collection {
            result["collection.pending"] = collection.state.pending?.id.uuidString ?? "none"
            result["collection.balance"] = collection.tokenBalance ?? "unavailable"
            result["collection.economyVersion"] = String(collection.economyVersion)
            result["collection.recoveryLocked"] = String(collection.recoveryLocked)
            if let pending = collection.state.pending {
                result["collection.pendingKind"] = pending.kind.rawValue
                if let object = try? JSONSerialization.jsonObject(with: pending.body) as? [String: Any] {
                    let safe = object.filter { ["requestId", "offerId", "offerVersion", "quantity"].contains($0.key) }
                    if let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) {
                        result["collection.pendingPayload"] = String(decoding: data, as: UTF8.self)
                    }
                }
            }
        }
        if let issue = connection.configurationIssue { result["configuration.issue"] = issue }
        if let renderer = LiveGardenDiagnostics.shared.renderer {
            result["renderer.identity"] = String(describing: ObjectIdentifier(renderer))
            result["renderer.modelLoads"] = String(renderer.modelLoadCount)
            result["renderer.modelsLoaded"] = String(renderer.loadedCount)
            result["renderer.loading"] = String(renderer.isLoading)
            result["renderer.butterflyReady"] = String(renderer.visitorAssetReady)
            result["renderer.butterflyIssue"] = renderer.visitorAssetIssue ?? "none"
            result["renderer.errors"] = renderer.errors.joined(separator: "\n")
        }
        return result
    }
    private var exportText: String {
        let state = (try? String(decoding: JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)) ?? "{}"
        return "Movement Forest local diagnostics\nState:\n" + state + "\nEvents:\n" + DiagnosticHistory.export(filtered)
    }

    var body: some View {
        List {
            if let renderer = LiveGardenDiagnostics.shared.renderer {
                Section("Mounted Garden") {
                    DetailRow(title: "Renderer identity", value: String(describing: ObjectIdentifier(renderer)))
                        .accessibilityIdentifier("diagnostic.renderer.identity")
                        .accessibilityValue(String(describing: ObjectIdentifier(renderer)))
                    LiveRenderIdentityRows(renderer: renderer)
                }
            }
            Section("Live account state") {
                ForEach(snapshot.keys.sorted(), id: \.self) { key in DetailRow(title: key, value: snapshot[key] ?? "unavailable") }
            }
            if let renderer = LiveGardenDiagnostics.shared.renderer {
                RenderDiagnostics(renderer: renderer, catalogue: connection.editor?.catalogue, isSample: connection.editor == nil)
            }
            Section("Recent events") {
                Picker("Category", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }
                if filtered.isEmpty { Text("No matching events. Reproduce the issue, then return here.") }
                ForEach(filtered) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.category).font(.headline)
                        Text(event.date.formatted(date: .abbreviated, time: .standard)).font(.caption)
                        Text(event.outcome).font(.callout)
                        if let id = event.requestID { Text("Request: " + id).font(.caption) }
                        Text("Session: " + event.session.uuidString).font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled).padding(.vertical, 4)
                }
            }
            Section("Share diagnostics") {
                Button(copied ? "Copied diagnostics" : "Copy diagnostics") { UIPasteboard.general.string = exportText; copied = true }
                Button("Export diagnostics") { exported = DiagnosticExport(text: exportText) }
                Text("Local recent history: up to 1,000 events, 2 MiB or seven days. Only the current account and general lifecycle events are shown. Health details remain in the explicit Health inspector. Nothing is uploaded automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.searchable(text: $query, prompt: "Outcome or request ID")
            .navigationTitle("Diagnostics").accessibilityIdentifier("developer.diagnostics")
            .sheet(item: $exported) { DiagnosticsShareSheet(text: $0.text) }
    }
}

private struct DiagnosticExport: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

@MainActor
private struct LiveRenderIdentityRows: View {
    @ObservedObject var renderer: RealityGardenRenderer
    private var camera: String {
        renderer.view.scene.anchors.compactMap { $0.findEntity(named: "garden-camera") }.first.map {
            String(describing: $0.transform)
        } ?? "unavailable"
    }
    var body: some View {
        DetailRow(title: "Loading", value: String(renderer.isLoading))
            .accessibilityIdentifier("diagnostic.renderer.loading").accessibilityValue(String(renderer.isLoading))
        DetailRow(title: "Model imports", value: String(renderer.modelLoadCount))
            .accessibilityIdentifier("diagnostic.renderer.imports").accessibilityValue(String(renderer.modelLoadCount))
        DetailRow(title: "Camera", value: camera)
            .accessibilityIdentifier("diagnostic.renderer.camera").accessibilityValue(camera)
    }
}
#endif
