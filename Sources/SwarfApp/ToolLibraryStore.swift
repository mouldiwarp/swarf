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

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL), let lib = try? JSONDecoder().decode(ToolLibrary.self, from: data) {
            library = lib
        } else {
            library = .starter
            save()  // persist so tool IDs stay stable and projects can follow library edits
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(library) { try? data.write(to: Self.fileURL, options: .atomic) }
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
            for t in lib.tools where !library.tools.contains(where: { $0.id == t.id }) { library.tools.append(t) }
            return lib.tools.count
        }
        let tools = try ToolLibrary.importFusion(data)
        for t in tools { add(t) }
        return tools.count
    }
}
