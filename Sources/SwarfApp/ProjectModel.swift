import CAMCore
import Combine
import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case model, stock, machine
    case region(UUID)
    case operation(UUID)
}

enum InteractionMode: String, CaseIterable, Identifiable {
    case orbit, faceUp, faceDown, drawKeepOut, placeTab
    var id: String { rawValue }
    var label: String {
        switch self {
        case .orbit: return "Navigate"
        case .faceUp: return "Pick Top Face"
        case .faceDown: return "Pick Bottom Face"
        case .drawKeepOut: return "Draw Keep-out"
        case .placeTab: return "Place Tabs"
        }
    }
    var symbol: String {
        switch self {
        case .orbit: return "rotate.3d"
        case .faceUp: return "arrow.up.square"
        case .faceDown: return "arrow.down.square"
        case .drawKeepOut: return "rectangle.dashed.badge.record"
        case .placeTab: return "pin"
        }
    }
}

enum OpStatus: Equatable {
    case pending, running(Double), done, failed(String)
}

@MainActor
final class ProjectModel: ObservableObject {
    let document: SwarfDocument
    weak var undoManager: UndoManager?

    @Published var selection: SidebarItem? = .model
    @Published var mode: InteractionMode = .orbit
    @Published private(set) var placed: PlacedModel?
    @Published private(set) var meshVersion = 0
    @Published private(set) var toolpaths: [Toolpath] = []
    @Published private(set) var toolpathVersion = 0
    @Published private(set) var status: [UUID: OpStatus] = [:]
    @Published private(set) var generating = false
    @Published var autoGenerate = true
    @Published var highlightTriangles: [Int] = []
    @Published var showModel = true
    @Published var showStock = true
    @Published var showToolpaths = true
    @Published var showRapids = true
    @Published var showUndercuts = false
    @Published var viewRequest: ViewPreset? = nil
    @Published var errorMessage: String? = nil
    @Published var showExport = false
    @Published var showImporter = false
    @Published var showInspector = true
    @Published var diagnostics: Mesh.Diagnostics? = nil

    // Simulation
    @Published var simMode = false
    @Published private(set) var simStock: Grid2D?
    @Published private(set) var simVersion = 0
    @Published private(set) var simAnalysis: StockSimulator.Analysis?
    @Published var simPosition: Double = 1  // 0...1
    @Published var simPlaying = false
    @Published private(set) var simToolPosition: (V3, Tool)?
    private var simRunner: SimRunner?
    private var playTimer: Timer?

    private var context: CAMContext?
    private var contextKey = ""
    private var cache: [UUID: (key: String, tp: Toolpath)] = [:]
    private var task: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var lastPlacementKey = ""
    private var generationToken = 0

    var job: Job { document.job }

    init(document: SwarfDocument) {
        self.document = document
        document.$job
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.jobChanged() }
            }
            .store(in: &cancellables)
        document.$mesh
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.diagnostics = nil
                    self?.lastPlacementKey = ""
                    self?.contextKey = ""
                    // Toolpaths from the previous model must never be reused for the new one.
                    self?.cache = [:]
                    self?.jobChanged()
                }
            }
            .store(in: &cancellables)
        // Operations keep a copy of their tool. When the same tool is edited in the library, update the copy's
        // geometry (flute length, diameter, flute style…) but keep the operation's own feeds and speeds.
        ToolLibraryStore.shared.$library
            .sink { [weak self] lib in
                Task { @MainActor in self?.syncTools(from: lib) }
            }
            .store(in: &cancellables)
        jobChanged()
    }

    private func syncTools(from lib: ToolLibrary) {
        let byID = Dictionary(lib.tools.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func synced(_ op: CAMCore.Operation) -> Tool? {
            guard var t = byID[op.tool.id] else { return nil }
            t.number = op.tool.number  // the T number can be overridden per operation
            return t == op.tool ? nil : t
        }
        guard job.operations.contains(where: { synced($0) != nil }) else { return }
        updateJob("Update Tools from Library") { j in
            for i in j.operations.indices {
                if let t = synced(j.operations[i]) { j.operations[i].tool = t }
            }
        }
    }

    /// Developer hooks used for automated screenshots: -SwarfAutoProcess YES, -SwarfAutoSimulate YES, -SwarfAutoExport YES,
    /// -SwarfAutoOps vcarve,cutout (add these operations instead of the full-processing template),
    /// -SwarfSelectOp N (1-based), -SwarfView top|iso|front|right, -SwarfKeepOut x0,y0,x1,y1 (adds and selects a keep-out box).
    private func runAutomationHooks() {
        let d = UserDefaults.standard
        if document.mesh != nil, let v = d.string(forKey: "SwarfView"), let preset = ViewPreset(rawValue: v) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.viewRequest = preset }
        }
        if document.mesh != nil, document.job.regions.isEmpty, let k = d.string(forKey: "SwarfKeepOut") {
            let n = k.split(separator: ",").compactMap { Double($0) }
            if n.count == 4 { addRegion(min: V2(n[0], n[1]), max: V2(n[2], n[3])) }
        }
        guard d.bool(forKey: "SwarfAutoProcess"), document.mesh != nil, document.job.operations.isEmpty else { return }
        if d.bool(forKey: "SwarfAutoSimulate") { pendingAutoSim = true }
        if d.bool(forKey: "SwarfAutoExport") { pendingAutoExport = true }
        if let list = d.string(forKey: "SwarfAutoOps") {
            for k in list.split(separator: ",").compactMap({ OperationKind(rawValue: String($0)) }) { addOperation(k) }
        } else {
            addFullProcessing()
        }
        let ops = document.job.operations
        let n = d.integer(forKey: "SwarfSelectOp")
        if n >= 1, n <= ops.count { selection = .operation(ops[n - 1].id) }
    }

    private var pendingAutoSim = false
    private var pendingAutoExport = false

    // MARK: Editing with undo

    func updateJob(_ actionName: String = "Edit", _ body: (inout Job) -> Void) {
        let before = undoState
        var new = before.job
        body(&new)
        guard new != before.job else { return }
        document.job = new
        registerUndo(before, name: actionName)
    }

    private struct UndoState {
        let job: Job
        let stl: Data?
        let mesh: Mesh?
        let name: String
        let revision: Int
    }

    private var undoState: UndoState {
        UndoState(job: document.job, stl: document.stlData, mesh: document.mesh, name: document.modelName, revision: document.modelRevision)
    }

    /// The inverse has to be registered while the undo is still running. That is how the undo manager knows it is a
    /// redo; registered any later it becomes a new undo step and Redo stops working.
    private func registerUndo(_ old: UndoState, name: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: document) { [weak self] doc in
            MainActor.assumeIsolated {
                let cur = self?.undoState
                doc.restore(job: old.job, stl: old.stl, mesh: old.mesh, name: old.name, revision: old.revision)
                if let cur { self?.registerUndo(cur, name: name) }
            }
        }
        um.setActionName(name)
    }

    func jobBinding<T>(_ kp: WritableKeyPath<Job, T>, name: String = "Edit") -> Binding<T> {
        Binding(get: { self.document.job[keyPath: kp] }, set: { v in self.updateJob(name) { $0[keyPath: kp] = v } })
    }

    func opBinding<T>(_ id: UUID, _ kp: WritableKeyPath<CAMCore.Operation, T>) -> Binding<T>? {
        guard document.job.operations.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.document.job.operations.first { $0.id == id }?[keyPath: kp] ?? CAMCore.Operation.placeholder[keyPath: kp] },
            set: { v in
                self.updateJob("Edit Operation") { j in
                    if let i = j.operations.firstIndex(where: { $0.id == id }) { j.operations[i][keyPath: kp] = v }
                }
            })
    }

    func regionBinding<T>(_ id: UUID, _ kp: WritableKeyPath<Region, T>) -> Binding<T> {
        Binding(
            get: { self.document.job.regions.first { $0.id == id }?[keyPath: kp] ?? Region.placeholder[keyPath: kp] },
            set: { v in
                self.updateJob("Edit Region") { j in
                    if let i = j.regions.firstIndex(where: { $0.id == id }) { j.regions[i][keyPath: kp] = v }
                }
            })
    }

    // MARK: Model & orientation

    func importSTL(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let before = undoState
            try document.setModel(data: data, name: url.deletingPathExtension().lastPathComponent, resetOrientation: true)
            registerUndo(before, name: "Import Model")
            requestView(.iso)
            runAutomationHooks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentImport() { showImporter = true }

    func loadSample() {
        let base = STL.box(V3(90, 70, 6))
        let dome = STL.dome(radius: 22, segments: 72, rings: 36, center: V2(32, 35)).translated(V3(0, 0, 6))
        let boss = STL.box(V3(18, 40, 6), at: V3(62, 15, 6))
        let mesh = STL.merge([base, dome, boss])
        do {
            try document.setModel(data: STL.binaryData(mesh), name: "Sample Relief", resetOrientation: true)
            updateJob("Sample") { $0.stock.extraTop = 2 }
            requestView(.iso)
        } catch { errorMessage = error.localizedDescription }
    }

    func rotate(axis: V3, degrees: Double) {
        updateJob("Rotate") { $0.orientation.rotate(axis: axis, degrees: degrees) }
    }

    func layFlat() {
        guard let mesh = document.mesh else { return }
        updateJob("Lay Flat") { j in
            j.orientation.rotation = Placement.layFlatRotation(mesh.scaled(j.orientation.scale))
        }
    }

    func resetOrientation() {
        updateJob("Reset Orientation") { $0.orientation.rotation = .identity }
    }

    func pickFace(triangle: Int, up: Bool) {
        guard let placed, placed.mesh.triangles.indices.contains(triangle) else { return }
        let n = placed.mesh.triangles[triangle].normal
        let nv = V3(Double(n.x), Double(n.y), Double(n.z))
        updateJob(up ? "Face Up" : "Face Down") { j in
            if up { j.orientation.faceUp(normal: nv) } else { j.orientation.faceDown(normal: nv) }
        }
        highlightTriangles = []
        mode = .orbit
    }

    // MARK: Operations

    func addOperation(_ kind: OperationKind) {
        let lib = ToolLibraryStore.shared.library
        // The library can be empty (every tool deleted): fall back to the built-in starter tools.
        func pick(_ k: ToolKind) -> Tool {
            lib.closest(kind: k, diameter: 6) ?? lib.tools.first ?? ToolLibrary.starter.closest(kind: k, diameter: 6)
                ?? ToolLibrary.starter.tools[0]
        }
        let tool: Tool
        switch kind {
        case .parallelFinish, .waterlineFinish: tool = pick(.ball)
        case .vcarve: tool = pick(.vBit)
        default: tool = pick(.flat)
        }
        let op = CAMCore.Operation(kind: kind, tool: tool, material: .named(job.stock.materialID))
        updateJob("Add Operation") { $0.operations.append(op) }
        selection = .operation(op.id)
    }

    func addFullProcessing() {
        guard let mesh = document.mesh else { return }
        let job = self.job
        let lib = ToolLibraryStore.shared.library
        let ctx = CAMContext(raw: mesh, job: job)
        let ops = JobTemplates.fullProcessing(ctx, library: lib, material: .named(job.stock.materialID))
        updateJob("Full Processing") { $0.operations.append(contentsOf: ops) }
        if let f = ops.first { selection = .operation(f.id) }
    }

    func duplicateOperation(_ id: UUID) {
        updateJob("Duplicate Operation") { j in
            guard let i = j.operations.firstIndex(where: { $0.id == id }) else { return }
            var c = j.operations[i]
            c.id = UUID()
            c.name += " copy"
            j.operations.insert(c, at: i + 1)
        }
    }

    func deleteOperation(_ id: UUID) {
        updateJob("Delete Operation") { $0.operations.removeAll { $0.id == id } }
        if selection == .operation(id) { selection = nil }
    }

    func moveOperations(from: IndexSet, to: Int) {
        updateJob("Reorder Operations") { $0.operations.move(fromOffsets: from, toOffset: to) }
    }

    func setTool(_ tool: Tool, for id: UUID, resetCutting: Bool) {
        updateJob("Change Tool") { j in
            guard let i = j.operations.firstIndex(where: { $0.id == id }) else { return }
            j.operations[i].tool = tool
            if resetCutting {
                let stepover = j.operations[i].cutting.stepoverPercent
                j.operations[i].cutting = Material.named(j.stock.materialID).apply(tool.defaults)
                if j.operations[i].kind != .facing { j.operations[i].cutting.stepoverPercent = j.operations[i].kind == .parallelFinish ? stepover : tool.defaults.stepoverPercent }
            }
        }
    }

    // MARK: Regions

    func addRegion(min a: V2, max b: V2) {
        let r = Region(name: "Keep-out \(job.regions.count + 1)", min: a, max: b)
        updateJob("Add Keep-out") { $0.regions.append(r) }
        selection = .region(r.id)
    }

    func moveRegion(_ id: UUID, by d: V2, actionName: String = "Move Region") {
        updateJob(actionName) { j in
            guard let i = j.regions.firstIndex(where: { $0.id == id }) else { return }
            j.regions[i].min += d
            j.regions[i].max += d
        }
    }

    var selectedRegionID: UUID? {
        if case .region(let id) = selection { return id }
        return nil
    }

    func deleteRegion(_ id: UUID) {
        updateJob("Delete Region") { $0.regions.removeAll { $0.id == id } }
        if selection == .region(id) { selection = nil }
    }

    func addTab(at p: V2) {
        guard case .operation(let id) = selection else { return }
        updateJob("Place Tab") { j in
            guard let i = j.operations.firstIndex(where: { $0.id == id }), j.operations[i].kind == .cutout else { return }
            j.operations[i].tabs.manualPositions.append(p)
            j.operations[i].tabs.enabled = true
        }
    }

    var selectedOperation: CAMCore.Operation? {
        if case .operation(let id) = selection { return job.operations.first { $0.id == id } }
        return nil
    }

    // MARK: Generation pipeline

    func jobChanged() {
        updatePlacement()
        if autoGenerate { scheduleGeneration(delay: 0.35) } else { markStale() }
    }

    private func markStale() {
        for op in job.operations where cache[op.id]?.key != opKey(op) { status[op.id] = .pending }
    }

    private func updatePlacement() {
        guard let mesh = document.mesh else {
            placed = nil
            meshVersion += 1
            return
        }
        let j = job
        let key = "\(j.orientation.rotation.m)|\(j.orientation.scale)|\(String(describing: j.stock))"
        if key == lastPlacementKey { return }
        lastPlacementKey = key
        placed = PlacedModel(raw: mesh, orientation: j.orientation, stock: j.stock)
        if diagnostics == nil { diagnostics = mesh.diagnostics() }
        meshVersion += 1
        stopSimulation()
    }

    private func makeContextKey(_ j: Job) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let maxTool = j.operations.map { $0.tool.radius + max(0, $0.boundaryMargin) + $0.stockToLeaveXY }.max() ?? 5
        let parts: [Data] = [(try? enc.encode(j.orientation)) ?? Data(), (try? enc.encode(j.stock)) ?? Data(),
                             (try? enc.encode(j.origin)) ?? Data(), (try? enc.encode(j.regions)) ?? Data(), (try? enc.encode(j.activeTestCut)) ?? Data(), Data("\(j.quality)|\(j.safeHeight)|\(Int(ceil(max(8, maxTool + 4) / 4)))".utf8),
                             // The model itself: replacing it (or undoing a replacement) changes the revision, so every
                             // operation's cache key changes and nothing computed for the old shape survives.
                             Data("model\(document.modelRevision)".utf8)]
        return parts.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "#")
    }

    private func opKey(_ op: CAMCore.Operation) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var o = op
        o.name = ""
        return String(decoding: (try? enc.encode(o)) ?? Data(), as: UTF8.self) + contextKey
    }

    /// Recalculates every toolpath from scratch: discards cached toolpaths and the prepared model geometry.
    func generateNow() {
        cache = [:]
        context = nil
        contextKey = ""
        for op in job.operations where op.enabled { status[op.id] = .pending }
        scheduleGeneration(delay: 0)
    }

    func scheduleGeneration(delay: Double) {
        task?.cancel()
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if Task.isCancelled { return }
            await self?.runGeneration()
        }
    }

    private func runGeneration() async {
        guard let mesh = document.mesh else {
            toolpaths = []; toolpathVersion += 1
            return
        }
        let j = job
        let key = makeContextKey(j)
        // A cancelled run can finish after its replacement has started; only the newest run may clear the flag.
        generationToken += 1
        let token = generationToken
        generating = true
        defer { if token == generationToken { generating = false } }
        if context == nil || key != contextKey {
            let ctx = await Self.makeContext(mesh: mesh, job: j)
            if Task.isCancelled { return }
            context = ctx
            contextKey = key
        }
        guard let ctx = context else { return }
        var out: [Toolpath] = []
        var newStatus = status
        for op in j.operations {
            guard op.enabled else { newStatus[op.id] = nil; continue }
            let k = opKey(op)
            if let c = cache[op.id], c.key == k {
                var tp = c.tp
                tp.name = op.name
                out.append(tp)
                newStatus[op.id] = .done
                continue
            }
            status[op.id] = .running(0)
            let id = op.id
            do {
                let tp = try await Self.generate(ctx: ctx, op: op) { [weak self] p in
                    Task { @MainActor [weak self] in
                        if case .running = self?.status[id] { self?.status[id] = .running(p) }
                    }
                }
                if Task.isCancelled { return }
                cache[op.id] = (k, tp)
                out.append(tp)
                newStatus[op.id] = .done
                status[op.id] = .done
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                newStatus[op.id] = .failed(error.localizedDescription)
                status[op.id] = .failed(error.localizedDescription)
                cache[op.id] = nil
            }
        }
        // Remove stale cache entries
        let ids = Set(j.operations.map(\.id))
        cache = cache.filter { ids.contains($0.key) }
        status = newStatus.filter { ids.contains($0.key) }
        toolpaths = out
        toolpathVersion += 1
        if simMode || pendingAutoSim { pendingAutoSim = false; startSimulation() }
        if pendingAutoExport { pendingAutoExport = false; showExport = true }
    }

    nonisolated static func makeContext(mesh: Mesh, job: Job) async -> CAMContext {
        await Task.detached(priority: .userInitiated) { CAMContext(raw: mesh, job: job) }.value
    }

    nonisolated static func generate(ctx: CAMContext, op: CAMCore.Operation, progress: @escaping @Sendable (Double) -> Void) async throws -> Toolpath {
        try ctx.generate(op, progress: progress)
    }

    /// Reasons the current toolpaths do not match the job. Shown before export so a failed, stale or
    /// unfinished operation is never silently missing from the G-code.
    var exportIssues: [String] {
        var out: [String] = []
        if generating { out.append("Toolpaths are still being calculated. Wait for them to finish, then export.") }
        let contextStale = makeContextKey(job) != contextKey
        for op in job.operations where op.enabled {
            switch status[op.id] {
            case .failed(let why):
                out.append("\(op.name) failed and is not in the G-code: \(why)")
            case .done where !contextStale && cache[op.id]?.key == opKey(op):
                break
            default:
                if !generating { out.append("\(op.name) has changed since it was calculated. Generate the toolpaths again before exporting.") }
            }
        }
        if let t = job.activeTestCut {
            out.append("Test cut mode is on: \(t.summary). The files are marked TEST and will not finish the part.")
        }
        if job.operations.contains(where: { !$0.enabled }) && !job.operations.isEmpty {
            let off = job.operations.filter { !$0.enabled }.map(\.name).joined(separator: ", ")
            out.append("Switched off and not exported: \(off).")
        }
        return out
    }

    // MARK: Stats

    var machine: MachineProfile { MachineProfile.find(job.machineID) }

    func stats(for id: UUID) -> Toolpath.Stats? {
        guard let tp = toolpaths.first(where: { $0.id == id }) else { return nil }
        return tp.stats(rapidRate: machine.rapidRate, acceleration: machine.acceleration)
    }

    var totalSeconds: Double {
        toolpaths.reduce(0) { $0 + $1.stats(rapidRate: machine.rapidRate, acceleration: machine.acceleration).seconds }
    }

    func postProcessor(profile: MachineProfile? = nil) -> PostProcessor? {
        guard let placed else { return nil }
        return PostProcessor(profile: profile ?? machine, origin: placed.originPoint(job.origin),
                             safeZ: placed.stockTop + job.safeHeight, jobName: document.modelName, stockSize: placed.stockSize,
                             testCut: job.activeTestCut)
    }

    // MARK: View

    func requestView(_ v: ViewPreset) { viewRequest = v }

    // MARK: Simulation

    var totalSimSegments: Int { simRunner?.segmentCount ?? 0 }

    func toggleSimulation() {
        if simMode { stopSimulation() } else { simMode = true; startSimulation() }
    }

    func startSimulation() {
        guard let placed, !toolpaths.isEmpty else { return }
        simMode = true
        let runner = SimRunner(toolpaths: toolpaths, placed: placed)
        simRunner = runner
        simAnalysis = nil
        simPosition = 1
        seekSimulation(to: 1, analyze: true)
    }

    func stopSimulation() {
        simPlaying = false
        playTimer?.invalidate()
        simMode = false
        simRunner = nil
        simStock = nil
        simAnalysis = nil
        simToolPosition = nil
        simVersion += 1
    }

    func seekSimulation(to fraction: Double, analyze: Bool = false) {
        guard let runner = simRunner else { return }
        let target = Int((Double(runner.segmentCount) * max(0, min(1, fraction))).rounded())
        runner.seek(to: target, analyze: analyze || target >= runner.segmentCount) { [weak self] stock, analysis, toolPos in
            guard let self, self.simRunner === runner else { return }
            self.simStock = stock
            if let a = analysis { self.simAnalysis = a }
            self.simToolPosition = toolPos
            self.simVersion += 1
        }
    }

    var simSegmentLimit: Int? {
        guard simMode, let r = simRunner else { return nil }
        return Int((Double(r.segmentCount) * simPosition).rounded())
    }

    func togglePlay() {
        simPlaying.toggle()
        playTimer?.invalidate()
        guard simPlaying else { return }
        if simPosition >= 1 { simPosition = 0 }
        playTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let step = 1.0 / max(60, Double(self.totalSimSegments) / 200) / 3
                self.simPosition = min(1, self.simPosition + max(step, 1.0 / 1800))
                self.seekSimulation(to: self.simPosition)
                if self.simPosition >= 1 { self.simPlaying = false; self.playTimer?.invalidate() }
            }
        }
    }
}

enum ViewPreset: String, CaseIterable, Identifiable {
    case iso, top, front, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

extension CAMCore.Operation {
    static let placeholder = CAMCore.Operation(kind: .roughing, tool: ToolLibrary.starter.tools[0])
}

extension Region {
    static let placeholder = Region(name: "", min: .zero, max: .zero)
}

/// Runs the stock simulation off the main thread, coalescing seek requests.
final class SimRunner: @unchecked Sendable {
    struct Segment { var a: V3; var b: V3; var tool: Tool; var cutting: Bool }
    let segments: [Segment]
    let engraved: [Grid2D]
    let placed: PlacedModel
    private var sim: StockSimulator
    private var index = 0
    private let queue = DispatchQueue(label: "swarf.sim", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (Int, Bool, @MainActor (Grid2D, StockSimulator.Analysis?, (V3, Tool)?) -> Void)?
    private var busy = false

    var segmentCount: Int { segments.count }

    init(toolpaths: [Toolpath], placed: PlacedModel) {
        var segs: [Segment] = []
        for tp in toolpaths {
            let pts = tp.tessellated(maxSegment: 1)
            for i in 1..<max(1, pts.count) {
                segs.append(Segment(a: pts[i - 1].0, b: pts[i].0, tool: tp.tool, cutting: pts[i].1 != .rapid))
            }
        }
        segments = segs
        engraved = toolpaths.compactMap(\.engraveMask)
        self.placed = placed
        sim = StockSimulator(stockSize: placed.stockSize, resolution: StockSimulator.defaultResolution(for: placed.stockSize))
    }

    func seek(to target: Int, analyze: Bool, completion: @escaping @MainActor (Grid2D, StockSimulator.Analysis?, (V3, Tool)?) -> Void) {
        lock.lock()
        pending = (target, analyze, completion)
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let (target, analyze, completion) = pending else { busy = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            if target < index {
                sim = StockSimulator(stockSize: placed.stockSize, resolution: sim.stock.res)
                index = 0
            }
            while index < min(target, segments.count) {
                let s = segments[index]
                if s.cutting { sim.cut(from: s.a, to: s.b, tool: s.tool) }
                index += 1
            }
            let analysis = analyze ? sim.analyze(model: placed, tolerance: 0.1, engraved: engraved) : nil
            let stock = sim.stock
            let toolPos: (V3, Tool)? = index > 0 && index <= segments.count ? (segments[index - 1].b, segments[index - 1].tool) : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(stock, analysis, toolPos) } }
        }
    }
}
