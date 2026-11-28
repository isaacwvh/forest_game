import Foundation
import Combine

/// The root observes routing/attention, while HUDs and pages observe their stores.
/// Coalescing reads after willChange also prevents reading pre-publication values.
@MainActor
final class RootPresentationObserver: ObservableObject {
    private struct Snapshot: Equatable {
        let owners: [ObjectIdentifier?]
        let flags: [Bool]
        let savedURL: String
        let profile: UUID?
        let homeRevision: HomeAttentionRevision
        let hostedTotal: String?
        let notice: APILevelUpNotice?
        let attention: HomeAttention

        @MainActor init(_ connection: GardenConnection) {
            let editor = connection.editor, collection = connection.collection
            owners = [
                editor.map(ObjectIdentifier.init), connection.activitySync.map(ObjectIdentifier.init),
                connection.visitors.map(ObjectIdentifier.init), collection.map(ObjectIdentifier.init),
                connection.accountSummary.map(ObjectIdentifier.init), connection.levelUps.map(ObjectIdentifier.init),
                connection.expeditions.map(ObjectIdentifier.init)
            ]
            flags = [
                connection.connecting, connection.switching, connection.titleVisible,
                connection.authentication?.busy == true, editor?.editing == true,
                editor?.editorRendered != nil, editor?.canStartEditing == true,
                editor?.hasDraftChanges == true && editor?.pending == nil,
                connection.activitySync?.busy == true || editor?.connectionBusy == true
            ]
            savedURL = connection.savedURL; profile = editor?.profile.userId
            homeRevision = connection.homeAttentionRevision
            hostedTotal = connection.visitors?.summary?.hostedTotal
            notice = connection.levelUps?.presented
            attention = connection.homeAttention
        }
    }
    let objectWillChange = ObservableObjectPublisher()
    private var snapshot: Snapshot
    private var observation: AnyCancellable?
    private var scheduled = false

    init(connection: GardenConnection) {
        snapshot = Snapshot(connection)
        observation = connection.objectWillChange.sink { [weak self, weak connection] _ in
            guard let self = self, !self.scheduled else { return }
            self.scheduled = true
            Task { @MainActor [weak self, weak connection] in
                guard let self = self, let connection = connection else { return }
                self.scheduled = false
                let next = Snapshot(connection)
                guard self.snapshot != next else { return }
                self.snapshot = next
                self.objectWillChange.send()
            }
        }
    }
}
