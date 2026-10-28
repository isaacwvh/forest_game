import Foundation
import RealityKit
import UIKit

/// iOS 16-compatible shared geometry; no per-species animation or shader assets.
/// Runs on the garden's existing frame subscription and owns no frame clock.
@MainActor
final class SharedGardenEffects {
    static let maximumConcurrent = 6
    private let dropletMesh = MeshResource.generateSphere(radius: 1)
    private let sparkleMesh = MeshResource.generateBox(size: 1, cornerRadius: 0.12)
    private struct Pending {
        let target: GardenEffectTarget
        let source: Entity
        let reduced: Bool
        let replace: () -> Entity?
    }
    private struct Surface {
        let entity: Entity
        let materials: [any Material]
        let height: Float
    }
    @MainActor private final class Effect {
        let pending: Pending
        let root = Entity()
        var source: Entity
        var surfaces: [Surface] = []
        var particles: [ModelEntity] = []
        var age: TimeInterval = 0
        var replaced = false
        var radius: Float = 0.3
        var bottom: Float = 0
        var height: Float = 0.5
        var duration: TimeInterval { pending.reduced ? 0.5 : (pending.target.water ? 1.35 : 0.75) }
        var peak: TimeInterval { pending.reduced ? 0.15 : (pending.target.water ? 0.70 : 0.28) }
        init(_ pending: Pending) { self.pending = pending; source = pending.source }
    }
    private var queue: [Pending] = []
    private var running: [Effect] = []
    private weak var parent: Entity?
    var activeCount: Int { running.count }
    var queuedCount: Int { queue.count }
    var plantIDs: Set<UUID> { Set(running.map { $0.pending.target.id } + queue.map { $0.target.id }) }

    func enqueue(_ target: GardenEffectTarget, source: Entity, parent: Entity,
                 reducedMotion: Bool, replace: @escaping () -> Entity?) {
        self.parent = parent
        queue.append(.init(target: target, source: source, reduced: reducedMotion, replace: replace))
        fillSlots()
    }

    func tick(_ delta: TimeInterval) {
        guard delta.isFinite, delta > 0 else { return }
        for effect in running {
            effect.age += delta
            if !effect.replaced && effect.age >= effect.peak {
                restore(effect)
                effect.source = effect.pending.replace() ?? effect.source
                capture(effect)
                effect.replaced = true
            }
            update(effect)
        }
        for effect in running where effect.age >= effect.duration {
            restore(effect); effect.root.removeFromParent()
        }
        running.removeAll { $0.age >= $0.duration }
        fillSlots()
    }

    func cancel() {
        for effect in running { restore(effect); effect.root.removeFromParent() }
        running = []; queue = []; parent = nil
    }

    private func fillSlots() {
        guard let parent = parent else { return }
        while running.count < Self.maximumConcurrent && !queue.isEmpty {
            let effect = Effect(queue.removeFirst())
            effect.root.name = "growth-effect-\(effect.pending.target.id.uuidString)"
            effect.root.transform = effect.source.transform
            parent.addChild(effect.root)
            capture(effect)
            if !effect.pending.reduced {
                for index in 0..<12 {
                    let water = effect.pending.target.water && index < 6
                    let color = water ? UIColor(red: 0.52, green: 0.82, blue: 0.98, alpha: 1) :
                        (index.isMultiple(of: 2) ? UIColor(red: 0.82, green: 0.94, blue: 0.62, alpha: 1) :
                            UIColor(red: 1, green: 0.91, blue: 0.62, alpha: 1))
                    let particle = ModelEntity(mesh: water ? dropletMesh : sparkleMesh,
                                              materials: [UnlitMaterial(color: color)])
                    particle.scale = .zero
                    effect.root.addChild(particle); effect.particles.append(particle)
                }
            }
            running.append(effect)
        }
    }

    private func capture(_ effect: Effect) {
        effect.root.transform = effect.source.transform
        let bounds = effect.source.visualBounds(relativeTo: effect.source)
        effect.radius = max(0.12, max(bounds.extents.x, bounds.extents.z) * 0.42)
        effect.bottom = bounds.min.y
        effect.height = max(0.2, bounds.extents.y)
        effect.surfaces = []
        @MainActor func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                let centre = entity.visualBounds(relativeTo: effect.source).center.y
                let height = min(1, max(0, (centre - effect.bottom) / effect.height))
                effect.surfaces.append(.init(entity: entity, materials: model.materials, height: height))
            }
            for child in entity.children { visit(child) }
        }
        visit(effect.source)
    }

    private func update(_ effect: Effect) {
        let t = Float(effect.age / effect.duration)
        let shimmerStart: Float = effect.pending.reduced ? 0 : (effect.pending.target.water ? 0.30 : 0.10)
        let shimmer = min(1, max(0, (t - shimmerStart) / (1 - shimmerStart)))
        let fade: Float = effect.pending.reduced && effect.pending.target.advancesStage ?
            (effect.replaced ? min(1, Float((effect.age - effect.peak) / (effect.duration - effect.peak))) :
                max(0, 1 - Float(effect.age / effect.peak))) : 1
        for surface in effect.surfaces {
            // Imported submeshes brighten from roots to crown. The travelling dew
            // flecks retain that direction even for a single-mesh plant.
            let wave = effect.pending.reduced ? sin(t * .pi) :
                max(0, 1 - abs(surface.height - shimmer) / 0.55) * sin(shimmer * .pi)
            guard var component = surface.entity.components[ModelComponent.self] else { continue }
            component.materials = surface.materials.map { tint($0, amount: CGFloat(max(0, wave) * 0.44), opacity: fade) }
            surface.entity.components.set(component)
        }
        for (index, particle) in effect.particles.enumerated() {
            let angle = Float(index) * 2.39996
            let spread = effect.radius * (0.45 + Float(index % 3) * 0.22)
            if effect.pending.target.water && index < 6 {
                let drop = (t - Float(index) * 0.025) / 0.46
                let visible = drop > 0 && drop < 1
                particle.position = [cos(angle) * spread,
                    effect.bottom + effect.height + 0.25 - drop * (effect.height * 0.55 + 0.25), sin(angle) * spread]
                let size = max(0.018, min(0.055, effect.height * 0.035))
                particle.scale = visible ? [size * 0.55, size * 1.7, size * 0.55] : .zero
            } else {
                let phase = min(1, max(0, (t - 0.15 - Float(index % 4) * 0.025) / 0.85))
                let orbit = angle + phase * 1.2
                particle.position = [cos(orbit) * spread, effect.bottom + effect.height * phase, sin(orbit) * spread]
                let size = max(0.016, min(0.07, effect.height * 0.045)) * sin(phase * .pi)
                particle.scale = [size, size * (effect.pending.target.advancesStage ? 1.8 : 1), size * 0.3]
                particle.orientation = simd_quatf(angle: orbit, axis: [0, 0, 1])
            }
        }
    }

    private func restore(_ effect: Effect) {
        for surface in effect.surfaces {
            guard var component = surface.entity.components[ModelComponent.self] else { continue }
            component.materials = surface.materials
            surface.entity.components.set(component)
        }
        effect.surfaces = []
    }

    private func tint(_ original: any Material, amount: CGFloat, opacity: Float) -> any Material {
        // Copy the material value, retaining its texture, roughness and other
        // authored properties. Restore the exact original on completion/cancel.
        if var material = original as? PhysicallyBasedMaterial {
            material.baseColor.tint = brightened(material.baseColor.tint, amount: amount)
            if amount > 0 {
                material.emissiveColor = .init(color: UIColor(red: 0.55, green: 0.85, blue: 0.38, alpha: 1))
                material.emissiveIntensity = max(material.emissiveIntensity, Float(amount) * 0.45)
            }
            if opacity < 1 {
                if case .transparent(var alpha) = material.blending {
                    alpha.scale *= opacity; material.blending = .transparent(opacity: alpha)
                } else { material.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
            }
            return material
        }
        if var material = original as? SimpleMaterial {
            material.color.tint = brightened(material.color.tint, amount: amount).withAlphaComponent(material.color.tint.cgColor.alpha * CGFloat(opacity))
            return material
        }
        if var material = original as? UnlitMaterial {
            material.color.tint = brightened(material.color.tint, amount: amount).withAlphaComponent(material.color.tint.cgColor.alpha * CGFloat(opacity))
            return material
        }
        return original
    }

    private func brightened(_ color: UIColor, amount: CGFloat) -> UIColor {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
        return UIColor(red: red + (0.92 - red) * amount, green: green + (1 - green) * amount,
                       blue: blue + (0.78 - blue) * amount, alpha: alpha)
    }
}
