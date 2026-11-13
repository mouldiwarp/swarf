import CAMCore
import Foundation

// swarf-cli <model.stl> [--machine id] [--out dir] [--material id] [--quality draft|normal|fine]
//           [--lay-flat] [--rotate x|y|z:deg ...] [--ops facing,roughing,...] [--simulate]

func usage(_ reason: String? = nil) -> Never {
    if let reason { FileHandle.standardError.write(Data("swarf-cli: \(reason)\n\n".utf8)) }
    print("""
    usage: swarf-cli <model.stl | project.swarf> [options]
      A .swarf project is machined as saved (its operations, regions, stock and origin); options still apply.
      --machine <id>        post-processor (default: workbee-z1plus-rrf); --list-machines to see all
      --material <id>       mdf, plywood, softwood, hardwood, acrylic, hdpe, foam, aluminium
      --quality <q>         draft | normal | fine
      --margin <mm>         stock margin around the model in X and Y (default 5)
      --lay-flat            auto-orient largest flat face down
      --rotate <axis:deg>   rotate model, e.g. x:90 (repeatable)
      --ops <list>          comma list of operations (default: full processing template):
                            facing, pocket, roughing, parallelFinish, waterlineFinish, vcarve, drill, cutout
      --vcarve-source <s>   recesses (default) | silhouette
      --vcarve-depth <mm>   flat-bottom depth limit for V-carving (default: unlimited)
      --out <dir>           output directory (default: current)
      --simulate            run stock simulation and report gouges/leftover
      --png <file>          write a top-view preview (implies --simulate)
      --png-underside <file> write the back as machined on side B, seen after the flip: leftover blue,
                            gouges red, side-B toolpaths cyan (implies --simulate)
      --keepout x0,y0,x1,y1 add a keep-out rectangle in stock coordinates (repeatable)
      --flip [mm]           two-sided job: dowel holes (mm into the spoilboard, default 5), side A, flip
                            about X, side B. With --ops, prefix side-B operations with b:, e.g. b:pocket
      --rest <mm>           after each pocket and 3D roughing, add a rest pass with the starter flat end mill
                            closest to <mm> that cuts only what the larger tool couldn't reach
      --trench <x>          cutouts rough a slot <x> times the tool diameter wide (e.g. 1.5) so chips clear
      --trench-feed <x>     feed of the trench's second pass, the one next to the part, as a multiple (default 1.25)
      --test-cut [c,p,d]    test-cut mode: cutouts c mm deep, pockets and carving p mm, holes d mm
                            (default 8,4,4 for 9 mm MDF); output files are marked _TEST
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.contains("--list-machines") {
    for m in MachineProfile.builtIn { print("\(m.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(m.name)") }
    exit(0)
}
if args.contains("--help") || args.contains("-h") { usage() }
guard var path = args.first, !path.hasPrefix("--") else { usage(args.isEmpty ? nil : "the first argument must be the STL file") }
args.removeFirst()

var job = Job()
var projectJob = false
var jobName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
if path.hasSuffix(".swarf") {
    let dir = URL(fileURLWithPath: path)
    do {
        job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: dir.appendingPathComponent("job.json")))
    } catch { usage("can't read \(dir.lastPathComponent)/job.json: \(error.localizedDescription)") }
    if let n = try? String(contentsOf: dir.appendingPathComponent("name.txt"), encoding: .utf8), !n.isEmpty {
        jobName = n.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    path = dir.appendingPathComponent("model.stl").path
    projectJob = true
}
var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var opsList: [(OperationKind, MachiningSide)]? = nil
var restDiameter: Double? = nil
var trenchFactor: Double? = nil
var trenchFeed: Double? = nil
var simulate = false
var layFlat = false
var pngPath: String? = nil
var pngPaths = true
var undersidePath: String? = nil
var keepOuts: [Region] = []
var flipDepth: Double? = nil
var vSettings = VCarveSettings()
var i = 0
while i < args.count {
    let a = args[i]
    func next() -> String { i += 1; guard i < args.count else { usage("\(a) needs a value") }; return args[i] }
    switch a {
    case "--machine":
        let id = next()
        guard MachineProfile.builtIn.contains(where: { $0.id == id }) else { usage("unknown machine \"\(id)\" (see --list-machines)") }
        job.machineID = id
    case "--material":
        let id = next()
        guard Material.library.contains(where: { $0.id == id }) else {
            usage("unknown material \"\(id)\" (choose from \(Material.library.map(\.id).joined(separator: ", ")))")
        }
        job.stock.materialID = id
    case "--quality":
        let q = next()
        guard let quality = ResolutionQuality(rawValue: q) else { usage("unknown quality \"\(q)\" (draft, normal or fine)") }
        job.quality = quality
    case "--out": outDir = URL(fileURLWithPath: next())
    case "--simulate": simulate = true
    case "--png": pngPath = next(); simulate = true
    case "--png-no-paths": pngPaths = false
    case "--png-underside": undersidePath = next(); simulate = true
    case "--keepout":
        // x0,y0,x1,y1 in stock space
        let v = next().split(separator: ",").compactMap { Double($0) }
        guard v.count == 4, v.allSatisfy(\.isFinite) else { usage("--keepout needs four numbers: x0,y0,x1,y1") }
        keepOuts.append(Region(name: "Keep-out \(keepOuts.count + 1)", min: V2(min(v[0], v[2]), min(v[1], v[3])), max: V2(max(v[0], v[2]), max(v[1], v[3]))))
    case "--test-cut":
        var t = TestCut()
        t.enabled = true
        if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
            let v = next().split(separator: ",").compactMap { Double($0) }
            guard v.count == 3, v.allSatisfy({ $0.isFinite && $0 > 0 }) else { usage("--test-cut takes three depths, e.g. 8,4,4") }
            t.cutoutDepth = v[0]; t.pocketDepth = v[1]; t.drillDepth = v[2]
        }
        job.testCut = t
    case "--flip":
        job.flipSettings.enabled = true
        if i + 1 < args.count, let d = Double(args[i + 1]) {
            guard d.isFinite, d >= 0 else { usage("--flip takes a spoilboard depth in mm, 0 or more") }
            flipDepth = d
            i += 1
        }
    case "--margin":
        guard let m = Double(next()), m.isFinite, m >= 0 else { usage("--margin needs a size in mm, 0 or more") }
        job.stock.marginXY = m
    case "--lay-flat": layFlat = true
    case "--rotate":
        let parts = next().split(separator: ":")
        let axes: [Substring: V3] = ["x": V3(1, 0, 0), "y": V3(0, 1, 0), "z": V3(0, 0, 1)]
        guard parts.count == 2, let axis = axes[parts[0]], let deg = Double(parts[1]), deg.isFinite else {
            usage("--rotate needs an axis and an angle, e.g. x:90")
        }
        job.orientation.rotate(axis: axis, degrees: deg)
    case "--vcarve-source":
        let v = next()
        guard let source = VCarveSource(rawValue: v) else { usage("unknown V-carve source \"\(v)\" (recesses or silhouette)") }
        vSettings.source = source
    case "--vcarve-depth":
        guard let d = Double(next()), d.isFinite, d >= 0 else { usage("--vcarve-depth needs a depth in mm, 0 or more") }
        vSettings.maxDepth = d
    case "--trench":
        guard let f = Double(next()), f.isFinite, CutoutTrench.widthRange.contains(f) else { usage("--trench needs a width of 1.1 to 3 times the tool diameter") }
        trenchFactor = f
    case "--trench-feed":
        guard let f = Double(next()), f.isFinite, CutoutTrench.innerFeedRange.contains(f) else { usage("--trench-feed needs a multiple from 1 to 2") }
        trenchFeed = f
    case "--rest":
        guard let d = Double(next()), d.isFinite, d > 0 else { usage("--rest needs a tool diameter in mm") }
        restDiameter = d
    case "--ops":
        var kinds: [(OperationKind, MachiningSide)] = []
        for item in next().split(separator: ",") {
            let sideB = item.hasPrefix("b:")
            let name = sideB ? item.dropFirst(2) : item
            guard let k = OperationKind(rawValue: String(name)) else { usage("unknown operation \"\(name)\"") }
            kinds.append((k, sideB ? .b : .a))
        }
        guard !kinds.isEmpty else { usage("--ops needs at least one operation") }
        opsList = kinds
    default: usage("unknown option \(a)")
    }
    i += 1
}

do {
    let t0 = Date()
    let mesh = try STL.read(url: URL(fileURLWithPath: path))
    let diag = mesh.diagnostics()
    print("Loaded \(diag.triangleCount) triangles, watertight: \(diag.isWatertight)")
    if layFlat { job.orientation.rotation = Placement.layFlatRotation(mesh.scaled(job.orientation.scale)) }
    let material = Material.named(job.stock.materialID)
    let library = ToolLibrary.starter
    // Create a context once to get traits, then build operations, then the real context.
    let probe = CAMContext(raw: mesh, job: job)
    if let kinds = opsList {
        job.operations = kinds.map { k, side in
            let tool: Tool = {
                switch k {
                case .parallelFinish, .waterlineFinish: return library.closest(kind: .ball, diameter: 6)!
                case .vcarve: return library.closest(kind: .vBit, diameter: 6)!
                default: return library.closest(kind: .flat, diameter: 6)!
                }
            }()
            var op = Operation(kind: k, tool: tool, material: material)
            if k == .vcarve { op.vcarveSettings = vSettings }
            if k == .cutout { op.tabs.enabled = true }
            op.machiningSide = side
            return op
        }
    } else if !projectJob {
        job.operations = JobTemplates.fullProcessing(probe, library: library, material: material)
    }
    if !projectJob || !keepOuts.isEmpty { job.regions = keepOuts }
    if let d = flipDepth {
        for k in job.operations.indices where job.operations[k].kind == .dowelHoles { job.operations[k].dowelSettings.spoilboardDepth = d }
    }
    if let f = trenchFactor {
        for k in job.operations.indices where job.operations[k].kind == .cutout {
            job.operations[k].cutoutTrenchSettings.enabled = true
            job.operations[k].cutoutTrenchSettings.widthFactor = f
            if let x = trenchFeed { job.operations[k].cutoutTrenchSettings.innerFeed = x }
        }
    }
    if let d = restDiameter, let small = library.closest(kind: .flat, diameter: d) {
        var ops: [CAMCore.Operation] = []
        for op in job.operations {
            ops.append(op)
            guard op.enabled, op.kind == .pocket || op.kind == .roughing, op.restFrom == nil, small.diameter < op.tool.diameter else { continue }
            var r = op
            r.id = UUID()
            r.name = op.name + " rest"
            r.tool = small
            r.restFrom = op.tool
            r.cutting = material.apply(small.defaults)
            ops.append(r)
        }
        job.operations = ops
    }
    let ctx = CAMContext(raw: mesh, job: job)
    let s = ctx.placed.stockSize
    print(String(format: "Stock %.1f x %.1f x %.1f mm, grid %d x %d @ %.3f mm", s.x, s.y, s.z, ctx.heights.width, ctx.heights.height, ctx.res))
    let out = await ctx.generateAll()
    for (id, e) in out.errors { print("ERROR \(job.operations.first { $0.id == id }?.name ?? "?"): \(e)") }
    let profile = MachineProfile.find(job.machineID)
    for tp in out.toolpaths {
        let st = tp.stats(rapidRate: profile.rapidRate, acceleration: profile.acceleration)
        print(String(format: "  %-22@ %@  moves %6d  cut %8.0f mm  time %5.1f min", tp.name as NSString, tp.tool.name, tp.moves.count, st.cutLength, st.seconds / 60))
        for w in tp.warnings { print("    ⚠︎ \(w)") }
    }
    let post = PostProcessor(profile: profile, origin: ctx.placed.originPoint(job.origin), safeZ: ctx.safeZ,
                             jobName: jobName, stockSize: s,
                             testCut: job.activeTestCut)
    for w in post.validate(out.toolpaths) { print("  ⚠︎ \(w)") }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    for f in post.process(out.toolpaths) {
        let url = outDir.appendingPathComponent(f.name)
        try f.content.write(to: url, atomically: true, encoding: .utf8)
        print("Wrote \(url.path) (\(f.content.split(separator: "\n").count) lines)")
    }
    if simulate {
        var sim = StockSimulator(stockSize: s, resolution: StockSimulator.defaultResolution(for: s))
        sim.run(out.toolpaths)
        let a = sim.analyze(model: ctx.placed, tolerance: 0.1, engraved: out.toolpaths.compactMap(\.engraveMask))
        print(String(format: "Simulation: removed %.1f cm³, gouge cells %d (max %.3f mm), leftover cells %d (max %.2f mm)",
                     a.removedVolume / 1000, a.gougeCells, a.maxGouge, a.leftoverCells, a.maxLeftover))
        if !a.undersideDeviation.isEmpty { print("  Underside (side B): gouge cells \(a.undersideGougeCells)") }
        for v in StockSimulator.keepOutViolations(out.toolpaths, regions: job.regions, stockTop: ctx.stockTop, stockSize: ctx.placed.stockSize) { print("  ✖︎ \(v)") }
        var images: [(String, TopView.Image)] = []
        if let png = pngPath {
            images.append((png, TopView.render(stock: sim.stock, stockSize: s, analysis: a, toolpaths: pngPaths ? out.toolpaths.filter { $0.side == .a } : [], regions: job.regions)))
        }
        if let png = undersidePath {
            images.append((png, TopView.renderUnderside(grid: sim.stock, stockSize: s, analysis: a, toolpaths: out.toolpaths.filter { $0.side == .b })))
        }
        for (png, img) in images {
            let ppm = URL(fileURLWithPath: png).deletingPathExtension().appendingPathExtension("ppm")
            try img.ppm.write(to: ppm)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p.arguments = ["-s", "format", "png", ppm.path, "--out", png]
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 {
                try? FileManager.default.removeItem(at: ppm)
                print("Preview: \(png)")
            } else {
                print("  ⚠︎ Could not convert the preview to PNG (sips exit \(p.terminationStatus)). The image was left as \(ppm.path)")
            }
        }
    }
    print(String(format: "Done in %.2f s", Date().timeIntervalSince(t0)))
    if !out.errors.isEmpty {
        FileHandle.standardError.write(Data("swarf-cli: \(out.errors.count) operation(s) failed and are missing from the G-code\n".utf8))
        exit(1)
    }
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
