import AVFAudio
import CompositorServices
import SwiftUI

@main
struct SHARVRApp: App {
    @State private var view = GameView.shared

    init() {
        // The game's listener is the headset: OpenAL already turns every sound with the head.
        // visionOS's default head-tracked soundstage would turn the mix a second time, so bypass
        // it and send the game's stereo straight to the speakers, as a PC headset hears it. It is
        // also anchored to no window, so it plays on after the launcher closes.
        do {
            try AVAudioSession.sharedInstance().setIntendedSpatialExperience(.bypassed)
        } catch {
            print("[SHARVR] setIntendedSpatialExperience(.bypassed) failed: \(error)")
        }
        SharVisionOS_SetViewHandler { mode in
            Task { @MainActor in await GameScenes.present(mode) }
        }
        SharVisionOS_SetRoomBehindMenus(GameView.roomBehindMenus)
    }

    var body: some Scene {
        WindowGroup(id: SHARVRApp.launcherID) {
            LauncherView()
        }

        // One game window, never restored at launch: the launcher is the way in.
        Window("The Simpsons: Hit & Run", id: SHARVRApp.gameWindowID) {
            GameWindowView()
        }
        .restorationBehavior(.disabled)
        .windowStyle(.plain)
        .defaultSize(width: 1280, height: 720)
        // Resizing keeps the content's 16:9.
        .windowResizability(.contentSize)

        ImmersiveSpace(id: SHARVRApp.immersiveSpaceID) {
            CompositorLayer(configuration: SHARConfiguration()) { renderer in
                // Swift's LayerRenderer is the same object as the C API's cp_layer_renderer_t, so
                // the engine drives every frame itself from its own thread.
                SharVisionOS_Launch(renderer, GameData.directory.path)
            }
            // A Digital Crown recenter moves the space's origin (and the progressive portal) to
            // where the player faces now; the game re-anchors its front to match (in Progressive,
            // keeping what the player was looking at in the portal).
            .onWorldRecenter { SharVisionOS_WorldRecentered() }
        }
        // The game's View setting picks the style, and changing it in the VR menu switches it live.
        .immersionStyle(selection: $view.style, in: GameView.progressive, .full, .mixed)
    }

    static let immersiveSpaceID = "Game"
    static let gameWindowID = "GameWindow"
    static let launcherID = "Launcher"
}

// Moves the game between its immersive space (Full, Progressive) and its shared-space window
// (Window) when the View setting changes in the game's menu. SwiftUI's scene actions come from
// whichever of the app's windows last appeared, since the immersive space has no SwiftUI views.
@MainActor
enum GameScenes {
    private static var openImmersiveSpace: OpenImmersiveSpaceAction?
    private static var dismissImmersiveSpace: DismissImmersiveSpaceAction?
    private static var openWindow: OpenWindowAction?
    private static var dismissWindow: DismissWindowAction?
    // The View the game is shown for, or nil while it isn't showing.
    static var presentedMode: Int32?

    static func capture(openImmersiveSpace: OpenImmersiveSpaceAction, dismissImmersiveSpace: DismissImmersiveSpaceAction,
                        openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        Self.openImmersiveSpace = openImmersiveSpace
        Self.dismissImmersiveSpace = dismissImmersiveSpace
        Self.openWindow = openWindow
        Self.dismissWindow = dismissWindow
    }

    static func present(_ mode: Int32) async {
        let previous = presentedMode
        print("[SHARVR] view \(mode) (was \(previous.map(String.init) ?? "not showing"))")
        GameView.shared.style = GameView.style(for: mode)
        guard let previous, previous != mode else { return }
        presentedMode = mode
        if mode == 2 {
            // The window opens once the space has gone; the engine waits for it in between.
            await dismissImmersiveSpace?()
            openWindow?(id: SHARVRApp.gameWindowID)
        } else if previous == 2 {
            // The space opens while the window still shows, then the window goes.
            if case .opened = await openImmersiveSpace?(id: SHARVRApp.immersiveSpaceID) {
                dismissWindow?(id: SHARVRApp.gameWindowID)
            } else {
                presentedMode = previous
            }
        }
    }

    // The window was closed with its own controls rather than for the immersive space: bring back
    // the launcher, which offers Resume.
    static func windowClosed() {
        guard presentedMode == 2 else { return }
        presentedMode = nil
        openWindow?(id: SHARVRApp.launcherID)
    }
}

// The immersive space's style, from the game's View setting (VR menu): full immersion or
// progressive (the Digital Crown sets how much of the game surrounds you).
@Observable
final class GameView {
    static let shared = GameView()
    var style: any ImmersionStyle = GameView.style(for: GameView.savedMode())

    // Portrait, because the wide default portal cuts off what's below eye level (Homer's hands,
    // the wheel). With the system's own range: a custom one (0.1...1.0, opening at 0.4) showed
    // nothing at all on the headset, though the Simulator took it.
    static let progressive = ProgressiveImmersionStyle.progressive(aspectRatio: .portrait)

    static func style(for mode: Int32) -> any ImmersionStyle {
        // Window (2) doesn't use the space. Full is a mixed space with the room behind menus on:
        // the game's frames are opaque except where a menu frame draws nothing.
        mode == 1 ? progressive : roomBehindMenus ? .mixed : .full
    }

    // The launcher's "Show my room around menus" (on unless turned off).
    static var roomBehindMenus: Bool {
        get { UserDefaults.standard.object(forKey: "roomBehindMenus") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "roomBehindMenus")
            SharVisionOS_SetRoomBehindMenus(newValue)
            shared.style = style(for: savedMode())
        }
    }

    // The engine saves its settings where SDL_GetPrefPath("c4rlox", "simpsons") points; read the
    // View before the engine starts, so the space opens in the right style.
    static var settingsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("c4rlox/simpsons/vrsettings.cfg")
    }

    static func savedMode() -> Int32 {
        guard let text = try? String(contentsOf: settingsFile, encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\n") where line.hasPrefix("view=") {
            return Int32(line.dropFirst(5)) ?? 0
        }
        return 0
    }

    // The launcher's View picker, before the engine starts and reads the file: the view line is
    // replaced (or added), the rest kept.
    static func saveMode(_ mode: Int32) {
        let text = (try? String(contentsOf: settingsFile, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.hasPrefix("view=") }
        lines.append("view=\(mode)")
        try? FileManager.default.createDirectory(at: settingsFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: settingsFile, atomically: true, encoding: .utf8)
        shared.style = style(for: mode)
    }
}

enum GameData {
    // The user's retail PC game files live here, installed by GameImporter (or copied in with
    // Finder or the Files app); none ship with the app. The engine runs with this as its working
    // directory.
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var isPresent: Bool { looksLikeGame(directory) }

    // The PC game's root: an art folder alongside the .rcf archives.
    nonisolated static func looksLikeGame(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("art").path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.contains { $0.lowercased().hasSuffix(".rcf") }
    }
}
