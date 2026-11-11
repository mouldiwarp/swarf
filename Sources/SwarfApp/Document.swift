import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let swarfProject = UTType(exportedAs: "io.github.swarfcam.project")
    static let stlModel = UTType(importedAs: "public.standard-tesselated-geometry-format")
}

/// A Swarf project: the original STL plus the job description, stored as a package.
final class SwarfDocument: ReferenceFileDocument {
    typealias Snapshot = (job: Job, stl: Data?, name: String)

    /// Only projects are documents. STL files are always *imported* into a new project so
    /// the user's original model file can never be overwritten by autosave.
    static var readableContentTypes: [UTType] { [.swarfProject] }
    static var writableContentTypes: [UTType] { [.swarfProject] }

    @Published var job: Job
    @Published private(set) var stlData: Data?
    @Published private(set) var mesh: Mesh?
    @Published var modelName: String
    /// Changes whenever the model itself is replaced, so undo can tell a model swap from a plain job edit.
    private(set) var modelRevision = 0

    init() {
        job = SwarfDocument.newJob()
        modelName = "Untitled"
    }

    static func newJob() -> Job {
        var j = Job()
        let d = UserDefaults.standard
        if let m = d.string(forKey: "defaultMachineID") { j.machineID = m }
        if let m = d.string(forKey: "defaultMaterialID") { j.stock.materialID = m }
        if let q = d.string(forKey: "defaultQuality"), let qq = ResolutionQuality(rawValue: q) { j.quality = qq }
        return j
    }

    required init(configuration: ReadConfiguration) throws {
        let file = configuration.file
        guard let wrappers = file.fileWrappers,
              let jobData = wrappers["job.json"]?.regularFileContents else {
            throw Self.corrupt("The project has no job.json, so it is not a complete Swarf project.")
        }
        do {
            job = try JSONDecoder().decode(Job.self, from: jobData)
        } catch {
            throw Self.corrupt("The job settings (job.json) could not be read. The project may be damaged or made by a newer version of Swarf.")
        }
        let name = String(data: wrappers["name.txt"]?.regularFileContents ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        modelName = name.isEmpty ? "Model" : name
        if let stl = wrappers["model.stl"]?.regularFileContents {
            do {
                mesh = try STL.parse(stl)
                stlData = stl
            } catch {
                throw Self.corrupt("The model inside the project (model.stl) could not be read: \(error.localizedDescription)")
            }
        }
    }

    private static func corrupt(_ reason: String) -> Error {
        CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedFailureReasonErrorKey: reason])
    }

    /// Puts back an earlier model and job together (undo and redo of "Import Model").
    func restore(job: Job, stl: Data?, mesh: Mesh?, name: String, revision: Int) {
        if revision != modelRevision {
            stlData = stl
            modelName = name
            modelRevision = revision
            self.job = job
            self.mesh = mesh
        } else {
            self.job = job
        }
    }

    func setModel(data: Data, name: String, resetOrientation: Bool) throws {
        let m = try STL.parse(data)
        stlData = data
        modelName = name
        modelRevision = Self.nextRevision()
        if resetOrientation {
            var j = job
            j.orientation = Orientation()
            // Heuristic unit detection: tiny models are probably in inches.
            let size = m.bounds.size
            if max(size.x, size.y, size.z) < 12 { j.orientation.scale = 25.4 }
            job = j
        }
        mesh = m
    }

    private static var revisionCounter = 0
    private static func nextRevision() -> Int { revisionCounter += 1; return revisionCounter }

    func snapshot(contentType: UTType) throws -> Snapshot { (job, stlData, modelName) }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var files: [String: FileWrapper] = [
            "job.json": FileWrapper(regularFileWithContents: try enc.encode(snapshot.job)),
            "name.txt": FileWrapper(regularFileWithContents: Data(snapshot.name.utf8)),
        ]
        if let stl = snapshot.stl { files["model.stl"] = FileWrapper(regularFileWithContents: stl) }
        return FileWrapper(directoryWithFileWrappers: files)
    }
}

/// STL files waiting to be imported into freshly created project windows.
@MainActor
final class PendingImports {
    static let shared = PendingImports()
    private(set) var urls: [URL] = []

    func enqueue(_ url: URL) { urls.append(url) }

    func next() -> URL? { urls.isEmpty ? nil : urls.removeFirst() }

    /// Opens files handed to the app (Finder, Dock, `open`): projects open normally,
    /// STLs each get a new untitled project.
    static func open(_ urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "stl" {
                shared.enqueue(url)
                NSDocumentController.shared.newDocument(nil)
            } else {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, err in
                    if let err { NSApp.presentError(err) }
                }
            }
        }
    }
}
