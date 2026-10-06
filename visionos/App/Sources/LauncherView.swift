import ARKit
import GameController
import SwiftUI
import UniformTypeIdentifiers

struct LauncherView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var importer = GameImporter()
    @State private var dataPresent = GameData.isPresent
    @State private var picking = false
    @State private var playError: String?
    @State private var viewMode = GameView.savedMode()
    // Full and Progressive: the present waits for the engine's frame on the GPU, not the CPU
    // (SHAR_PRESENT_EVENT, visionos_compositor.mm), so the engine starts its next frame sooner.
    // Off until the headset shows it's right.
    @AppStorage("paceFramesOnGPU") private var paceFramesOnGPU = false
    @State private var roomBehindMenus = GameView.roomBehindMenus
    // What the game can be played with: a controller (Sense or gamepad), or in Full and
    // Progressive bare hands, which need hand tracking allowed.
    @State private var controllerConnected = LauncherView.anyController
    @State private var handTrackingDenied = false

    private static let trevorbiltOrange = Color(red: 237 / 255, green: 112 / 255, blue: 20 / 255)

    var body: some View {
        VStack(spacing: 20) {
            Text("The Simpsons: Hit & Run VR")
                .font(.title)
            if case .working(let progress, let status) = importer.phase {
                ProgressView(value: progress) { Text(status) }
                    .frame(maxWidth: 420)
                Text("Keep the app open until this finishes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if dataPresent {
                // After visionOS closes the game's space (Digital Crown, PS button), the engine is
                // still running, paused, and reopening the space resumes it.
                if !SharVisionOS_IsEngineRunning() {
                    // The game's View setting (VR menu), also here, so a view that shows nothing
                    // can be left without reaching the menu inside it.
                    Picker("View", selection: $viewMode) {
                        Text("Full").tag(Int32(0))
                        Text("Progressive").tag(Int32(1))
                        Text("Window").tag(Int32(2))
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .onChange(of: viewMode) { _, mode in GameView.saveMode(mode) }
                    // Full only: menus, loading and films float in the room instead of black.
                    Toggle("Show my room around menus", isOn: $roomBehindMenus)
                        .frame(maxWidth: 360)
                        .onChange(of: roomBehindMenus) { _, on in GameView.roomBehindMenus = on }
                    Toggle("Pace frames on the GPU (experimental)", isOn: $paceFramesOnGPU)
                        .frame(maxWidth: 360)
                }
                Button(SharVisionOS_IsEngineRunning() ? "Resume" : "Play") {
                    Task { await play() }
                }
                .buttonStyle(.borderedProminent)
                if let inputNote {
                    Text(inputNote)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    if handTrackingDenied, !controllerConnected, currentView != 2 {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
                if !SharVisionOS_IsEngineRunning() {
                    Button("Re-import Game Files…") { picking = true }
                }
            } else {
                Text("Grab your PC copy of the game: the archive you AirDropped (RAR, ZIP, 7z, whatever it came in) or its unpacked folder. We'll find the game files and install them.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                Button("Import Game Files…") { picking = true }
                    .buttonStyle(.borderedProminent)
            }
            if case .failed(let message) = importer.phase {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            if let playError {
                Text(playError)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            // Who made this port; the README credits the game and the ports it builds on.
            Text("An unofficial port by Trevorbilt")
                .font(.footnote)
                .foregroundStyle(Self.trevorbiltOrange)
                .padding(.top, 8)
        }
        .padding()
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { startImport(url) }
        }
        // AirDrop or the share sheet's "Open with SHAR VR".
        .onOpenURL { url in startImport(url) }
        .onAppear {
            GameScenes.capture(openImmersiveSpace: openImmersiveSpace, dismissImmersiveSpace: dismissImmersiveSpace,
                               openWindow: openWindow, dismissWindow: dismissWindow)
        }
        // Game files copied in with the Files app while the launcher was in the background, or hand
        // tracking allowed in Settings.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if !importer.isWorking { dataPresent = GameData.isPresent }
            SharVisionOS_RetryHandTracking()
            Task { await refreshInputs() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            controllerConnected = Self.anyController
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllerConnected = Self.anyController
        }
        .task {
            await refreshInputs()
            // Headless Simulator runs: simctl launch with SIMCTL_CHILD_SHAR_IMPORT_PATH=<host path>.
            if let path = TestHooks.value("SHAR_IMPORT_PATH") {
                startImport(URL(fileURLWithPath: path))
            // Headless Simulator runs: simctl launch with SIMCTL_CHILD_SHAR_AUTO_PLAY=1.
            } else if dataPresent, TestHooks.value("SHAR_AUTO_PLAY") == "1" {
                await play()
            }
        }
    }

    // Why nothing would play, if nothing can: the Window view takes only a controller (visionOS gives
    // apps no hand tracking outside a Full Space), and bare hands need hand tracking allowed.
    private var inputNote: String? {
        guard dataPresent, !controllerConnected else { return nil }
        if currentView == 2 {
            return "The Window view plays with a controller. Connect PS VR2 Sense controllers or a gamepad to play it."
        }
        if handTrackingDenied {
            return "Hand tracking is off for SHAR VR and no controller is connected, so the game can't see your hands. Allow hand tracking in Settings, or connect a controller."
        }
        return nil
    }

    // The View the game will open in: the picker's, or once the game runs, its own setting, which
    // its VR menu can change.
    private var currentView: Int32 { SharVisionOS_IsEngineRunning() ? GameView.savedMode() : viewMode }

    // Headless Simulator runs: SHAR_TEST_NO_INPUT=1 shows the launcher as if no controller were
    // connected and hand tracking were denied (the Simulator always has a gamepad).
    private static var anyController: Bool {
        !GCController.controllers().isEmpty && TestHooks.value("SHAR_TEST_NO_INPUT") != "1"
    }

    private func refreshInputs() async {
        controllerConnected = Self.anyController
        var status: ARKitSession.AuthorizationStatus?
        if HandTrackingProvider.isSupported {
            status = await ARKitSession().queryAuthorization(for: [.handTracking])[.handTracking]
        }
        handTrackingDenied = status == .denied || TestHooks.value("SHAR_TEST_NO_INPUT") == "1"
        print("[SHARVR] hand tracking \(status.map { "\($0)" } ?? "not supported"), "
              + "controller \(controllerConnected ? "connected" : "none")")
    }

    private func startImport(_ url: URL) {
        importer.importGame(from: url) {
            dataPresent = GameData.isPresent
            // Headless Simulator runs: SHAR_AUTO_PLAY=1 also plays as soon as an import lands.
            if dataPresent, TestHooks.value("SHAR_AUTO_PLAY") == "1" {
                Task { await play() }
            }
        }
    }

    private func play() async {
        playError = nil
        // Read by the engine's first frame; an Xcode scheme's own setting also counts.
        if paceFramesOnGPU { setenv("SHAR_PRESENT_EVENT", "1", 1) }
        // View: Window plays in the shared space, beside other apps.
        let mode = GameView.savedMode()
        if mode == 2 {
            GameScenes.presentedMode = mode
            openWindow(id: SHARVRApp.gameWindowID)
            dismissWindow()
            return
        }
        let result = await openImmersiveSpace(id: SHARVRApp.immersiveSpaceID)
        print("[SHARVR] openImmersiveSpace: \(result)")
        switch result {
        case .opened:
            GameScenes.presentedMode = mode
            dismissWindow()
        case .userCancelled:
            playError = "The game's immersive space was cancelled."
        default:
            // Keep the window, so the app still has a scene, and say why.
            playError = "visionOS couldn't open the game's immersive space. The Xcode console has the details."
        }
    }
}
