import AVFAudio
import CompositorServices
import os
import SwiftUI
import TrevorbiltKit

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
        Trevorbilt.registerFonts()
        GameAudio.observeInterruptions()
        MemoryWatch.start()
        GameData.excludeFromBackup()
        SharVisionOS_SetViewHandler { mode in
            Task { @MainActor in await GameScenes.present(mode) }
        }
        SharVisionOS_SetRoomBehindMenus(GameView.roomBehindMenus)
    }

    var body: some Scene {
        // Only ever one launcher: it's opened with the same value each time, and visionOS brings
        // the window already showing that value to the front instead of opening another.
        WindowGroup(id: SHARVRApp.launcherID, for: String.self) { _ in
            LauncherView()
        } defaultValue: {
            SHARVRApp.launcherID
        }
        .windowResizability(.contentSize)

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
        GameView.shared.windowCloses += 1
        openWindow?(id: SHARVRApp.launcherID, value: SHARVRApp.launcherID)
    }
}

// The immersive space's style, from the game's View setting (VR menu): full immersion or
// progressive (the Digital Crown sets how much of the game surrounds you).
@Observable
final class GameView {
    static let shared = GameView()
    var style: any ImmersionStyle = GameView.style(for: GameView.savedMode())
    /// The game's window is showing (the Window view): the launcher leaves the controller to it.
    var windowShowing = false
    /// Counts the game's window being closed with its own controls: the launcher comes back on Play.
    var windowCloses = 0

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

    // How much of the game is installed, for the launcher: "1.97 GB" and its file count. Only the
    // items excludeFromBackup marks, so saves, an import's staging folder or AirDrop's Inbox don't
    // count. Walks the folders, so off the main thread.
    nonisolated static func installedSummary() -> (size: String, files: Int)? {
        let folders: Set<String> = ["art", "movies", "scripts", "sound"]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        var bytes: Int64 = 0, files = 0
        func count(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        for item in items {
            let name = item.lastPathComponent.lowercased()
            if folders.contains(name) {
                guard let walker = FileManager.default.enumerator(at: item, includingPropertiesForKeys: keys) else { continue }
                for case let url as URL in walker { count(url) }
            } else if name.hasSuffix(".rcf") {
                count(item)
            }
        }
        guard files > 0 else { return nil }
        return (ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), files)
    }

    // The game's own files, about 2 GB the player can always copy in again, stay out of iCloud
    // backups: its folders and its .rcf archives. Anything else here, saves included, is backed
    // up as usual. Marking a folder covers what's in it.
    nonisolated static func excludeFromBackup() {
        let folders: Set<String> = ["art", "movies", "scripts", "sound"]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for var item in items {
            let name = item.lastPathComponent.lowercased()
            guard folders.contains(name) || name.hasSuffix(".rcf") else { continue }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? item.setResourceValues(values)
        }
    }
}

// visionOS interrupts the app's audio for Siri, calls and alarms. The game's sound pauses for the
// interruption and comes back once the audio session is active again. The end isn't always
// announced, so coming back to the foreground tries too.
@MainActor
enum GameAudio {
    private static var interrupted = false
    private static var observers: [NSObjectProtocol] = []

    static func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: AVAudioSession.sharedInstance(), queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                if type == .began { began() } else if type == .ended { resume(attempts: 5) }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { resume(attempts: 5) }
        })
    }

    private static func began() {
        guard !interrupted else { return }
        interrupted = true
        print("[SHARVR] audio interrupted")
        SharVisionOS_SetAudioInterrupted(true)
    }

    // Reactivates the session, then the game's sound. While another app still has the audio, it
    // tries again a second later, a few times; coming back to the foreground starts over.
    private static func resume(attempts: Int) {
        guard interrupted else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            interrupted = false
            print("[SHARVR] audio interruption over")
            SharVisionOS_SetAudioInterrupted(false)
        } catch {
            print("[SHARVR] the audio session isn't back yet: \(error.localizedDescription)")
            guard attempts > 1 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                resume(attempts: attempts - 1)
            }
        }
    }
}

// Logs visionOS's memory warnings with what's left before its limit, so a session that ends early
// can be told apart from a crash.
@MainActor
enum MemoryWatch {
    private static var source: DispatchSourceMemoryPressure?

    static func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            print("[SHARVR] memory pressure (\(event.contains(.critical) ? "critical" : "warning")): "
                  + "\(os_proc_available_memory() / 1_048_576) MB left")
        }
        source.resume()
        Self.source = source
    }
}
