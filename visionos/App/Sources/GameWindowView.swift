import GameController
import Metal
import RealityKit
import SwiftUI

// The game in a window in the shared space (View: Window), beside other apps, moved and resized
// with visionOS's own controls. visionOS gives no head pose outside a Full Space, so the engine
// renders each eye from where a viewer's would be, with a relief of its depth (visionos_window.h).
// RealityKit draws the reliefs behind a portal in the window from the viewer's real eyes, so the
// game has depth and parallax; the HUD sits flat on the window's face.
struct GameWindowView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var updates: EventSubscription?

    var body: some View {
        GeometryReader3D { geometry in
            RealityView { content in
                let loaded: GameScreen?
                do { loaded = try await GameScreen() } catch {
                    NSLog("%@", "[SHARVR] the game window's materials failed to load: \(error)")
                    loaded = nil
                }
                guard let screen = loaded else {
                    return
                }
                content.add(screen.root)
                GameScreen.fit(screen.root, to: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
                // RealityKit's updates pace the engine: a frame per update, while the window shows.
                updates = content.subscribe(to: SceneEvents.Update.self) { _ in screen.update() }
            } update: { content in
                // Resizing the window.
                if let root = content.entities.first {
                    GameScreen.fit(root, to: content.convert(geometry.frame(in: .local), from: .local, to: .scene))
                }
            }
            // The window's face takes pinches and taps (the portal's collision box): without a
            // target they went through it to whatever was behind, another app's window or a
            // widget. Nothing is done with them; looking at the window is what gives it the
            // controller (below).
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in })
        }
        // visionOS turns a game controller's buttons into pinches on whatever the player looks at,
        // unless that view says it reads the controller itself: with another window open the game
        // got nothing. Looking at the game window now gives it the controller.
        .handlesGameControllerEvents(matching: .gamepad)
        // Next to no depth (3 mm), so the face is where the window's bar and corner handles are:
        // taking all the depth the window offers (as deep as it is tall), the face sat at the back
        // of it, and on the headset it didn't line up with them. The game needs none of it: it is
        // behind the portal, and what comes nearer than the face still shows.
        .frame(depth: 4)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(minWidth: 640, idealWidth: 1280, maxWidth: 4096, minHeight: 360, idealHeight: 720, maxHeight: 2304)
        .onAppear {
            GameScenes.capture(openImmersiveSpace: openImmersiveSpace, dismissImmersiveSpace: dismissImmersiveSpace,
                               openWindow: openWindow, dismissWindow: dismissWindow)
            SharVisionOS_SetWindowActive(true)
            GameView.shared.windowShowing = true
            if !SharVisionOS_IsEngineRunning() {
                SharVisionOS_Launch(nil, GameData.directory.path)
            }
        }
        .onDisappear {
            SharVisionOS_SetWindowActive(false)
            GameView.shared.windowShowing = false
            GameScenes.windowClosed()
        }
        .onChange(of: scenePhase) { _, phase in
            // In the background: the game holds, as it does with the headset off in the immersive
            // space, rather than rendering on where visionOS may refuse the GPU work. Only there:
            // whether visionOS also reports .inactive during play (a glance at Control Center or a
            // notification) is unchecked on the headset, and holding then would pause the game.
            SharVisionOS_SetWindowVisible(phase != .background)
            NSLog("%@", "[SHARVR] window phase: \(phase)")
        }
        .task {
            // Headless Simulator runs: SHAR_TEST_LAUNCHER_BESIDE=1 opens the launcher beside the
            // window once it shows, as a look at the controls would.
            if TestHooks.value("SHAR_TEST_LAUNCHER_BESIDE") == "1" {
                // (Not if the game has moved on meanwhile: a dismissed window's task isn't always
                // cancelled at once.)
                guard (try? await Task.sleep(for: .seconds(3))) != nil, GameScenes.presentedMode == 2 else { return }
                NSLog("%@", "[SHARVR] test: opening the launcher beside the window")
                openWindow(id: SHARVRApp.launcherID, value: SHARVRApp.launcherID)
            }
        }
        .task {
            // Headless Simulator runs: SHAR_TEST_WINDOW_HIDE="40~10" puts the window in the
            // background 40 s after it opens, for 10 s, as leaving it would.
            let spec = (TestHooks.value("SHAR_TEST_WINDOW_HIDE") ?? "").split(separator: "~").compactMap { Double($0) }
            guard spec.count == 2 else { return }
            try? await Task.sleep(for: .seconds(spec[0]))
            SharVisionOS_SetWindowVisible(false)
            try? await Task.sleep(for: .seconds(spec[1]))
            SharVisionOS_SetWindowVisible(true)
        }
    }
}

// What the window shows, in window units: 1 wide, 16:9, its face at z = 0 with +z towards the
// viewer. A portal fills the face and looks into a world holding each eye's relief in three layers
// (primary, secondary, backstop; see visionos_window.h); the HUD is a plane just in front of it.
// Each engine frame is copied in on the main thread (RealityKit's textures and meshes belong to the
// main actor).
@MainActor
final class GameScreen {
    let root = Entity()
    private let hud: ModelEntity
    // Eye by eye: primary, secondary, backstop, the order SharVisionOS_CopyWindowFrame takes them.
    private let layers: [ModelEntity]
    private let meshes: [LowLevelMesh]
    private var reliefMaterials: [ShaderGraphMaterial]  // shown to the left eye, the right
    private var hudMaterial: ShaderGraphMaterial
    private var colour: LowLevelTexture?
    private var hudTexture: LowLevelTexture?
    private var eyeSize = SIMD2<Int>.zero, hudSize = SIMD2<Int>.zero
    private var serial: UInt64 = 0
    private let queue: MTLCommandQueue
    private var mirror: MirrorScene?

    private static let columns = Int(SHARVISIONOS_WINDOW_GRID_COLUMNS), rows = Int(SHARVISIONOS_WINDOW_GRID_ROWS)
    private static let aspect: Float = 9.0 / 16.0

    private enum Layer: Int, CaseIterable { case primary, secondary, backstop }

    init() async throws {
        var left = try await ShaderGraphMaterial(named: "/Root/ReliefFrame", from: "WindowFrame.usda", in: .main)
        // Seen from the side, a stretch across a depth step can face away; it still hides what's behind.
        left.faceCulling = .none
        var right = left
        try right.setParameter(name: "Eye", value: .float(1))
        reliefMaterials = [left, right]
        hudMaterial = try await ShaderGraphMaterial(named: "/Root/HudFrame", from: "WindowFrame.usda", in: .main)
        guard let queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue() else { throw CancellationError() }
        self.queue = queue
        var meshes: [LowLevelMesh] = []
        var layers: [ModelEntity] = []
        for eye in 0..<2 {
            for layer in Layer.allCases {
                let mesh = try Self.makeReliefMesh(eye: eye)
                // A secondary layer is the other eye's to see.
                let seenBy = layer == .secondary ? 1 - eye : eye
                meshes.append(mesh)
                layers.append(ModelEntity(mesh: try await MeshResource(from: mesh), materials: [reliefMaterials[seenBy]]))
            }
        }
        self.meshes = meshes
        self.layers = layers
        hud = ModelEntity(mesh: .generatePlane(width: 1, height: Self.aspect))

        let world = Entity()
        world.components.set(WorldComponent())
        layers.forEach { world.addChild($0) }
        // Test runs: SHAR_TEST_WINDOW_LAYERS=<letters> shows only those layers (p, s, b).
        if let shown = TestHooks.value("SHAR_TEST_WINDOW_LAYERS"), !shown.isEmpty {
            for (index, layer) in layers.enumerated() {
                layer.isEnabled = shown.contains(["p", "s", "b"][index % 3])
            }
        }
        let portal = ModelEntity(mesh: .generatePlane(width: 1, height: Self.aspect), materials: [PortalMaterial()])
        portal.components.set(PortalComponent(target: world))
        // The whole face is a target for pinches and taps (GameWindowView's gesture), so they stop here.
        portal.components.set(InputTargetComponent())
        portal.components.set(CollisionComponent(shapes: [.generateBox(width: 1, height: Self.aspect, depth: 0.004)]))
        // The scene mirror (MirrorScene) is what the window shows; the reliefs are the fallback,
        // which test runs can pick with SHAR_TEST_WINDOW_RELIEF=1.
        if (TestHooks.value("SHAR_TEST_WINDOW_RELIEF") ?? "").isEmpty {
            do {
                let mirror = try await MirrorScene()
                world.addChild(mirror.root)
                layers.forEach { $0.isEnabled = false }
                self.mirror = mirror
                SharVisionOS_SetMirrorEnabled(true)
            } catch {
                NSLog("%@", "[SHARVR] the scene mirror failed to load, so the window shows the relief: \(error)")
                SharVisionOS_SetMirrorEnabled(false)
            }
        }
        hud.position.z = 0.002
        root.addChild(world)
        root.addChild(portal)
        root.addChild(hud)
        root.isEnabled = false  // until the first frame
    }

    // Window units onto the window: its face is the back of the view's bounds (the view is all but
    // flat), scaled to its width in metres, which the engine also needs to place its eyes.
    static func fit(_ root: Entity, to bounds: BoundingBox) {
        root.position = [bounds.center.x, bounds.center.y, bounds.min.z]
        root.scale = SIMD3(repeating: bounds.extents.x)
        // Test runs: SHAR_TEST_WINDOW_TILT=<degrees> turns the window about its vertical axis, which
        // shows the view from the side without moving the Simulator's camera.
        if let tilt = TestHooks.value("SHAR_TEST_WINDOW_TILT").flatMap(Float.init) {
            root.orientation = simd_quatf(angle: tilt * .pi / 180, axis: [0, 1, 0])
        }
        SharVisionOS_SetWindowWidth(bounds.extents.x)
        if bounds.extents != loggedExtents {
            loggedExtents = bounds.extents
            NSLog("%@", String(format: "[SHARVR] window: %.3f x %.3f x %.3f m, centred at (%.3f, %.3f), from z %.3f to %.3f in the view's scene",
                         bounds.extents.x, bounds.extents.y, bounds.extents.z, bounds.center.x, bounds.center.y, bounds.min.z,
                         bounds.max.z))
        }
    }
    private static var loggedExtents = SIMD3<Float>.zero

    func update() {
        SharVisionOS_WindowTick()
        mirror?.update()
        var eyeWidth: Int32 = 0, eyeHeight: Int32 = 0, hudWidth: Int32 = 0, hudHeight: Int32 = 0
        let latest = SharVisionOS_WindowFrame(&eyeWidth, &eyeHeight, &hudWidth, &hudHeight)
        guard latest != 0, latest != serial else { return }
        serial = latest
        let eye = SIMD2(Int(eyeWidth), Int(eyeHeight)), hud = SIMD2(Int(hudWidth), Int(hudHeight))
        if eye != eyeSize || hud != hudSize {
            makeTextures(eye: eye, hud: hud)
        }
        guard let colour, let hudTexture, let commands = queue.makeCommandBuffer() else { return }
        if mirror != nil {
            // The mirror draws the world; only the HUD comes from the frame.
            SharVisionOS_CopyWindowHud(commands, hudTexture.replace(using: commands))
            commands.commit()
            root.isEnabled = true
            return
        }
        let positions = meshes.map { $0.replace(bufferIndex: 0, using: commands) }
        // The backstops keep every cell; the primaries and secondaries take the engine's cut.
        let cut = meshes.enumerated().filter { $0.offset % 3 != Layer.backstop.rawValue }
        let indices = cut.map { $0.element.replaceIndices(using: commands) }
        SharVisionOS_CopyWindowFrame(commands, colour.replace(using: commands), hudTexture.replace(using: commands),
                                     positions, indices)
        commands.commit()
        root.isEnabled = true
    }

    // The engine's frames change size with Render Scale.
    private func makeTextures(eye: SIMD2<Int>, hud size: SIMD2<Int>) {
        guard let colour = Self.texture(width: eye.x * 2, height: eye.y),
              let hudTexture = Self.texture(width: size.x, height: size.y, mipmapped: true),
              let colourResource = try? TextureResource(from: colour),
              let hudResource = try? TextureResource(from: hudTexture) else {
            NSLog("%@", "[SHARVR] the game window's \(eye.x)x\(eye.y) textures failed")
            return
        }
        for index in reliefMaterials.indices {
            try? reliefMaterials[index].setParameter(name: "Frame", value: .textureResource(colourResource))
        }
        for (index, layer) in layers.enumerated() {
            let eye = index / 3, seenBy = index % 3 == Layer.secondary.rawValue ? 1 - eye : eye
            layer.model?.materials = [reliefMaterials[seenBy]]
        }
        try? hudMaterial.setParameter(name: "Frame", value: .textureResource(hudResource))
        hud.model?.materials = [hudMaterial]
        self.colour = colour
        self.hudTexture = hudTexture
        eyeSize = eye
        hudSize = size
    }

    // The HUD is mipmapped (the engine regenerates its levels with each copy): seen smaller than it's
    // drawn, a single level sparkled.
    private static func texture(width: Int, height: Int, mipmapped: Bool = false) -> LowLevelTexture? {
        let levels = mipmapped ? Int(log2(Double(max(width, height)))) + 1 : 1
        let descriptor = LowLevelTexture.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                    mipmapLevelCount: levels, textureUsage: [.shaderRead, .renderTarget])
        return try? LowLevelTexture(descriptor: descriptor)
    }

    // An eye's grid, skirt and all (see SharVisionOS_CopyWindowFrame): positions and the cut from the
    // engine every frame, UVs into that eye's half of the pictures fixed here, the skirt's at the
    // picture's edge. It starts with every cell, which the backstop keeps.
    private static func makeReliefMesh(eye: Int) throws -> LowLevelMesh {
        let across = columns + 3, down = rows + 3
        let vertexCount = across * down, indexCount = (across - 1) * (down - 1) * 6
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: vertexCount,
            vertexAttributes: [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                               .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 12), .init(bufferIndex: 1, bufferStride: 8)],
            indexCapacity: indexCount, indexType: .uint32)
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uvs = raw.bindMemory(to: SIMD2<Float>.self)
            for row in 0..<down {
                let v = Float(min(max(row - 1, 0), rows)) / Float(rows)
                for column in 0..<across {
                    let u = Float(min(max(column - 1, 0), columns)) / Float(columns)
                    uvs[row * across + column] = [(u + Float(eye)) * 0.5, 1 - v]
                }
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            var next = 0
            for row in 0..<(down - 1) {
                for column in 0..<(across - 1) {
                    // Two counter-clockwise triangles, facing the viewer.
                    let topLeft = UInt32(row * across + column), bottomLeft = topLeft + UInt32(across)
                    for index in [topLeft, bottomLeft, topLeft + 1, topLeft + 1, bottomLeft, bottomLeft + 1] {
                        indices[next] = index
                        next += 1
                    }
                }
            }
        }
        // As far as a layer reaches: the engine's farthest distance pushed back, the overscan and the
        // skirt, in window units.
        let bounds = BoundingBox(min: [-110, -80, -80], max: [110, 80, 1])
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indexCount, topology: .triangle, bounds: bounds)])
        return mesh
    }
}
