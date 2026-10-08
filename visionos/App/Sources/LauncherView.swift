import GameController
import SwiftUI
import TrevorbiltKit
import UniformTypeIdentifiers

// The launcher: Play (the game files, how to play, Play), Controls, Ports (the AVP Ports Index) and
// About, in the Trevorbilt launcher shared by every Trevorbilt port (visionos/TrevorbiltKit). What
// you'll play with sits in an ornament under the window. It closes when the game opens; visionOS
// brings it back, with Resume, when the game's space or window closes.
struct LauncherView: View {
    enum Tab: String, CaseIterable {
        case play, controls, ports, about
    }

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var importer = GameImporter()
    @State private var tab = Tab(rawValue: TestHooks.value("SHAR_TEST_TAB") ?? "") ?? .play
    @State private var dataPresent = GameData.isPresent
    @State private var installed: (size: String, files: Int)?
    @State private var picking = false
    @State private var playError: String?
    @State private var viewMode = GameView.savedMode()
    // Headless Simulator runs: SHAR_TEST_SHEET=manage|advanced|credits|diagnostics|port:<index id>
    // opens that sheet (on its own tab: SHAR_TEST_TAB).
    @State private var managing = TestHooks.value("SHAR_TEST_SHEET") == "manage"
    @State private var advanced = TestHooks.value("SHAR_TEST_SHEET") == "advanced"
    // Full and Progressive: the present waits for the engine's frame on the GPU, not the CPU
    // (SHAR_PRESENT_EVENT, visionos_compositor.mm), so the engine starts its next frame sooner.
    // Off until the headset shows it's right; read on the engine's first frame, so it lives here.
    @AppStorage("paceFramesOnGPU") private var paceFramesOnGPU = false
    @State private var roomBehindMenus = GameView.roomBehindMenus
    // Headless Simulator runs: SHAR_TEST_INPUTS=hands:denied,sense:none,gamepad:none (InputMonitor).
    @State private var inputs = InputMonitor(testOverride: TestHooks.value("SHAR_TEST_INPUTS"))
    @State private var ports = PortsIndex(testFeed: TestHooks.value("SHAR_TEST_FEED").map { URL(fileURLWithPath: $0) },
                                          offline: TestHooks.value("SHAR_TEST_OFFLINE") == "1")

    var body: some View {
        TabView(selection: $tab) {
            playTab
                .tabItem { Label("Play", systemImage: "play.fill") }
                .tag(Tab.play)
            ControlsView()
                .tabItem { Label("Controls", systemImage: "gamecontroller.fill") }
                .tag(Tab.controls)
            PortsBrowser(index: ports, ownID: "shar-visionos", buildCommit: BuildInfo.current.commit,
                         buildDirty: BuildInfo.current.dirty,
                         opening: TestHooks.value("SHAR_TEST_SHEET").flatMap { $0.hasPrefix("port:") ? String($0.dropFirst(5)) : nil },
                         // No pictures once the game is loaded (it runs once per process): its memory comes first.
                         showsMedia: !engineRunning)
                .tabItem { Label("Ports", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.ports)
            AboutView(content: Self.about, diagnostics: diagnostics,
                      sheet: TestHooks.value("SHAR_TEST_SHEET").flatMap(AboutView.Sheet.init(rawValue:)))
                .tabItem { Label("About", systemImage: "info.circle.fill") }
                .tag(Tab.about)
        }
        // A glanceable glass card, the same size on every tab (the window hugs it: .contentSize).
        .frame(width: 640, height: 600)
        // visionOS turns a game controller's buttons into pinches on whatever window the player
        // looks at. While the game's window shows (the Window view), a look at the launcher, to
        // check the controls say, mustn't take the controller from it: here too the controller is
        // read only by the game. Otherwise (before it, and once it's closed, for Resume) it works
        // the launcher as usual.
        .handlesGameControllerEvents(matching: GameView.shared.windowShowing ? .gamepad : [])
        // The game's window closed with its own controls: back on Play, where Resume is.
        .onChange(of: GameView.shared.windowCloses) { tab = .play }
        // What you'll play with, centred under the window, while Play is showing.
        .ornament(visibility: tab == .play && dataPresent && !importer.isWorking ? .visible : .hidden,
                  attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
            InputStatus(monitor: inputs, handsUsed: currentView != 2, handsUnusedReason: "Not used in Window",
                        combinedSenseTitle: currentView == 2 ? "Sense (as a gamepad)" : nil, verdict: verdict)
                .padding(.top, 16)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { startImport(url) }
        }
        // AirDrop or the share sheet's "Open with SHAR VR".
        .onOpenURL { url in startImport(url) }
        .sheet(isPresented: $managing) { manageSheet }
        .sheet(isPresented: $advanced) { advancedSheet }
        .onAppear {
            NSLog("%@", "[SHARVR] launcher shows")
            GameScenes.capture(openImmersiveSpace: openImmersiveSpace, dismissImmersiveSpace: dismissImmersiveSpace,
                               openWindow: openWindow, dismissWindow: dismissWindow)
        }
        .onDisappear { NSLog("%@", "[SHARVR] launcher closes") }
        // The guide opens on what's connected, for the View the game will play.
        // (Not over a test run's page: SHAR_TEST_CONTROLS sets its own.)
        .onChange(of: tab) { _, tab in
            if tab == .controls && TestHooks.value("SHAR_TEST_CONTROLS") == nil { showGuide() }
        }
        // Game files copied in with the Files app while the launcher was in the background, hand
        // tracking allowed in Settings, or the View changed in the game's own menu.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if !importer.isWorking { dataPresent = GameData.isPresent }
            if !engineRunning { viewMode = GameView.savedMode() }
            SharVisionOS_RetryHandTracking()
            Task { await inputs.refresh() }
            refreshInstalled()
        }
        .task {
            refreshInstalled()
            await inputs.start()
            if tab == .controls && TestHooks.value("SHAR_TEST_CONTROLS") == nil { showGuide() }
        }
        .task {
            // Headless Simulator runs: SHAR_TEST_CONTROLS=hands|sense|gamepad|window[,driving] shows
            // that page of the guide.
            if let value = TestHooks.value("SHAR_TEST_CONTROLS") {
                let parts = value.split(separator: ",").map(String.init)
                let guide = ControlsGuide.shared
                guide.windowView = parts.contains("window")
                guide.input = ControlsView.Input.allCases.first { parts.contains($0.rawValue.lowercased()) } ?? (guide.windowView ? .gamepad : .hands)
                guide.context = parts.contains("driving") ? .driving : .onFoot
                tab = .controls
            }
            // Headless Simulator runs: simctl launch with SIMCTL_CHILD_SHAR_IMPORT_PATH=<host path>.
            if let path = TestHooks.value("SHAR_IMPORT_PATH") {
                startImport(URL(fileURLWithPath: path))
            // Headless Simulator runs: simctl launch with SIMCTL_CHILD_SHAR_AUTO_PLAY=1 (once: not
            // again from a launcher opened later).
            } else if dataPresent, !engineRunning, TestHooks.value("SHAR_AUTO_PLAY") == "1" {
                await play()
            }
        }
    }

    // MARK: Play

    private var playTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    TrevorbiltHeader(title: "SHAR ", boldTitle: "VR", subtitle: "The Simpsons: Hit & Run on Apple Vision Pro")
                    filesStatus
                    if dataPresent && !importer.isWorking {
                        if engineRunning { paused } else { playAs }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 6) {
                Button(engineRunning ? "Resume" : "Play") { Task { await play() } }
                    .buttonStyle(TrevorbiltPrimaryButtonStyle(width: 240))
                    .disabled(!dataPresent || importer.isWorking)
                if let reason = playDisabledReason {
                    Text(reason).font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                }
                if let playError {
                    TrevorbiltCard { StatusHeadline(.problem, title: "The game didn't open", detail: playError) }
                        .frame(maxWidth: 460)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
    }

    /// The game files at a glance: one capsule once they're in (Manage holds the rest), or the
    /// way to bring them.
    @ViewBuilder private var filesStatus: some View {
        if case .working(let progress, _) = importer.phase {
            StatusCapsule {
                ProgressRing(progress: progress)
                Text("Installing the game files\(progress.map { " · \(Int(($0 * 100).rounded()))%" } ?? "…")")
            } action: {
                Button("Details") { managing = true }
            }
        } else if dataPresent {
            VStack(spacing: 6) {
                StatusCapsule {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 18))
                        .accessibilityHidden(true)
                    Text(installed.map { "Game installed · \($0.size)" } ?? "Game installed")
                } action: {
                    Button("Manage") { managing = true }
                }
                if case .failed = importer.phase {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Trevorbilt.orangeTint)
                            .accessibilityHidden(true)
                        Text("The last import didn't work. Manage has the details.")
                    }
                    .font(.tbBody(12, weight: .medium))
                }
            }
        } else {
            TrevorbiltCard(padding: 28, alignment: .center) {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 28))
                        .accessibilityHidden(true)
                    Text("Bring your copy of the game").font(.tbHeader(18, bold: true, relativeTo: .title3))
                    Text("Your PC copy of The Simpsons: Hit & Run: the archive you AirDropped (RAR, ZIP, 7z, whatever it came in) or its unpacked folder. We'll find the game files and install them.")
                        .font(.tbBody(13))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 460)
                    Button("Import game files") { picking = true }
                        .buttonStyle(TrevorbiltPrimaryButtonStyle(width: 240))
                        .padding(.top, 4)
                    if case .failed(let message) = importer.phase {
                        StatusHeadline(.problem, title: "That didn't work", detail: message)
                            .frame(maxWidth: 460)
                    }
                }
            }
            .frame(maxWidth: 560)
        }
    }

    private var playAs: some View {
        VStack(spacing: 8) {
            TrevorbiltSectionTitle("Play as")
            // The game's View setting (VR menu), also here, so a view that shows nothing can be
            // left without reaching the menu inside it.
            HStack(spacing: 12) {
                ModeCard(.full, name: "Full", line: Self.explanation(0), selected: viewMode == 0) { viewMode = 0 }
                ModeCard(.progressive, name: "Progressive", line: Self.explanation(1), selected: viewMode == 1) { viewMode = 1 }
                ModeCard(.window, name: "Window", line: Self.explanation(2), selected: viewMode == 2) { viewMode = 2 }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: viewMode) { _, mode in GameView.saveMode(mode) }
            // What only the selected View has: the room around menus in Full, GPU pacing in Full
            // and Progressive.
            if viewMode != 2 {
                HStack(spacing: 10) {
                    if viewMode == 0 {
                        Toggle(isOn: $roomBehindMenus) {
                            Text("Show my room around menus").font(.tbBody(13, weight: .medium))
                        }
                        .tint(Trevorbilt.orange)
                        .fixedSize()
                        .padding(.leading, 16)
                        .padding(.trailing, 8)
                        .frame(minHeight: 44)
                        .background(.white.opacity(0.1), in: .capsule)
                        .onChange(of: roomBehindMenus) { _, on in GameView.roomBehindMenus = on }
                    }
                    Button("Advanced \u{203A}") { advanced = true }
                        .buttonStyle(TrevorbiltSecondaryButtonStyle())
                }
                if viewMode == 0 {
                    Text("Menus, loading screens and films float in your room instead of the dark.")
                        .font(.tbBody(12))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }

    /// While the game is paused: which View it's in, and where that's changed.
    private var paused: some View {
        VStack(spacing: 6) {
            StatusCapsule {
                Image(systemName: "pause.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18))
                    .accessibilityHidden(true)
                Text("Paused in \(Self.modeNames[Int(min(max(currentView, 0), 2))])")
            }
            Text("Resume to carry on. The game's VR menu changes the View.")
                .font(.tbBody(12))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private static let modeNames = ["Full", "Progressive", "Window"]

    private static func explanation(_ mode: Int32) -> String {
        switch mode {
        case 1: "A portal in your room. The Digital Crown widens it."
        case 2: "Beside your other apps. Plays with a controller."
        default: "All around you, in stereo."
        }
    }

    private var manageSheet: some View {
        SheetContent(done: { managing = false }) {
            TrevorbiltHeading("game ", bold: "files", size: 22)
            TrevorbiltCard {
                VStack(alignment: .leading, spacing: 10) {
                    if case .working(let progress, let status) = importer.phase {
                        StatusHeadline(.working, title: "Installing the game files", detail: "\(status) Keep the app open until this finishes.")
                        ProgressView(value: progress).tint(.white)
                    } else if dataPresent {
                        StatusHeadline(.ready, title: "The Simpsons: Hit & Run is installed",
                                       detail: installed.map { "Your PC copy: \($0.size), \($0.files.formatted()) files, in SHAR VR's folder." }
                                           ?? "Your PC copy, in SHAR VR's folder.")
                    } else {
                        StatusHeadline(.missing, title: "No game files yet", detail: "Import your PC copy from Play.")
                    }
                    if case .failed(let message) = importer.phase {
                        StatusHeadline(.problem, title: "That didn't work", detail: message)
                    }
                }
            }
            if !importer.isWorking && !engineRunning {
                Button(dataPresent ? "Re-import game files" : "Import game files") { pickingFromSheet = true }
                    .buttonStyle(TrevorbiltSecondaryButtonStyle())
            }
        }
        // A sheet can't show the launcher's own importer over itself.
        .fileImporter(isPresented: $pickingFromSheet, allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { startImport(url) }
        }
    }

    @State private var pickingFromSheet = false

    private var advancedSheet: some View {
        SheetContent(done: { advanced = false }) {
            TrevorbiltHeading("advanced ", bold: "options", size: 22)
            TrevorbiltCard {
                Toggle(isOn: $paceFramesOnGPU) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pace frames on the GPU (experimental)").font(.tbBody(14, weight: .bold))
                        Text("Can help the frame rate in Full and Progressive. If the game ever goes blank, force quit SHAR VR (hold the top button and the Digital Crown until Force Quit Applications shows), open it again and turn this off.")
                            .font(.tbBody(12)).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Trevorbilt.orange)
            }
        }
    }

    /// Which inputs the selected View plays with, and whether they're here.
    private var verdict: InputVerdict {
        // A Sense controller takes over from a gamepad, and the game needs both halves of it.
        if currentView == 2 {
            if inputs.senseLeft != nil && inputs.senseRight != nil {
                return InputVerdict("Ready to play with your Sense controllers, as a gamepad.", ready: true)
            }
            if inputs.anySense {
                return InputVerdict("Only one Sense controller is connected. Turn on the other, or turn this one off to play with a gamepad.", ready: false)
            }
            if inputs.gamepad != nil { return InputVerdict("Ready to play with your gamepad.", ready: true) }
            return InputVerdict("The Window view plays with a controller. Connect your Sense controllers or a gamepad.", ready: false)
        }
        if inputs.senseLeft != nil && inputs.senseRight != nil {
            // Without accessory tracking the game has their buttons but not where they are.
            if inputs.accessories == .denied {
                return InputVerdict("Controller tracking is off for SHAR VR, so the game can't see where your Sense controllers are. Allow it in Settings.",
                                    ready: false, settingsNeeded: true)
            }
            return InputVerdict("Ready to play with your Sense controllers.", ready: true)
        }
        if inputs.anySense {
            return InputVerdict("Only one Sense controller is connected. Turn on the other to play with both hands.", ready: false)
        }
        if inputs.gamepad != nil { return InputVerdict("Ready to play with your gamepad.", ready: true) }
        switch inputs.hands {
        case .allowed:
            return InputVerdict("Ready to play with your hands. The Controls tab shows how.", ready: true)
        case .notAsked:
            return InputVerdict("Your hands play. visionOS asks to track them when the game starts.", ready: true)
        case .denied:
            return InputVerdict("Hand tracking is off for SHAR VR and no controller is connected. Allow it in Settings, or connect a controller.",
                                ready: false, handsNeeded: true)
        case .unavailable:
            return InputVerdict("No controller is connected, and hand tracking isn't available here.", ready: false)
        }
    }

    /// The guide, on what's connected for the View the game will play.
    private func showGuide() {
        let guide = ControlsGuide.shared
        guide.windowView = currentView == 2
        guide.input = inputs.anySense ? .sense : inputs.gamepad != nil || currentView == 2 ? .gamepad : .hands
    }

    private var playDisabledReason: String? {
        if importer.isWorking { return "Play is ready as soon as the game files are in." }
        if !dataPresent { return "Import the game files first." }
        return nil
    }

    private var engineRunning: Bool { SharVisionOS_IsEngineRunning() }

    // The View the game will open in: the picker's, or once the game runs, its own setting, which
    // its VR menu can change.
    private var currentView: Int32 { engineRunning ? GameView.savedMode() : viewMode }

    private func refreshInstalled() {
        guard GameData.isPresent else { installed = nil; return }
        Task.detached(priority: .utility) {
            let summary = GameData.installedSummary()
            await MainActor.run { installed = summary }
        }
    }

    private func startImport(_ url: URL) {
        // Its progress and any problem show on Play.
        tab = .play
        // Never under a paused game (the engine runs once per process and keeps its files open).
        guard !engineRunning else {
            playError = "The game is paused. To bring in new game files, force quit SHAR VR (hold the top button and the Digital Crown until Force Quit Applications shows), open it again, and import them before you play."
            return
        }
        importer.importGame(from: url) {
            dataPresent = GameData.isPresent
            refreshInstalled()
            // Headless Simulator runs: SHAR_AUTO_PLAY=1 also plays as soon as an import lands.
            if dataPresent, TestHooks.value("SHAR_AUTO_PLAY") == "1" {
                Task { await play() }
            }
        }
    }

    private func play() async {
        playError = nil
        // The game's memory comes first: the Ports tab's pictures go now, not whenever it's next seen.
        PortsBrowser.letGoOfPictures()
        // Read by the space's first frame, so set or cleared on every Play before it (a Play whose
        // space didn't open may have set it); an Xcode scheme's own setting also counts.
        if paceFramesOnGPU {
            setenv("SHAR_PRESENT_EVENT", "1", 1)
        } else if let scheme = GameView.schemePresentEvent {
            setenv("SHAR_PRESENT_EVENT", scheme, 1)
        } else {
            unsetenv("SHAR_PRESENT_EVENT")
        }
        // View: Window plays in the shared space, beside other apps.
        let mode = GameView.savedMode()
        if mode == 2 {
            GameScenes.presentedMode = mode
            openWindow(id: SHARVRApp.gameWindowID)
            dismissWindow()
            return
        }
        let result = await openImmersiveSpace(id: SHARVRApp.immersiveSpaceID)
        NSLog("%@", "[SHARVR] openImmersiveSpace: \(result)")
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

    // MARK: About

    private var diagnostics: [(String, String)] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let names = ["Full", "Progressive", "Window"]
        func controller(_ c: InputMonitor.Controller?) -> String {
            c.map { "\($0.name)\($0.battery.map { ", \(Int(($0 * 100).rounded()))%" } ?? "")" } ?? "None"
        }
        return [("Build", BuildInfo.current.summary),
                ("visionOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
                ("Game files", installed.map { "\($0.size), \($0.files.formatted()) files" } ?? "None"),
                ("View", names[Int(min(max(currentView, 0), 2))]),
                ("Game", engineRunning ? "Running" : "Not started"),
                ("Hand tracking", ["Allowed", "Off in Settings", "Not asked yet", "Not available"][
                    [InputMonitor.Permission.allowed, .denied, .notAsked, .unavailable].firstIndex(of: inputs.hands) ?? 2]),
                ("Sense L", controller(inputs.senseLeft)),
                ("Sense R", controller(inputs.senseRight)),
                ("Gamepad", controller(inputs.gamepad))]
    }

    /// The public repository. Builds from anywhere else (this one's own development included) are
    /// development builds (the "Build commit" phase in project.yml).
    static let repository = "edgytoast/shar-visionos"

    static let about = AboutContent(
        appName: "SHAR VR",
        repository: repository,
        releaseBranch: "main",
        updateInstructions: "From the AVP Ports Index: git fetch, then git checkout the commit SHAR VR's page there lists now. From main: git pull. Then ./scripts/build.sh, and run it from Xcode. Your game files and saves stay.",
        credits: [
            .init("Trevorbilt", "The Vision Pro port: the visionOS runtime, the Window view's scene mirror, the input, the app and the build.", "https://trevorbilt.com"),
            .init("Radical Entertainment", "Made The Simpsons: Hit & Run, published in 2003 by Vivendi Universal Games and Fox Interactive.", "https://en.wikipedia.org/wiki/Radical_Entertainment"),
            .init("ZenoArrows", "Ported the game's original source code (by way of Svxy's repository) to Nintendo Switch and PS Vita.", "https://github.com/ZenoArrows/The-Simpsons-Hit-and-Run"),
            .init("Carlox33", "Took that to Android.", "https://github.com/Carlox33/The-Simpsons-Hit-and-Run-Android"),
            .init("kote2345", "Made it VR: the first-person gameplay, the body, the steering wheel, the stereo HUD and menus. This port builds directly on that work.", "https://github.com/kote2345/The-Simpsons-Hit-and-Run-VR"),
            .init("MoltenVK, SDL, OpenAL Soft, FFmpeg and SMAA", "Do a lot of the heavy lifting."),
        ],
        notices: [
            .init("SHAR VR: MIT licence", "Trevorbilt's own work here: the visionOS runtime, the app, the scripts and the changes in patches/.",
                  URL(string: "https://github.com/\(repository)/blob/main/LICENSE")),
            .init("Third-party code", "MoltenVK, SDL, OpenAL Soft, FFmpeg and SMAA keep their own licences.",
                  URL(string: "https://github.com/\(repository)/blob/main/THIRD_PARTY_NOTICES.md")),
            .init("Fonts", "Space Mono and Roboto, under the SIL Open Font License 1.1."),
            .init("Trevorbilt's name and badge", "All rights reserved; not covered by the repository's licence."),
        ],
        disclaimer: "SHAR VR is a fan project. It isn't affiliated with or endorsed by Disney, 20th Television, Fox, Vivendi, Activision or Radical Entertainment. The game, its characters and its art belong to their rights holders, and the game files are yours to bring.",
        otherPorts: [(name: "Twilight Princess VR",
                      url: URL(string: "https://github.com/edgytoast/avp-ports-index/blob/main/ports/twilight-princess-vr.md")!)])
}

/// One line of status in a glass capsule, with an optional button at its end.
private struct StatusCapsule<Label: View, Action: View>: View {
    private let label: Label
    private let action: Action

    init(@ViewBuilder label: () -> Label, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.label = label()
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) { label }
                .font(.tbBody(14, weight: .medium, relativeTo: .body))
                .accessibilityElement(children: .combine)
            action.buttonStyle(TrevorbiltSecondaryButtonStyle())
        }
        .padding(.leading, 16)
        .padding(.trailing, Action.self == EmptyView.self ? 16 : 4)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
        .background(.white.opacity(0.08), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1) }
    }
}

/// How far an import has got, as a ring (a quarter, turning, while that isn't known).
private struct ProgressRing: View {
    let progress: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 3)
            Circle().trim(from: 0, to: progress ?? 0.25).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
