@preconcurrency import Metal
import QuartzCore
import RealityKit

// The window's scene mirror (the engine side is visionos_mirror.h): the game's own meshes and
// textures, placed each frame as the engine draws them, for RealityKit to render from the viewer's
// real eyes, so the window shows the level from any angle rather than a picture of it from one.
// Sits in the portal's world, in window units.
//
// Static meshes are made once and kept, an entity per draw. This frame's dynamic geometry
// (characters, particles) is two meshes, solid and blended, with a part per material, refilled each
// frame: refilling a RealityKit mesh costs about a tenth of a millisecond however small it is.
@MainActor
final class MirrorScene {
    let root = Entity()
    // WindowFrame.usda's materials, unlit and lit: [opaque, cutout, blend].
    private let unlit: [ShaderGraphMaterial], lit: [ShaderGraphMaterial]
    private let queue: MTLCommandQueue
    private var meshes: [UInt64: MeshResource] = [:]
    private var textures: [UInt64: TextureResource] = [:]
    private var white: TextureResource?
    // New meshes and textures, copied out of the engine's frame (its pointers last only until the
    // next acquire) and made a few at a time: a level's hundreds at once is a burst of GPU uploads
    // a headset may not take in one frame. A draw waits for its mesh and texture.
    private struct PendingTexture { let id: UInt64; let pixels: Data; let width: Int; let height: Int; let mipmapped: Bool; let cutout: Bool }
    private struct PendingMesh { let id: UInt64; let vertices: Data; let indices: Data; let bounds: BoundingBox; var tries = 3 }
    private var pendingTextures: [PendingTexture] = []
    private var pendingMeshes: [PendingMesh] = []
    private var failedTextures: Set<UInt64> = []
    // Textures a draw is waiting for, made before the rest of the queue (a crash queues a burst of
    // new ones: damage, debris) so what's on screen isn't kept waiting behind them.
    private var wantedTextures: Set<UInt64> = []
    // Likewise meshes: all four of a car's wheels are one mesh, so a car waiting for it behind a
    // burst of others (a reopened window, a zone streaming in) drove on without wheels.
    private var wantedMeshes: Set<UInt64> = []
    // This 5 s: draws not shown because their mesh, or their new entity's material, wasn't made yet.
    private var skipped = (mesh: 0, material: 0)
    private var texturesArrived = false
    private var resourceCounts = (textures: 0, texturesFailed: 0, meshes: 0, meshesFailed: 0)
    // What every material reads of the frame (WindowFrame.usda): the engine's exposure, and its
    // lights for lit draws.
    private let constants: (texture: LowLevelTexture, resource: TextureResource)
    private var constantsValue: [Float16] = []
    private var materials: [MaterialKey: ShaderGraphMaterial] = [:]
    // Each mesh's entities, one per draw of it, matched to this frame's draws by where they were.
    private var pools: [UInt64: [Placed]] = [:]
    private var entityCount: Int { pools.values.reduce(0) { $0 + $1.count } }
    private var serial: UInt64 = 0
    private var frame = 0

    // The dynamic geometry, as two meshes with an entity each: the solid parts (characters), drawn
    // with the level's opaque geometry, and the blended ones (particles, glows, a fading
    // character), drawn after every blended static draw. RealityKit draws an entity in a sort group
    // in the group's order even when it is opaque: in one entity at the group's end, characters
    // came after every blended draw, so a translucent static that writes no depth didn't cover the
    // people behind it, and one that does (glass, a picket fence's rails) hid them, showing what
    // was behind.
    @MainActor private final class DynamicLayer {
        let entity = ModelEntity()
        var mesh: (mesh: LowLevelMesh, resource: MeshResource)?
    }
    private let solidDynamic = DynamicLayer(), blendedDynamic = DynamicLayer()
    // The materials both meshes' parts index.
    private var dynamicMaterials: [MaterialKey] = []
    private var dynamicMaterialList: [ShaderGraphMaterial] = []
    private var dynamicReady: [Bool] = []
    private var dynamicReassigned = 0

    private var timing = (calls: 0, frames: 0, seconds: 0.0, since: CACurrentMediaTime())
    private var stages = (acquire: 0.0, resources: 0.0, placing: 0.0, dynamic: 0.0)

    private struct MaterialKey: Hashable {
        var texture: UInt64
        var colour: SIMD4<UInt8>
        var ambient: SIMD3<UInt8>
        var cutoff: UInt8
        var flags: UInt32
        var blend: UInt32

        init(texture: UInt64, colour: simd_float4, ambient: simd_float4, cutoff: Float, flags: UInt32, blend: UInt32) {
            self.texture = texture
            // A fading car's alpha (and its trim's alpha test with it) changes every frame: in 32
            // steps, a fade is a few dozen materials, not one a frame for each of its parts.
            var colour = simd_clamp(colour, .zero, .one)
            colour.w = (colour.w * 31).rounded() / 31
            self.colour = SIMD4<UInt8>(clamping: SIMD4<Int>((colour * 255).rounded(.toNearestOrEven)))
            let ambient3 = SIMD3(ambient.x, ambient.y, ambient.z)
            self.ambient = SIMD3<UInt8>(clamping: SIMD3<Int>((simd_clamp(ambient3, .zero, .one) * 255).rounded(.toNearestOrEven)))
            // Quantized only while fading: a steady car's trim test stays at the engine's 250/255.
            let fading = colour.w < 30.5 / 31
            let steps: Float = fading ? 31 : 255
            self.cutoff = cutoff > 0 ? UInt8(clamping: max(1, Int(((cutoff * steps).rounded() / steps * 255).rounded()))) : 0
            self.flags = flags & (SHARVISIONOS_MIRROR_TWO_SIDED | SHARVISIONOS_MIRROR_LIT | SHARVISIONOS_MIRROR_DEPTH_WRITE)
            self.blend = blend
        }
    }

    // Blended entities draw in the engine's order (its draws come far to near), not by RealityKit's
    // distance from the eye to each entity's centre, which changes with every movement of the head:
    // a car's glass, its roof and the glows in front of them took turns.
    private static let blendOrder = ModelSortGroup()

    private final class Placed {
        let entity: ModelEntity
        var material: MaterialKey
        var lastFrame: Int
        var position: SIMD3<Float>
        var order: Int32 = -1
        init(entity: ModelEntity, material: MaterialKey, lastFrame: Int, position: SIMD3<Float>) {
            self.entity = entity
            self.material = material
            self.lastFrame = lastFrame
            self.position = position
        }
    }

    init() async throws {
        guard let queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue(),
              let texture = try? LowLevelTexture(descriptor: LowLevelTexture.Descriptor(
                  pixelFormat: .rgba16Float, width: 8, height: 1, mipmapLevelCount: 1, textureUsage: [.shaderRead])),
              let resource = try? await TextureResource(from: texture) else { throw CancellationError() }
        self.queue = queue
        constants = (texture, resource)
        var loaded: [ShaderGraphMaterial] = []
        for name in ["MirrorOpaque", "MirrorCutout", "MirrorBlend", "MirrorOpaqueLit", "MirrorCutoutLit", "MirrorBlendLit"] {
            var material = try await ShaderGraphMaterial(named: "/Root/\(name)", from: "WindowFrame.usda", in: .main)
            try material.setParameter(name: "Constants", value: .textureResource(resource))
            loaded.append(material)
        }
        (unlit, lit) = (Array(loaded[0..<3]), Array(loaded[3..<6]))
        setConstants(SharVisionOSMirrorFrame())
        white = makeTexture(pixels: [UInt8](repeating: 255, count: 4), width: 1, height: 1)
        // The blended parts (glows, particles, headlight cones) after every blended static draw, as
        // the engine draws its billboards after its translucent pass; among themselves far to near.
        blendedDynamic.entity.components.set(ModelSortGroupComponent(group: Self.blendOrder, order: Int32.max))
        for layer in [solidDynamic, blendedDynamic] {
            layer.entity.isEnabled = false
            root.addChild(layer.entity)
        }
    }

    func update() {
        let start = CACurrentMediaTime()
        defer {
            // Every 5 s: how often RealityKit updates, how many engine frames came, and what they cost here.
            timing.calls += 1
            timing.seconds += CACurrentMediaTime() - start
            if start - timing.since > 5 {
                let calls = Double(timing.calls)
                print(String(format: "[SHARVR] mirror: %.0f updates/s, %.0f frames/s, %.2f ms an update (acquire %.2f, "
                             + "new meshes and textures %.2f, placing %.2f, dynamic %.2f), %d entities, %d materials, dynamic "
                             + "materials set %d times; textures %d made, "
                             + "%d failed, %d waiting; meshes %d made, %d failed, %d waiting; draws waiting for a mesh %d, "
                             + "for a material %d",
                             calls / (start - timing.since), Double(timing.frames) / (start - timing.since),
                             timing.seconds / calls * 1000, stages.acquire / calls * 1000, stages.resources / calls * 1000,
                             stages.placing / calls * 1000, stages.dynamic / calls * 1000, entityCount, materials.count,
                             dynamicReassigned,
                             resourceCounts.textures, resourceCounts.texturesFailed, pendingTextures.count,
                             resourceCounts.meshes, resourceCounts.meshesFailed, pendingMeshes.count, skipped.mesh, skipped.material))
                skipped = (0, 0)
                timing = (0, 0, 0, start)
                dynamicReassigned = 0
                stages = (0, 0, 0, 0)
            }
        }
        var next = SharVisionOSMirrorFrame()
        guard SharVisionOS_MirrorAcquire(&next) else { return }
        let acquired = CACurrentMediaTime()
        stages.acquire += acquired - start
        for index in 0..<Int(next.textureCount) {
            let texture = next.textures![index]
            let width = Int(texture.width), height = Int(texture.height), row = width * 4
            // The engine's rows go bottom to top against the UVs it gives them (Pure3D's GL
            // heritage): reversed here, so the upload is one copy.
            var pixels = Data(count: row * height)
            pixels.withUnsafeMutableBytes { destination in
                for y in 0..<height {
                    (destination.baseAddress! + y * row).copyMemory(from: texture.pixels + (height - 1 - y) * row, byteCount: row)
                }
            }
            pendingTextures.append(PendingTexture(id: texture.id, pixels: pixels, width: width, height: height,
                                                  mipmapped: texture.mipmapped, cutout: texture.cutout))
        }
        for index in 0..<Int(next.meshCount) {
            let mesh = next.meshes![index]
            pendingMeshes.append(PendingMesh(id: mesh.id,
                                             vertices: Data(bytes: mesh.vertices, count: Int(mesh.vertexCount) * 36),
                                             indices: Data(bytes: mesh.indices, count: Int(mesh.indexCount) * 2),
                                             bounds: BoundingBox(min: mesh.boundsMin, max: mesh.boundsMax)))
        }
        // After the new ones: a mesh or texture can arrive and be gone in the same frame.
        for index in 0..<Int(next.removedCount) {
            let id = next.removed![index]
            meshes[id] = nil
            textures[id] = nil
            failedTextures.remove(id)
            pendingTextures.removeAll { $0.id == id }
            pendingMeshes.removeAll { $0.id == id }
            pools[id]?.forEach { $0.entity.removeFromParent() }
            pools[id] = nil
            materials = materials.filter { $0.key.texture != id }
        }
        // A few milliseconds of them an update, and at least one of each.
        if !wantedTextures.isEmpty {
            let wanted = pendingTextures.filter { wantedTextures.contains($0.id) }
            pendingTextures = wanted + pendingTextures.filter { !wantedTextures.contains($0.id) }
            wantedTextures.removeAll()
        }
        var made = 0
        while !pendingTextures.isEmpty && (made == 0 || CACurrentMediaTime() - acquired < 0.003) {
            let texture = pendingTextures.removeFirst()
            if let resource = makeTexture(texture) {
                textures[texture.id] = resource
                resourceCounts.textures += 1
            } else {
                failedTextures.insert(texture.id)
                resourceCounts.texturesFailed += 1
            }
            texturesArrived = true
            made += 1
        }
        if !wantedMeshes.isEmpty {
            let wanted = pendingMeshes.filter { wantedMeshes.contains($0.id) }
            pendingMeshes = wanted + pendingMeshes.filter { !wantedMeshes.contains($0.id) }
            wantedMeshes.removeAll()
        }
        made = 0
        var failed: [PendingMesh] = []
        while !pendingMeshes.isEmpty && (made == 0 || CACurrentMediaTime() - acquired < 0.005) {
            var mesh = pendingMeshes.removeFirst()
            if let resource = makeMesh(mesh) {
                meshes[mesh.id] = resource
                resourceCounts.meshes += 1
            } else {
                // Tried again in a later update, a few times, rather than its draws never showing.
                resourceCounts.meshesFailed += 1
                mesh.tries -= 1
                if mesh.tries > 0 { failed.append(mesh) }
            }
            made += 1
        }
        pendingMeshes += failed
        let resourced = CACurrentMediaTime()
        stages.resources += resourced - acquired
        guard next.serial != serial else { return }
        serial = next.serial
        setConstants(next)
        frame += 1
        timing.frames += 1

        // A mesh drawn many times (a tree, a fence post, a car's wheel) is drawn in an order that
        // changes from frame to frame, so its n-th draw is a different instance each time. Matched
        // by order, entities jumped between instances every frame: each frame right on its own, but
        // the headset's renderer, which runs on its own clock and smooths motion, showed the same
        // trees and car parts flickering. So each draw takes the nearest of its mesh's entities as
        // they were last frame, one with its material first.
        var drawsByMesh: [UInt64: [Int]] = [:]
        for index in 0..<Int(next.drawCount) {
            let meshID = next.draws![index].mesh
            if meshes[meshID] == nil {
                wantedMeshes.insert(meshID)
                skipped.mesh += 1
                continue
            }
            drawsByMesh[meshID, default: []].append(index)
        }
        for (meshID, indices) in drawsByMesh {
            guard let mesh = meshes[meshID] else { continue }
            var pool = pools[meshID] ?? []
            var taken = [Bool](repeating: false, count: pool.count)
            for index in indices {
                let draw = next.draws![index]
                let position = SIMD3(draw.transform.columns.3.x, draw.transform.columns.3.y, draw.transform.columns.3.z)
                let materialKey = MaterialKey(texture: draw.texture, colour: draw.colour, ambient: draw.ambient,
                                              cutoff: draw.alphaCutoff, flags: draw.flags, blend: draw.blend)
                var best = -1
                var bestCost = Float.infinity
                for (slot, candidate) in pool.enumerated() where !taken[slot] {
                    // One with this draw's material first, but only among those within a game metre
                    // (0.17 window units): preferred from anywhere, two cars sharing a wheel mesh
                    // swapped wheels whenever their materials did.
                    let cost = simd_distance_squared(candidate.position, position) + (candidate.material == materialKey ? 0 : 0.03)
                    if cost < bestCost { bestCost = cost; best = slot }
                }
                let placed: Placed
                if best >= 0 {
                    taken[best] = true
                    placed = pool[best]
                    if placed.material != materialKey {
                        // A material the mirror can't make yet (a texture still on its way) leaves
                        // the last one until it can: hiding the entity meanwhile blinked it out.
                        if let material = material(for: materialKey) {
                            placed.entity.model?.materials = [material]
                            placed.material = materialKey
                        } else if Self.drawable(materialKey) {
                            wantedTextures.insert(materialKey.texture)
                        } else {
                            placed.entity.isEnabled = false
                            continue
                        }
                    }
                } else {
                    guard let material = material(for: materialKey) else {
                        wantedTextures.insert(materialKey.texture)
                        skipped.material += 1
                        continue
                    }
                    placed = Placed(entity: ModelEntity(mesh: mesh, materials: [material]), material: materialKey,
                                    lastFrame: frame, position: position)
                    root.addChild(placed.entity)
                    pool.append(placed)
                    taken.append(true)
                }
                placed.entity.transform = Transform(matrix: draw.transform)
                let order: Int32 = Self.blended(placed.material) ? Int32(index) : -1
                if order != placed.order {
                    if order >= 0 {
                        placed.entity.components.set(ModelSortGroupComponent(group: Self.blendOrder, order: order))
                    } else {
                        placed.entity.components.remove(ModelSortGroupComponent.self)
                    }
                    placed.order = order
                }
                placed.entity.isEnabled = true
                placed.lastFrame = frame
                placed.position = position
            }
            pools[meshID] = pool
        }
        // Not drawn this frame: hidden, and let go after a few seconds.
        for (meshID, pool) in pools {
            var kept: [Placed] = []
            for placed in pool {
                if placed.lastFrame != frame { placed.entity.isEnabled = false }
                if frame - placed.lastFrame > 300 { placed.entity.removeFromParent() } else { kept.append(placed) }
            }
            pools[meshID] = kept.isEmpty ? nil : kept
        }
        let placed = CACurrentMediaTime()
        stages.placing += placed - resourced
        updateDynamic(next)
        stages.dynamic += CACurrentMediaTime() - placed
    }

    // This frame's dynamic meshes: two GPU copies into each, and their parts.
    private func updateDynamic(_ frame: SharVisionOSMirrorFrame) {
        guard frame.dynamicIndexCount > 0, frame.dynamicPartCount > 0, let vertices = frame.dynamicVertices,
              let indices = frame.dynamicIndices, let parts = frame.dynamicParts else {
            solidDynamic.entity.isEnabled = false
            blendedDynamic.entity.isEnabled = false
            return
        }
        // A material index per part, the list growing as new materials appear (and starting over
        // if it gets long).
        let partCount = Int(frame.dynamicPartCount)
        let keys = (0..<partCount).map { index in
            let part = parts[index]
            return MaterialKey(texture: part.texture, colour: part.colour, ambient: part.ambient, cutoff: part.alphaCutoff,
                               flags: part.flags, blend: part.blend)
        }
        // (Counting new materials, not parts: blended parts in the game's order repeat theirs.)
        let fresh = Set(keys).filter { !dynamicMaterials.contains($0) }
        if dynamicMaterials.count + fresh.count > 256 { dynamicMaterials = [] }
        // Textures that arrived since may let parts that were waiting take their own materials;
        // the list is set again only then (or for a new material), as setting it may cost the
        // headset's renderer a frame of every character.
        var changed = false
        if texturesArrived {
            texturesArrived = false
            changed = dynamicMaterials.indices.contains { !dynamicReady[$0] && material(for: dynamicMaterials[$0]) != nil }
        }
        for key in keys where !dynamicMaterials.contains(key) {
            dynamicMaterials.append(key)
            changed = true
        }
        if changed {
            dynamicReassigned += 1
            dynamicReady = dynamicMaterials.map { material(for: $0) != nil }
            dynamicMaterialList = dynamicMaterials.map { key in
                // Particles and sprites face whichever way they were built; draw both sides.
                var material = material(for: key) ?? unlit[0]
                material.faceCulling = .none
                return material
            }
            for layer in [solidDynamic, blendedDynamic] { layer.entity.model?.materials = dynamicMaterialList }
        }
        let solidVertices = Int(frame.dynamicSolidVertexCount), solidIndices = Int(frame.dynamicSolidIndexCount)
        let solidParts = Int(frame.dynamicSolidPartCount)
        fill(solidDynamic, vertices: UnsafeRawPointer(vertices), vertexCount: solidVertices, indices: indices,
             indexCount: solidIndices, parts: parts, range: 0..<solidParts, firstIndex: 0, keys: keys,
             bounds: BoundingBox(min: frame.dynamicBoundsMin.0, max: frame.dynamicBoundsMax.0))
        fill(blendedDynamic, vertices: UnsafeRawPointer(vertices) + solidVertices * 36,
             vertexCount: Int(frame.dynamicVertexCount) - solidVertices, indices: indices + solidIndices,
             indexCount: Int(frame.dynamicIndexCount) - solidIndices, parts: parts, range: solidParts..<partCount,
             firstIndex: solidIndices, keys: keys, bounds: BoundingBox(min: frame.dynamicBoundsMin.1, max: frame.dynamicBoundsMax.1))
    }

    // One of the dynamic meshes: its vertices and indices into fresh buffers, then its parts (`range`
    // of the frame's, whose first index is `firstIndex` in the frame's index list).
    private func fill(_ layer: DynamicLayer, vertices: UnsafeRawPointer, vertexCount: Int, indices: UnsafePointer<UInt32>,
                      indexCount: Int, parts: UnsafePointer<SharVisionOSMirrorPart>, range: Range<Int>, firstIndex: Int,
                      keys: [MaterialKey], bounds: BoundingBox) {
        guard !range.isEmpty, vertexCount > 0, indexCount > 0 else {
            layer.entity.isEnabled = false
            return
        }
        let fits = layer.mesh.map { $0.mesh.vertexCapacity >= vertexCount && $0.mesh.indexCapacity >= indexCount } ?? false
        if !fits {
            guard let mesh = try? LowLevelMesh(descriptor: Self.dynamicDescriptor(
                      vertices: max(4096, vertexCount.nextPowerOfTwo), indices: max(8192, indexCount.nextPowerOfTwo))),
                  let resource = try? MeshResource(from: mesh) else { return }
            layer.mesh = (mesh, resource)
            if layer.entity.model == nil {
                layer.entity.model = ModelComponent(mesh: resource, materials: dynamicMaterialList)
            } else {
                layer.entity.model?.mesh = resource
            }
        }
        guard let (mesh, _) = layer.mesh else { return }
        // Into fresh buffers, which RealityKit swaps in once written. Written in place (the
        // `with` variants), the headset's renderer, on its own clock, could draw a frame between
        // the vertices and the indices or parts: characters flashed. In place also waited for the
        // GPU to finish with the buffer, most of the mirror's time an update.
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: vertices, count: vertexCount * 36))
        }
        mesh.replaceUnsafeMutableIndices { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: indices, count: indexCount * 4))
        }
        // A part whose material isn't made yet (its texture on its way) isn't drawn: drawn with a
        // stand-in, a character flashed white, untextured, as it came into view.
        mesh.parts.replaceAll(range.compactMap { index in
            let part = parts[index]
            guard let materialIndex = dynamicMaterials.firstIndex(of: keys[index]), dynamicReady[materialIndex] else {
                wantedTextures.insert(keys[index].texture)
                return nil
            }
            return LowLevelMesh.Part(indexOffset: (Int(part.firstIndex) - firstIndex) * 4, indexCount: Int(part.indexCount),
                                     topology: .triangle, materialIndex: materialIndex, bounds: bounds)
        })
        layer.entity.isEnabled = true
    }

    // Pure3D's blend modes through MirrorBlend's premultiplied weights (see WindowFrame.usda):
    // colour base, colour x alpha, opacity base, opacity x alpha, opacity x luma, tone curve.
    // Subtraction (dst - src: the darkening glows under crates and vending machines, a phone box's
    // smoke) darkens by the source's brightness instead, exact over white; the rest of the
    // subtracting and destination-alpha blends have no equivalent and aren't drawn.
    private static func blendWeights(_ mode: UInt32) -> [Float]? {
        switch mode {
        case SHARVISIONOS_MIRROR_BLEND_ALPHA: [0, 1, 0, 1, 0, 1]
        case SHARVISIONOS_MIRROR_BLEND_ADD: [1, 0, 0, 0, 0, 0]
        case SHARVISIONOS_MIRROR_BLEND_SUBTRACT: [0, 0, 0, 0, 1, 0]
        case SHARVISIONOS_MIRROR_BLEND_ADDMODULATEALPHA: [1, 0, 1, -1, 0, 0]
        case SHARVISIONOS_MIRROR_BLEND_MODULATE: [0, 0, 1, 0, -1, 0]
        case SHARVISIONOS_MIRROR_BLEND_MODULATE2: [0, 0, 1, 0, -2, 0]
        default: nil
        }
    }

    // Whether the key makes a blended material (MirrorBlend), not an opaque or cut-out one.
    private static func blended(_ key: MaterialKey) -> Bool {
        !(key.blend == SHARVISIONOS_MIRROR_BLEND_NONE || (key.cutoff > 0 && key.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA))
    }

    // Whether the mirror has a material for this blend at all.
    private static func drawable(_ key: MaterialKey) -> Bool {
        key.blend == SHARVISIONOS_MIRROR_BLEND_NONE || (key.cutoff > 0 && key.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA)
            || blendWeights(key.blend) != nil
    }

    private func material(for key: MaterialKey) -> ShaderGraphMaterial? {
        if let material = materials[key] { return material }
        // Not made yet: the draw waits. One that failed shows white rather than nothing.
        let made = key.texture == 0 || failedTextures.contains(key.texture) ? white : textures[key.texture]
        guard let texture = made else { return nil }
        var material: ShaderGraphMaterial
        let bases = key.flags & SHARVISIONOS_MIRROR_LIT != 0 ? lit : unlit
        if key.blend == SHARVISIONOS_MIRROR_BLEND_NONE || (key.cutoff > 0 && key.blend == SHARVISIONOS_MIRROR_BLEND_ALPHA) {
            // Alpha-tested blending (foliage, fences) keeps its cutout and its depth.
            material = key.cutoff > 0 ? bases[1] : bases[0]
            if key.cutoff > 0 { try? material.setParameter(name: "Cutoff", value: .float(Float(key.cutoff) / 255)) }
        } else {
            guard let weights = Self.blendWeights(key.blend) else { return nil }
            material = bases[2]
            for (name, weight) in zip(["ColourBase", "ColourAlpha", "OpacityBase", "OpacityAlpha", "OpacityLuma", "Curve"], weights) {
                try? material.setParameter(name: name, value: .float(weight))
            }
            // Blended surfaces hide what's behind them only where the game's do: drawn in the
            // game's order, they do what its depth writes do. RealityKit's default (always), in its
            // own order, let an invisible wheel-blur disc cut out the tyre behind it.
            material.writesDepth = key.flags & SHARVISIONOS_MIRROR_DEPTH_WRITE != 0
        }
        try? material.setParameter(name: "Frame", value: .textureResource(texture))
        try? material.setParameter(name: "Colour", value: .simd4Float(SIMD4<Float>(key.colour) / 255))
        if key.flags & SHARVISIONOS_MIRROR_LIT != 0 {
            try? material.setParameter(name: "Ambient", value: .simd3Float(SIMD3<Float>(key.ambient) / 255))
        }
        material.faceCulling = key.flags & SHARVISIONOS_MIRROR_TWO_SIDED != 0 ? .none : .back
        // Entities keep theirs: this is only a cache.
        if materials.count > 2048 { materials.removeAll(keepingCapacity: true) }
        materials[key] = material
        return material
    }

    // Texel 0 is (exposure, ambient); texels 1-6 each light's direction and colour. The engine's
    // directions are in window space, which the materials' world normals see turned however the
    // window is.
    private func setConstants(_ frame: SharVisionOSMirrorFrame) {
        let turn = root.orientation(relativeTo: nil)
        let exposure = frame.exposure > 0 ? frame.exposure : 1
        var texels: [SIMD4<Float>] = [SIMD4(exposure, frame.ambient.x, frame.ambient.y, frame.ambient.z)]
        let lights = [(frame.lightDirections.0, frame.lightColours.0), (frame.lightDirections.1, frame.lightColours.1),
                      (frame.lightDirections.2, frame.lightColours.2)]
        for (direction, colour) in lights {
            texels.append(SIMD4(turn.act(direction), 0))
            texels.append(SIMD4(colour, 0))
        }
        texels.append(.zero)
        let values = texels.flatMap { [Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w)] }
        guard values != constantsValue,
              let staging = values.withUnsafeBytes({ queue.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: 64, sourceBytesPerImage: 64,
                  sourceSize: MTLSize(width: 8, height: 1, depth: 1), to: constants.texture.replace(using: commands),
                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commands.commit()
        constantsValue = values
    }

    private func makeTexture(_ texture: PendingTexture) -> TextureResource? {
        let levels = texture.mipmapped && texture.cutout ? Self.coverageMipmaps(texture) : nil
        return (levels ?? texture.pixels).withUnsafeBytes {
            makeTexture(pixels: $0.baseAddress!, width: texture.width, height: texture.height,
                        mipmapped: texture.mipmapped, levelsIncluded: levels != nil, id: texture.id)
        }
    }

    // A cut-out texture's mipmaps, every level after the first, in one buffer: each texel the mean of
    // the four below it (colour weighted by alpha, so the cut-away texels' colour doesn't darken the
    // edges), its alpha scaled so as many texels pass an alpha test at a half as at full size. A box
    // filter alone thins foliage with distance, and its edges, cut afresh every time the eye moves
    // a little, shimmered.
    private static func coverageMipmaps(_ texture: PendingTexture) -> Data? {
        var width = texture.width, height = texture.height
        guard width > 1 || height > 1 else { return nil }
        var level = [UInt8](texture.pixels)
        let covered = { (pixels: [UInt8], scale: Float) -> Int in
            stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (Float(pixels[$1]) * scale >= 127.5 ? 1 : 0) }
        }
        let coverage = Float(covered(level, 1)) / Float(width * height)
        var chain = Data(level)
        while width > 1 || height > 1 {
            let nextWidth = max(1, width / 2), nextHeight = max(1, height / 2)
            var next = [UInt8](repeating: 0, count: nextWidth * nextHeight * 4)
            for y in 0..<nextHeight {
                for x in 0..<nextWidth {
                    var colour = SIMD3<Float>.zero, plain = SIMD3<Float>.zero, alpha: Float = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let at = (min(y * 2 + dy, height - 1) * width + min(x * 2 + dx, width - 1)) * 4
                        let texel = SIMD3<Float>(Float(level[at]), Float(level[at + 1]), Float(level[at + 2]))
                        let a = Float(level[at + 3])
                        colour += texel * a
                        plain += texel
                        alpha += a
                    }
                    let rgb = alpha > 0 ? colour / alpha : plain / 4
                    let at = (y * nextWidth + x) * 4
                    next[at] = UInt8(rgb.x.rounded())
                    next[at + 1] = UInt8(rgb.y.rounded())
                    next[at + 2] = UInt8(rgb.z.rounded())
                    next[at + 3] = UInt8((alpha / 4).rounded())
                }
            }
            // The scale whose coverage is nearest the full size's.
            var low: Float = 0, high: Float = 8
            for _ in 0..<12 {
                let middle = (low + high) / 2
                if Float(covered(next, middle)) / Float(nextWidth * nextHeight) < coverage { low = middle } else { high = middle }
            }
            for at in stride(from: 3, to: next.count, by: 4) { next[at] = UInt8(min(255, (Float(next[at]) * high).rounded())) }
            chain.append(contentsOf: next)
            (level, width, height) = (next, nextWidth, nextHeight)
        }
        return chain
    }

    // `levelsIncluded`: the pixels are every level, one after another (coverageMipmaps), rather than
    // the first level for the GPU to mipmap.
    private func makeTexture(pixels: UnsafeRawPointer, width: Int, height: Int, mipmapped: Bool = false,
                             levelsIncluded: Bool = false, id: UInt64 = 0) -> TextureResource? {
        let levels = mipmapped ? Int(log2(Double(max(width, height)))) + 1 : 1
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                    mipmapLevelCount: levels, textureUsage: [.shaderRead, .renderTarget])
        let texture: LowLevelTexture
        do { texture = try LowLevelTexture(descriptor: descriptor) } catch {
            Self.report("texture \(id) (\(width)x\(height), \(levels) levels): LowLevelTexture failed: \(error)")
            return nil
        }
        let sizes = (0..<(levelsIncluded ? levels : 1)).map { (max(1, width >> $0), max(1, height >> $0)) }
        guard let staging = queue.device.makeBuffer(bytes: pixels, length: sizes.reduce(0) { $0 + $1.0 * $1.1 * 4 }),
              upload(staging, into: texture, sizes: sizes, generate: levels > 1 && !levelsIncluded, id: id, retries: 1) else {
            Self.report("texture \(id) (\(width)x\(height)): no staging buffer or command buffer")
            return nil
        }
        do { return try TextureResource(from: texture) } catch {
            Self.report("texture \(id) (\(width)x\(height)): TextureResource failed: \(error)")
            return nil
        }
    }

    // The staging buffer's levels into the texture (the GPU making the rest when it should). One the
    // GPU reports failing is tried again into the same texture, so what draws it needn't change:
    // dropping it to make again hid every character sharing it (their swatch) until it was remade.
    @discardableResult
    private func upload(_ staging: MTLBuffer, into texture: LowLevelTexture, sizes: [(Int, Int)], generate: Bool, id: UInt64,
                        retries: Int) -> Bool {
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return false }
        let destination = texture.replace(using: commands)
        var offset = 0
        for (level, (levelWidth, levelHeight)) in sizes.enumerated() {
            blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: levelWidth * 4,
                      sourceBytesPerImage: levelWidth * levelHeight * 4,
                      sourceSize: MTLSize(width: levelWidth, height: levelHeight, depth: 1), to: destination,
                      destinationSlice: 0, destinationLevel: level, destinationOrigin: MTLOrigin())
            offset += levelWidth * levelHeight * 4
        }
        if generate { blit.generateMipmaps(for: destination) }
        blit.endEncoding()
        commands.addCompletedHandler { [weak self] done in
            guard let error = done.error else { return }
            let message = "texture \(id) (\(sizes[0].0)x\(sizes[0].1)): upload failed\(retries > 0 ? ", trying again" : ""): \(error)"
            DispatchQueue.main.async {
                Self.report(message)
                if retries > 0 {
                    self?.upload(staging, into: texture, sizes: sizes, generate: generate, id: id, retries: retries - 1)
                }
            }
        }
        commands.commit()
        return true
    }

    // The first few failures of each kind, word for word; the counts are in the 5-second line.
    private static var reports = 0
    private static func report(_ message: String) {
        reports += 1
        if reports <= 20 { print("[SHARVR] mirror: \(message)") }
    }

    private func makeTexture(pixels: [UInt8], width: Int, height: Int) -> TextureResource? {
        pixels.withUnsafeBytes { makeTexture(pixels: $0.baseAddress!, width: width, height: height) }
    }

    // A static mesh's vertex (visionos_mirror.mm): position, normal, uv, colour, as the dynamic
    // mesh's, with 16-bit indices.
    private static func descriptor(vertices: Int, indices: Int) -> LowLevelMesh.Descriptor {
        LowLevelMesh.Descriptor(
            vertexCapacity: vertices,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 24),
                               .init(semantic: .color, format: .uchar4Normalized, layoutIndex: 0, offset: 32)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 36)],
            indexCapacity: indices, indexType: .uint16)
    }

    // The dynamic mesh's packed vertex (visionos_mirror.mm): position, normal, uv, colour.
    private static func dynamicDescriptor(vertices: Int, indices: Int) -> LowLevelMesh.Descriptor {
        LowLevelMesh.Descriptor(
            vertexCapacity: vertices,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 24),
                               .init(semantic: .color, format: .uchar4Normalized, layoutIndex: 0, offset: 32)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 36)],
            indexCapacity: indices, indexType: .uint32)
    }

    private func makeMesh(_ source: PendingMesh) -> MeshResource? {
        let vertexCount = source.vertices.count / 36, indexCount = source.indices.count / 2
        let mesh: LowLevelMesh
        do { mesh = try LowLevelMesh(descriptor: Self.descriptor(vertices: vertexCount, indices: indexCount)) } catch {
            Self.report("mesh \(source.id) (\(vertexCount) vertices, \(indexCount) indices): LowLevelMesh failed: \(error)")
            return nil
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            source.vertices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        mesh.withUnsafeMutableIndices { raw in
            source.indices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indexCount, topology: .triangle, bounds: source.bounds)])
        do { return try MeshResource(from: mesh) } catch {
            Self.report("mesh \(source.id) (\(vertexCount) vertices): MeshResource failed: \(error)")
            return nil
        }
    }
}

private extension Int {
    var nextPowerOfTwo: Int { self <= 1 ? 1 : 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount) }
}

