import Foundation
import Combine

protocol GardenRepository {
    func loadGarden() async throws -> GardenSnapshot
}

struct SampleGardenRepository: GardenRepository {
    let bundle: Bundle
    init(bundle: Bundle = .main) { self.bundle = bundle }
    func loadGarden() async throws -> GardenSnapshot {
        guard let url = bundle.url(forResource: "sample-garden", withExtension: "json", subdirectory: "Fixtures") else {
            throw ForestError.missingResource("Fixtures/sample-garden.json")
        }
        return try JSONDecoder().decode(GardenSnapshot.self, from: Data(contentsOf: url)).validated()
    }
}

@MainActor
final class GardenStore: ObservableObject {
    @Published private(set) var garden: GardenSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private let repository: any GardenRepository
    init(repository: any GardenRepository) { self.repository = repository }
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do { garden = try await repository.loadGarden(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
