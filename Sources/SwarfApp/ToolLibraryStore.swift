import CAMCore
import Foundation
import SwiftUI

/// App-wide tool library persisted to ~/Library/Application Support/Swarf/tools.json.
@MainActor
final class ToolLibraryStore: ObservableObject {
    static let shared = ToolLibraryStore()

    @Published var library: ToolLibrary {
        didSet { save() }
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Swarf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("tools.json") }

    /// The last load or save problem, shown in the Tool Library settings.
    @Published var lastError: String?

    private init() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            library = .starter
            save()  // persist so tool IDs stay stable and projects can follow library edits
            return
        }
        do {
            library = try JSONDecoder().decode(ToolLibrary.self, from: Data(contentsOf: url))
        } catch {
            // Never overwrite a library that could not be read: keep it beside the new one so it can be repaired.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = Self.directory.appendingPathComponent("tools-unreadable-\(stamp).json")
            let kept = (try? FileManager.default.moveItem(at: url, to: backup)) != nil
            library = .starter
            lastError = "The saved tool library could not be read, so the starter tools were loaded. "
                + (kept ? "The old file was kept as \(backup.lastPathComponent)." : "The old file could not be set aside and was left in place.")
            if kept { save() }
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(library).write(to: Self.fileURL, options: .atomic)
        } catch {
            lastError = "The tool library could not be saved: \(error.localizedDescription)"
        }
    }

    var tools: [Tool] { library.tools }

    func add(_ t: Tool) {
        var t = t
        t.number = (library.tools.map(\.number).max() ?? 0) + 1
        library.tools.append(t)
    }

    func update(_ t: Tool) {
        if let i = library.tools.firstIndex(where: { $0.id == t.id }) { library.tools[i] = t }
    }

    func remove(_ id: UUID) { library.tools.removeAll { $0.id == id } }

    func resetToStarter() { library = .starter }

    func importFile(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        if let lib = try? JSONDecoder().decode(ToolLibrary.self, from: data) {
            // Add everything in one assignment so the library is saved once, and count only what is new.
            var tools = library.tools
            var added = 0
            for t in lib.tools where t.diameter.isFinite && t.diameter > 0 && !tools.contains(where: { $0.id == t.id }) {
                tools.append(t)
                added += 1
            }
            if added > 0 { library.tools = tools }
            return added
        }
        let tools = try ToolLibrary.importFusion(data)
        for t in tools { add(t) }
        return tools.count
    }
}
