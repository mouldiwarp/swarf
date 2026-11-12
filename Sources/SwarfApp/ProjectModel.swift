import CAMCore
import Combine
import Foundation
import SwiftUI
import simd

enum SidebarItem: Hashable {
    case model, stock, machine
    case region(UUID)
    case operation(UUID)
}

enum InteractionMode: String, CaseIterable, Identifiable {
    case orbit, faceUp, faceDown, drawKeepOut, placeTab, placeDowel
    var id: String { rawValue }
    var label: String {
        switch self {
        case .orbit: return "Navigate"
        case .faceUp: return "Pick Top Face"
        case .faceDown: return "Pick Bottom Face"
        case .drawKeepOut: return "Draw Keep-out"
        case .placeTab: return "Place Tabs"
        case .placeDowel: return "Place Dowel Holes"
        }
    }
    var symbol: String {
        switch self {
        case .orbit: return "rotate.3d"
        case .faceUp: return "arrow.up.square"
        case .faceDown: return "arrow.down.square"
        case .drawKeepOut: return "rectangle.dashed.badge.record"
        case .placeTab: return "pin"
        case .placeDowel: return "circle.circle"
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
    /// Toolpaths as exported: side-B moves are in the machine's coordinates after the flip.
    @Published private(set) var toolpaths: [Toolpath] = [] {
        didSet {
            // For drawing and simulating, side B is shown from below the side-A view of the part.
            let s = placed?.stockSize ?? .zero
            displayToolpaths = toolpaths.map { $0.side == .b ? $0.rolledAboutX(stockSize: s) : $0 }
        }
    }
    /// `toolpaths` in side-A coordinates, for the 3D view and the simulation.
    @Published private(set) var displayToolpaths: [Toolpath] = []
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
    /// A short-lived banner over the 3D view, for things the app changed on the user's behalf.
    @Published var notice: Notice? = nil
    private var noticeTask: Task<Void, Never>?

    struct Notice: Identifiable {
        let id = UUID()
        var text: String
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
    }
    @Published var showExport = false
    @Published var showImporter = false
    @Published var showInspector = true
    @Published var diagnostics: Mesh.Diagnostics? = nil

    // Simulation
    @Published var simMode = false
    @Published private(set) var simStock: Grid2D?
    /// Underside of the simulated stock once side B has cut (side-A coordinates).
    @Published private(set) var simBottom: Grid2D?
    @Published private(set) var simVersion = 0
    @Published private(set) var simAnalysis: StockSimulator.Analysis?
    @Published var simPosition: Double = 1  // 0...1
    @Published var simPlaying = false
    @Published private(set) var simToolPosition: (V3, Tool)?
    private var simRunner: SimRunner?
    private var playTimer: Timer?

    private var context: CAMContext?
    private var contextKey = ""
    /// Side-B context: depends on the side-A context and on the side-A cutouts (slot and tabs to protect).
    private var contextB: CAMContext?
    private var contextBKey = ""
    private var cache: [UUID: (key: String, tp: Toolpath)] = [:]
    private var task: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var lastPlacementKey = ""
    private var generationToken = 0

    var job: Job { document.job }

    init(document: SwarfDocument) {
        self.document = document
        // The export file name doesn't affect toolpaths, so changing it alone skips regeneration.
        document.$job
            .map { j -> Job in var k = j; k.exportName = nil; return k }
            .removeDuplicates()
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
        // A rest pass's larger tool is a copy too: keep its geometry in step, or the pass would follow the old size.
        func syncedRef(_ op: CAMCore.Operation) -> Tool? {
            guard let r = op.restFrom, var t = byID[r.id] else { return nil }
            t.number = r.number
            return t == r ? nil : t
        }
        guard job.operations.contains(where: { synced($0) != nil || syncedRef($0) != nil }) else { return }
        updateJob("Update Tools from Library") { j in
            for i in j.operations.indices {
                if let t = synced(j.operations[i]) { j.operations[i].tool = t }
                if let t = syncedRef(j.operations[i]) { j.operations[i].restFrom = t }
            }
        }
    }

    /// Developer hooks used for automated screenshots: -SwarfAutoProcess YES, -SwarfAutoSimulate YES, -SwarfAutoExport YES,
    /// -SwarfAutoOps vcarve,cutout (add these operations instead of the full-processing template), -SwarfAutoRest YES (then a
    /// rest-clearing pass after the last pocket or roughing),
    /// -SwarfSelectOp N (1-based), -SwarfView top|iso|front|right, -SwarfKeepOut x0,y0,x1,y1 (adds and selects a keep-out box),
    /// -SwarfMargin mm (stock XY margin), -SwarfFlip YES (two-sided job), -SwarfDowelPicks x,y;x,y (hand-placed dowel
    /// holes, stock space), -SwarfDowelHover x,y with -SwarfMode placeDowel (shows the placement preview there).
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
        if d.object(forKey: "SwarfMargin") != nil { updateJob("Stock Margin") { $0.stock.marginXY = d.double(forKey: "SwarfMargin") } }
        if d.bool(forKey: "SwarfFlip") { setFlip(true) }
        if d.bool(forKey: "SwarfAutoSimulate") { pendingAutoSim = true }
        if d.bool(forKey: "SwarfAutoExport") { pendingAutoExport = true }
        if let list = d.string(forKey: "SwarfAutoOps") {
            for k in list.split(separator: ",").compactMap({ OperationKind(rawValue: String($0)) }) { addOperation(k) }
        } else {
            addFullProcessing()
        }
        if d.bool(forKey: "SwarfAutoRest") { addRestClearing() }
        if let s = d.string(forKey: "SwarfDowelPicks") {
            let picks = s.split(separator: ";").compactMap { item -> V2? in
                let v = item.split(separator: ",").compactMap { Double($0) }
                return v.count == 2 ? V2(v[0], v[1]) : nil
            }
            updateJob("Place Dowel Holes") { j in
                for k in j.operations.indices where j.operations[k].kind == .dowelHoles { j.operations[k].dowelSettings.picks = picks }
            }
        }
        if let m = d.string(forKey: "SwarfMode").flatMap(InteractionMode.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.mode = m }
        }
        if let h = d.string(forKey: "SwarfDowelHover")?.split(separator: ",").compactMap({ Double($0) }), h.count == 2 {
            dowelHover = V2(h[0], h[1])
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
        // Dowel holes are always drilled first, while the stock is still where side A will be machined.
        updateJob("Add Operation") { j in if kind == .dowelHoles { j.operations.insert(op, at: 0) } else { j.operations.append(op) } }
        selection = .operation(op.id)
        announceScaling(tool)
    }

    func addFullProcessing() {
        guard let mesh = document.mesh else { return }
        let job = self.job
        let lib = ToolLibraryStore.shared.library
        let ctx = CAMContext(raw: mesh, job: job)
        var ops = JobTemplates.fullProcessing(ctx, library: lib, material: .named(job.stock.materialID))
        if job.operations.contains(where: { $0.kind == .dowelHoles }) { ops.removeAll { $0.kind == .dowelHoles } }
        updateJob("Full Processing") { j in
            j.operations.append(contentsOf: ops)
            if j.activeFlip != nil { Self.sortByStage(&j.operations) }
        }
        if let f = ops.first { selection = .operation(f.id) }
        let m = Material.named(job.stock.materialID)
        if let adj = m.adjustmentSummary, !ops.isEmpty {
            showNotice("Feeds and speeds for these \(ops.count) operations were adjusted for \(m.name): \(adj) of the tool library's MDF values.")
        }
    }

    // MARK: Rest machining

    /// The clearing operation a new rest pass follows: the selected pocket or 3D roughing if there is one, otherwise the
    /// last enabled one.
    var restSourceOperation: CAMCore.Operation? {
        func clears(_ o: CAMCore.Operation) -> Bool { (o.kind == .pocket || o.kind == .roughing) && o.restFrom == nil }
        if let s = selectedOperation, clears(s) { return s }
        return job.operations.last { $0.enabled && clears($0) }
    }

    /// The tool for a rest pass after `ref`: the largest flat end mill in the library clearly smaller than it.
    func restTool(after ref: Tool) -> Tool? {
        let lib = ToolLibraryStore.shared.library.tools
        return (lib.isEmpty ? ToolLibrary.starter.tools : lib)
            .filter { $0.kind == .flat && $0.diameter < ref.diameter - 0.5 }
            .max { $0.diameter < $1.diameter }
    }

    /// Adds a rest-clearing pass right after a pocket or 3D roughing operation (`after`, or `restSourceOperation`): the
    /// same area, depth, side and stock to leave, with a smaller bit that cuts only what the larger one couldn't reach.
    func addRestClearing(after id: UUID? = nil) {
        guard let src = id.flatMap({ i in job.operations.first { $0.id == i } }) ?? restSourceOperation else {
            showNotice("Add a pocket or 3D roughing operation first. Rest clearing cuts what its tool couldn't reach.")
            return
        }
        guard let tool = restTool(after: src.tool) else {
            showNotice("The tool library has no flat end mill smaller than \(src.tool.name). Add one under Edit Tool Library.")
            return
        }
        var op = src
        op.id = UUID()
        op.name = "Rest Clearing"
        op.enabled = true
        op.tool = tool
        op.restFrom = src.tool
        op.cutting = CAMCore.Material.named(job.stock.materialID).apply(tool.defaults)
        updateJob("Add Rest Clearing") { j in
            let i = j.operations.firstIndex { $0.id == src.id }.map { $0 + 1 } ?? j.operations.count
            j.operations.insert(op, at: i)
        }
        selection = .operation(op.id)
        restSuggestion = nil
        announceScaling(tool)
    }

    /// Tools a rest pass for `op` can follow: other operations' tools and library tools larger than its own, nearest
    /// earlier operation first.
    func restReferenceChoices(for op: CAMCore.Operation) -> [Tool] {
        let mine = job.operations.firstIndex { $0.id == op.id } ?? job.operations.count
        let earlier = job.operations.prefix(mine).reversed().filter { $0.kind.supportsRest || $0.kind == .facing }.map(\.tool)
        let later = job.operations.suffix(from: min(mine + 1, job.operations.count)).map(\.tool)
        var seen = Set<UUID>()
        return (earlier + later + ToolLibraryStore.shared.library.tools).filter { t in
            [.flat, .ball, .bullNose].contains(t.kind) && t.diameter > op.tool.diameter + 1e-6 && seen.insert(t.id).inserted
        }
    }

    /// Shown in the simulation bar when a clearing operation leaves material a smaller bit could take out.
    @Published private(set) var restSuggestion: (text: String, opID: UUID)? = nil
    private var restSuggestionTask: Task<Void, Never>?

    /// Looks for the clearing operation with the most material a smaller library bit could still remove.
    func updateRestSuggestion() {
        restSuggestionTask?.cancel()
        restSuggestion = nil
        guard let ctx = context else { return }
        // Operations already followed by a rest pass from their tool, on their side, need no suggestion.
        func followed(_ o: CAMCore.Operation) -> Bool {
            job.operations.contains { $0.restFrom?.id == o.tool.id && $0.machiningSide == o.machiningSide }
        }
        let candidates: [(CAMCore.Operation, Tool)] = job.operations.compactMap { o in
            guard o.enabled, o.kind == .pocket || o.kind == .roughing, o.restFrom == nil, !followed(o),
                  let t = restTool(after: o.tool) else { return nil }
            return (o, t)
        }
        guard !candidates.isEmpty else { return }
        restSuggestionTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> (String, UUID)? in
                var best: (Double, String, UUID)? = nil
                for (o, t) in candidates {
                    if Task.isCancelled { return nil }
                    guard let p = ctx.restPotential(after: o, with: t), p.area >= 5, p.maxThickness >= 0.5 else { continue }
                    if p.area > (best?.0 ?? 0) {
                        best = (p.area, String(format: "%@ leaves about %.0f mm² in corners and slots its Ø%g mm bit can't reach. A Ø%g mm rest pass could clear it.",
                                               o.name, p.area, o.tool.diameter, t.diameter), o.id)
                    }
                }
                return best.map { ($0.1, $0.2) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.restSuggestion = found.map { (text: $0.0, opID: $0.1) }
            self.dumpState()
        }
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

    /// Reorders operations within one step of a two-sided job (the sidebar shows each step as its own list).
    func moveOperations(in stage: FlipStage, from: IndexSet, to: Int) {
        updateJob("Reorder Operations") { j in
            var group = j.operations.filter { $0.flipStage == stage }
            group.move(fromOffsets: from, toOffset: to)
            let rest = j.operations.filter { $0.flipStage != stage }
            j.operations = rest + group
            Self.sortByStage(&j.operations)
        }
    }

    /// Dowel holes, then side A, then side B, keeping the order within each.
    static func sortByStage(_ ops: inout [CAMCore.Operation]) {
        ops = FlipStage.allCases.flatMap { s in ops.filter { $0.flipStage == s } }
    }

    /// Turns two-sided machining on or off. Turning it on adds the dowel-hole step if there isn't one.
    func setFlip(_ on: Bool) {
        let lib = ToolLibraryStore.shared.library
        let tool = lib.closest(kind: .flat, diameter: 6) ?? ToolLibrary.starter.tools[0]
        let material = CAMCore.Material.named(job.stock.materialID)
        updateJob(on ? "Machine Both Sides" : "Machine One Side") { j in
            j.flipSettings.enabled = on
            if on && !j.operations.contains(where: { $0.kind == .dowelHoles }) {
                var d = CAMCore.Operation(kind: .dowelHoles, tool: tool, material: material)
                d.name = "Dowel holes"
                j.operations.insert(d, at: 0)
            }
            if on { Self.sortByStage(&j.operations) }
        }
        if on, let ctx = context, ctx.job.stock == job.stock {
            if let d = job.operations.first(where: { $0.kind == .dowelHoles }), (try? ctx.dowelPositions(d)) == nil {
                showNotice("The stock has no room for automatic dowel holes. Place them by hand (select Dowel holes, then click in the waste), or increase the XY margin.")
            }
        }
    }

    /// Changes which face an operation machines, keeping the list in step order.
    func setSide(_ side: MachiningSide, for id: UUID) {
        updateJob("Change Side") { j in
            guard let i = j.operations.firstIndex(where: { $0.id == id }) else { return }
            j.operations[i].machiningSide = side
            Self.sortByStage(&j.operations)
        }
    }

    func showNotice(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        notice = Notice(text: text, actionTitle: actionTitle, action: action)
        noticeTask?.cancel()
        // A notice with a button stays until dismissed; a plain one fades after a while.
        guard action == nil else { return }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    /// Tells the user when an operation's feeds differ from the tool library because of the stock material.
    func announceScaling(_ tool: Tool) {
        let m = Material.named(job.stock.materialID)
        guard m.adjustmentSummary != nil else { return }
        let a = tool.defaults, b = m.apply(a)
        func n(_ v: Double) -> String { String(format: "%g", v) }
        var parts: [String] = []
        if a.rpm != b.rpm { parts.append("spindle \(n(a.rpm)) → \(n(b.rpm)) RPM") }
        if a.feed != b.feed { parts.append("feed \(n(a.feed)) → \(n(b.feed)) mm/min") }
        if a.plunge != b.plunge { parts.append("plunge \(n(a.plunge)) → \(n(b.plunge)) mm/min") }
        if a.stepdown != b.stepdown { parts.append("stepdown \(n(a.stepdown)) → \(n(b.stepdown)) mm") }
        guard !parts.isEmpty else { return }
        showNotice("Feeds and speeds for T\(tool.number) were adjusted for \(m.name): " + parts.joined(separator: ", ")
                   + ". The tool library's values are for MDF.")
    }

    /// Changes the stock material. Existing operations keep their feeds, so offer to rescale them.
    func setMaterial(_ id: String) {
        guard id != job.stock.materialID else { return }
        updateJob("Material") { $0.stock.materialID = id }
        guard !job.operations.isEmpty else { return }
        let m = Material.named(id)
        showNotice("Stock material is now \(m.name). Existing operations keep their current feeds and speeds.",
                   actionTitle: "Rescale All for \(m.name)") { [weak self] in self?.rescaleAllOperations() }
    }

    func rescaleAllOperations() {
        updateJob("Rescale Feeds") { j in
            let m = Material.named(j.stock.materialID)
            for i in j.operations.indices { Self.resetCutting(&j.operations[i], tool: j.operations[i].tool, material: m) }
        }
        let m = Material.named(job.stock.materialID)
        showNotice("Feeds and speeds for all \(job.operations.count) operations were reset from the tool library"
                   + (m.adjustmentSummary.map { " and adjusted for \(m.name): \($0)." } ?? "."))
    }

    private static func resetCutting(_ op: inout CAMCore.Operation, tool: Tool, material: CAMCore.Material) {
        let stepover = op.cutting.stepoverPercent
        op.cutting = material.apply(tool.defaults)
        if op.kind != .facing { op.cutting.stepoverPercent = op.kind == .parallelFinish ? stepover : tool.defaults.stepoverPercent }
    }

    func setTool(_ tool: Tool, for id: UUID, resetCutting: Bool) {
        if resetCutting { announceScaling(tool) }
        updateJob("Change Tool") { j in
            guard let i = j.operations.firstIndex(where: { $0.id == id }) else { return }
            j.operations[i].tool = tool
            if resetCutting { Self.resetCutting(&j.operations[i], tool: tool, material: .named(j.stock.materialID)) }
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

    // MARK: Dowel holes

    /// Where the mouse is while placing dowel holes (stock space), for the green/red preview.
    @Published var dowelHover: V2? = nil

    var dowelOperation: CAMCore.Operation? {
        if let op = selectedOperation, op.kind == .dowelHoles { return op }
        return job.operations.first { $0.kind == .dowelHoles }
    }

    /// The hole at `p` and its mirror, each with the reason it can't be drilled (nil = fine).
    func dowelPreview(at p: V2) -> [(V2, String?)] {
        guard let ctx = context, let op = dowelOperation, job.activeFlip != nil else { return [] }
        return ctx.dowelHoles(picks: [p]).map { ($0, ctx.dowelProblem(at: $0, op: op, cutouts: job.operations)) }
    }

    /// Holes to mark in the 3D view: the placed ones (red if unusable), or the automatic ones.
    func dowelMarkers() -> [(V2, Bool)] {
        guard let ctx = context, let op = dowelOperation, job.activeFlip != nil, op.enabled else { return [] }
        let picks = op.dowelSettings.picks
        if !picks.isEmpty {
            return ctx.dowelHoles(picks: picks).map { ($0, ctx.dowelProblem(at: $0, op: op, cutouts: job.operations) == nil) }
        }
        return ((try? ctx.dowelPositions(op)) ?? []).map { ($0, true) }
    }

    /// A click while placing dowel holes: on an existing hole it removes that pair, elsewhere it adds a pair if
    /// both holes clear the part and the stock edges.
    func clickDowel(at p: V2) {
        guard let ctx = context, let op = dowelOperation else { return }
        let picks = op.dowelSettings.picks
        if let i = picks.firstIndex(where: { q in ctx.dowelHoles(picks: [q]).contains { simd_distance($0, p) < max(4, op.tool.diameter) } }) {
            updateJob("Remove Dowel Holes") { j in
                if let k = j.operations.firstIndex(where: { $0.id == op.id }) { j.operations[k].dowelSettings.picks.remove(at: i) }
            }
            return
        }
        let bad = dowelPreview(at: p).compactMap { h, why in why.map { String(format: "X%.0f Y%.0f is %@", h.x, h.y, $0) } }
        if !bad.isEmpty {
            showNotice("Can't put a dowel hole there: " + bad.joined(separator: "; ") + ".")
            return
        }
        updateJob("Place Dowel Holes") { j in
            if let k = j.operations.firstIndex(where: { $0.id == op.id }) { j.operations[k].dowelSettings.picks.append(p) }
        }
    }

    func clearDowelPicks() {
        guard let op = dowelOperation else { return }
        updateJob("Automatic Dowel Holes") { j in
            if let k = j.operations.firstIndex(where: { $0.id == op.id }) { j.operations[k].dowelSettings.picks = [] }
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
                             (try? enc.encode(j.origin)) ?? Data(), (try? enc.encode(j.regions)) ?? Data(), (try? enc.encode(j.activeTestCut)) ?? Data(), (try? enc.encode(j.activeFlip)) ?? Data(), Data("\(j.quality)|\(j.safeHeight)|\(Int(ceil(max(8, maxTool + 4) / 4)))".utf8),
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
        let own = String(decoding: (try? enc.encode(o)) ?? Data(), as: UTF8.self) + contextKey
        return op.machiningSide == .b && op.kind != .dowelHoles ? own + "#B" + Self.cutoutsKey(job) : own
    }

    /// Side-A cutouts, which decide what side B must leave (the frame and tabs).
    static func cutoutsKey(_ j: Job) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        // Only what decides the slot and the tabs: feeds and names don't matter to side B.
        return j.operations.filter { $0.enabled && $0.kind == .cutout && $0.machiningSide == .a }.map { c in
            [(try? enc.encode(c.tool)) ?? Data(), (try? enc.encode(c.tabs)) ?? Data(), (try? enc.encode(c.cutoutFinish)) ?? Data(),
             Data("\(c.stockToLeaveXY)|\(c.cutHoles)|\(c.direction)".utf8)].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "|")
        }.joined(separator: "#")
    }

    /// Recalculates every toolpath from scratch: discards cached toolpaths and the prepared model geometry.
    func generateNow() {
        cache = [:]
        context = nil
        contextKey = ""
        contextB = nil
        contextBKey = ""
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
            contextB = nil
        }
        guard let ctx = context else { return }
        if j.activeFlip != nil, j.operations.contains(where: { $0.enabled && $0.machiningSide == .b && $0.kind != .dowelHoles }) {
            let bKey = key + "#" + Self.cutoutsKey(j)
            if contextB == nil || bKey != contextBKey {
                let cuts = j.operations
                contextB = await Task.detached(priority: .userInitiated) { ctx.makeSideB(cutouts: cuts) }.value
                if Task.isCancelled { return }
                contextBKey = bKey
            }
        }
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
                let useB = op.machiningSide == .b && op.kind != .dowelHoles && j.activeFlip != nil
                let tp = try await Self.generate(ctx: useB ? (contextB ?? ctx) : ctx, op: op) { [weak self] p in
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
        if j.activeFlip != nil { out = FlipStage.allCases.flatMap { s in out.filter { $0.flipStage == s } } }
        toolpaths = out
        toolpathVersion += 1
        if simMode || pendingAutoSim { pendingAutoSim = false; startSimulation() }
        if pendingAutoExport { pendingAutoExport = false; showExport = true }
        dumpState()
    }

    /// Developer hook for checks without a screen: -SwarfDumpState <file> writes the operations, their toolpaths and
    /// warnings, the simulation result and any rest-machining suggestion each time they change.
    func dumpState() {
        guard let path = UserDefaults.standard.string(forKey: "SwarfDumpState") else { return }
        var lines: [String] = []
        for op in job.operations {
            let tp = toolpaths.first { $0.id == op.id }
            lines.append("op \(op.name) | \(op.kind.rawValue) | tool \(op.tool.name) | rest \(op.restFrom?.name ?? "-") | moves \(tp?.moves.count ?? -1)")
            for w in tp?.warnings ?? [] { lines.append("  warning \(w)") }
        }
        if let a = simAnalysis { lines.append("sim gouges \(a.gougeCells) leftover \(a.leftoverCells)") }
        if let r = restSuggestion { lines.append("suggestion \(r.text)") }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
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
                if !generating { out.append("\(op.name) has changed since it was calculated. Click Recalculate All (⌘G) before exporting.") }
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
        var post = PostProcessor(profile: profile ?? machine, origin: placed.originPoint(job.origin),
                                 safeZ: placed.stockTop + job.safeHeight, jobName: document.modelName, stockSize: placed.stockSize,
                                 testCut: job.activeTestCut)
        if let n = job.exportName, !n.trimmingCharacters(in: .whitespaces).isEmpty { post.fileName = n }
        return post
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
        let runner = SimRunner(toolpaths: displayToolpaths, placed: placed)
        simRunner = runner
        simAnalysis = nil
        simPosition = 1
        seekSimulation(to: 1, analyze: true)
    }

    func stopSimulation() {
        restSuggestionTask?.cancel()
        restSuggestion = nil
        simPlaying = false
        playTimer?.invalidate()
        simMode = false
        simRunner = nil
        simStock = nil
        simBottom = nil
        simAnalysis = nil
        simToolPosition = nil
        simVersion += 1
    }

    func seekSimulation(to fraction: Double, analyze: Bool = false) {
        guard let runner = simRunner else { return }
        let target = Int((Double(runner.segmentCount) * max(0, min(1, fraction))).rounded())
        runner.seek(to: target, analyze: analyze || target >= runner.segmentCount) { [weak self] stock, bottom, analysis, toolPos in
            guard let self, self.simRunner === runner else { return }
            self.simStock = stock
            self.simBottom = bottom
            if let a = analysis { self.simAnalysis = a; self.updateRestSuggestion(); self.dumpState() }
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
    case iso, top, front, right, bottom
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
    struct Segment { var a: V3; var b: V3; var tool: Tool; var cutting: Bool; var fromBelow: Bool }
    let segments: [Segment]
    let engraved: [Grid2D]
    let placed: PlacedModel
    private var sim: StockSimulator
    private var index = 0
    private let queue = DispatchQueue(label: "swarf.sim", qos: .userInitiated)
    private let lock = NSLock()
    typealias Completion = @MainActor (Grid2D, Grid2D?, StockSimulator.Analysis?, (V3, Tool)?) -> Void
    private var pending: (Int, Bool, Completion)?
    private var busy = false

    var segmentCount: Int { segments.count }

    init(toolpaths: [Toolpath], placed: PlacedModel) {
        var segs: [Segment] = []
        for tp in toolpaths {
            let pts = tp.tessellated(maxSegment: 1)
            for i in 1..<max(1, pts.count) {
                segs.append(Segment(a: pts[i - 1].0, b: pts[i].0, tool: tp.tool, cutting: pts[i].1 != .rapid, fromBelow: tp.side == .b))
            }
        }
        segments = segs
        engraved = toolpaths.compactMap(\.engraveMask)
        self.placed = placed
        sim = StockSimulator(stockSize: placed.stockSize, resolution: StockSimulator.defaultResolution(for: placed.stockSize))
    }

    func seek(to target: Int, analyze: Bool, completion: @escaping Completion) {
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
                if s.cutting { sim.cut(from: s.a, to: s.b, tool: s.tool, fromBelow: s.fromBelow) }
                index += 1
            }
            let analysis = analyze ? sim.analyze(model: placed, tolerance: 0.1, engraved: engraved) : nil
            let stock = sim.stock
            let bottom = sim.bottom
            let toolPos: (V3, Tool)? = index > 0 && index <= segments.count ? (segments[index - 1].b, segments[index - 1].tool) : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(stock, bottom, analysis, toolPos) } }
        }
    }
}
