import Foundation
import RealityKit
import CryptoKit
import Combine

/// One immutable bundled template for the process. Scene entities and animation
/// controllers belong to each renderer; a replacement never reimports this asset.
@MainActor
final class VisitorModelLibrary {
    static let shared = VisitorModelLibrary()
    private var template: Entity?
    private var loading: Task<Entity, Error>?
    private var generation = UUID()
    private(set) var loadCount = 0
    private let importer: @MainActor () async throws -> Entity

    init(importer: (@MainActor () async throws -> Entity)? = nil) {
        self.importer = importer ?? { try await VisitorModelLibrary.importTemplate() }
    }

    /// Begin importing at app startup, before authentication or visitor issuance.
    /// The single owned task fills the cache even when no renderer is attached.
    func preload() {
        guard template == nil else { return }
        _ = startLoading()
    }

    func cachedClone() -> Entity? { template?.clone(recursive: true) }

    func load() async throws -> Entity {
        if let cached = cachedClone() { return cached }
        let imported = try await startLoading().value
        try Task.checkCancellation()
        return imported.clone(recursive: true)
    }

    private func startLoading() -> Task<Entity, Error> {
        if let loading = loading { return loading }
        loadCount += 1
        let token = UUID(); generation = token
        let importer = importer
        let operation = Task { [weak self] in
            LifecycleDiagnostics.event("butterfly load started id=\(token)")
            defer { LifecycleDiagnostics.event("butterfly load ended id=\(token)") }
            do {
                let imported = try await importer()
                if let self = self, self.generation == token {
                    self.template = imported; self.loading = nil
                }
                return imported
            } catch {
                if let self = self, self.generation == token { self.loading = nil }
                LifecycleDiagnostics.event("butterfly import failed id=\(token) error=\(error.localizedDescription)")
                throw error
            }
        }
        loading = operation
        return operation
    }

    private static func importTemplate() async throws -> Entity {
        let (manifest, url) = try VisitorAssetManifest.load()
        let asset = manifest.assets[0]
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == asset.bytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
                throw ForestError.invalidData("Butterfly checksum mismatch.")
            }
        }.value
        LifecycleDiagnostics.event("butterfly checksum verified; RealityKit import started")
        let request = VisitorAssetLoadRequest()
        let imported = try await request.run { Entity.loadAsync(contentsOf: url).eraseToAnyPublisher() }
        LifecycleDiagnostics.event("butterfly RealityKit import completed")
        func hasAnimation(_ node: Entity) -> Bool {
            !node.availableAnimations.isEmpty || node.children.contains { hasAnimation($0) }
        }
        guard hasAnimation(imported) else { throw ForestError.assetLoad("Butterfly wing animation is unavailable.") }
        let adapter = Entity(); adapter.addChild(imported)
        if AssetOrientation.needsZUpCorrection(imported: imported.visualBounds(relativeTo: adapter).extents,
                                              authored: asset.bounds.extents) {
            adapter.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        }
        return adapter
    }
}

enum VisitorAssetLoadError: LocalizedError {
    case timedOut, empty
    var errorDescription: String? {
        switch self {
        case .timedOut: return "Butterfly artwork loading timed out. Tap Retry visitor artwork."
        case .empty: return "No butterfly model was imported. Tap Retry visitor artwork."
        }
    }
}

/// Keep the LoadRequest subscription alive until its one result, cancellation,
/// or deadline. A stalled import must not pin the process-wide cache in loading.
@MainActor
final class VisitorAssetLoadRequest {
    private var subscription: AnyCancellable?
    private var continuation: CheckedContinuation<Entity, Error>?

    func run(timeoutSeconds: TimeInterval = 10, _ makePublisher: () -> AnyPublisher<Entity, Error>) async throws -> Entity {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // collect emits exactly one array, including on empty completion.
                // Ignore .finished so it cannot race a queued receiveValue handler.
                subscription = makePublisher().prefix(1).collect()
                    .timeout(.milliseconds(max(1, Int(timeoutSeconds * 1000))), scheduler: DispatchQueue.main,
                             customError: { VisitorAssetLoadError.timedOut })
                    .sink(receiveCompletion: { [weak self] completion in
                        if case .failure(let error) = completion {
                            Task { @MainActor in self?.finish(.failure(error)) }
                        }
                    }, receiveValue: { [weak self] entities in
                        Task { @MainActor in
                            if let entity = entities.first { self?.finish(.success(entity)) }
                            else { self?.finish(.failure(VisitorAssetLoadError.empty)) }
                        }
                    })
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.failure(CancellationError())) }
        })
    }

    private func finish(_ result: Result<Entity, Error>) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        subscription?.cancel(); subscription = nil
        continuation.resume(with: result)
    }
}
