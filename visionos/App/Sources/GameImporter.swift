import Foundation
import UIKit

// Puts the user's retail PC game files where the engine loads them: the app's Documents folder.
// Accepts an archive (RAR, ZIP, 7z, ...) or an unpacked folder, and finds the game inside however
// it's nested, so the user only has to pick the file.
@MainActor
final class GameImporter: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(progress: Double?, status: String)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    func importGame(from source: URL, completion: @escaping () -> Void) {
        guard !isWorking else { return }
        phase = .working(progress: nil, status: "Preparing…")
        // Extraction takes a minute or two on device; keep going if the user looks away.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import game files")
        // The importer lives as long as the launcher; holding it until the import ends is fine.
        Task.detached(priority: .userInitiated) {
            let error = GameImporter.run(source) { progress, status in
                Task { @MainActor in
                    if self.isWorking { self.phase = .working(progress: progress, status: status) }
                }
            }
            await MainActor.run {
                self.phase = error.map { .failed($0) } ?? .idle
                if error == nil { completion() }
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
    }

    private nonisolated static func run(_ source: URL, report: @escaping (Double?, String) -> Void) -> String? {
        let fileManager = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let documents = GameData.directory.resolvingSymlinksInPath()
        let resolvedSource = source.resolvingSymlinksInPath()
        if documents.path.hasPrefix(resolvedSource.path) {
            return "Pick the game archive or the game's folder, not the app's own folder."
        }
        // A source already inside the app's folder (AirDrop's "Open with" copies it into Inbox) is
        // consumed rather than left behind as a second 2 GB copy.
        let ownsSource = resolvedSource.path.hasPrefix(documents.path + "/")

        // Stage inside Documents so the final moves are same-volume renames, not copies.
        let staging = GameData.directory.appendingPathComponent(".import", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return "Couldn't prepare the import: \(error.localizedDescription)"
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            return "Couldn't read \(source.lastPathComponent)."
        }
        if isDirectory.boolValue {
            report(nil, "Copying \(source.lastPathComponent)…")
            let staged = staging.appendingPathComponent(source.lastPathComponent)
            do {
                if ownsSource {
                    try fileManager.moveItem(at: source, to: staged)
                } else {
                    try fileManager.copyItem(at: source, to: staged)
                }
            } catch {
                return "Couldn't copy the folder: \(error.localizedDescription)"
            }
        } else if let error = extract(source, into: staging, report: report) {
            return error
        }

        report(nil, "Checking the game files…")
        guard let root = findGameRoot(in: staging) else {
            return "That doesn't look like the PC version of The Simpsons: Hit & Run: there's no art folder with .rcf archives next to it."
        }

        report(nil, "Moving the game files into place…")
        do {
            for item in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let destination = GameData.directory.appendingPathComponent(item.lastPathComponent)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: item, to: destination)
            }
        } catch {
            return "Couldn't move the game files into place: \(error.localizedDescription)"
        }
        GameData.excludeFromBackup()

        if ownsSource && !isDirectory.boolValue {
            try? fileManager.removeItem(at: source)
            let folder = source.deletingLastPathComponent()
            if folder.resolvingSymlinksInPath() != documents,
               (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
            }
        }
        return nil
    }

    private nonisolated static func extract(_ archive: URL, into destination: URL,
                                            report: @escaping (Double?, String) -> Void) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let status = "Extracting \(archive.lastPathComponent)…"
        report(size > 0 ? 0 : nil, status)
        let progress = ProgressRelay { bytesRead in
            report(size > 0 ? min(Double(bytesRead) / size, 1) : nil, status)
        }
        let callback: SharExtractProgress = { context, bytesRead in
            Unmanaged<ProgressRelay>.fromOpaque(context!).takeUnretainedValue().update(bytesRead)
        }
        let error = withExtendedLifetime(progress) {
            SharExtractArchive(archive.path, destination.path, callback,
                               Unmanaged.passUnretained(progress).toOpaque())
        }
        guard let error else { return nil }
        defer { free(error) }
        return String(cString: error)
    }

    // The shallowest folder holding the game: the one with the art folder and .rcf archives.
    private nonisolated static func findGameRoot(in directory: URL) -> URL? {
        var queue = [directory]
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            if GameData.looksLikeGame(folder) { return folder }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            queue += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return nil
    }
}

// Carries C progress callbacks back to Swift, throttled to about one report per 16 MB.
private final class ProgressRelay {
    private let onUpdate: (Int64) -> Void
    private var lastReported: Int64 = 0

    init(onUpdate: @escaping (Int64) -> Void) { self.onUpdate = onUpdate }

    func update(_ bytesRead: Int64) {
        guard bytesRead - lastReported >= 16 << 20 else { return }
        lastReported = bytesRead
        onUpdate(bytesRead)
    }
}
