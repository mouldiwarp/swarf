import CAMCore
import Foundation

// swarf-cli <model.stl> [--machine id] [--out dir] [--material id] [--quality draft|normal|fine]
//           [--lay-flat] [--rotate x|y|z:deg ...] [--ops facing,roughing,...] [--simulate]

func usage(_ reason: String? = nil) -> Never {
    if let reason { FileHandle.standardError.write(Data("swarf-cli: \(reason)\n\n".utf8)) }
    print("""
    usage: swarf-cli <model.stl> [options]
      --machine <id>        post-processor (default: workbee-z1plus-rrf); --list-machines to see all
      --material <id>       mdf, plywood, softwood, hardwood, acrylic, hdpe, foam, aluminium
      --quality <q>         draft | normal | fine
      --lay-flat            auto-orient largest flat face down
      --rotate <axis:deg>   rotate model, e.g. x:90 (repeatable)
      --ops <list>          comma list of operations (default: full processing template):
                            facing, pocket, roughing, parallelFinish, waterlineFinish, vcarve, drill, cutout
      --vcarve-source <s>   recesses (default) | silhouette
      --vcarve-depth <mm>   flat-bottom depth limit for V-carving (default: unlimited)
      --out <dir>           output directory (default: current)
      --simulate            run stock simulation and report gouges/leftover
      --png <file>          write a top-view preview (implies --simulate)
      --keepout x0,y0,x1,y1 add a keep-out rectangle in stock coordinates (repeatable)
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.contains("--list-machines") {
    for m in MachineProfile.builtIn { print("\(m.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(m.name)") }
    exit(0)
}
if args.contains("--help") || args.contains("-h") { usage() }
guard let path = args.first, !path.hasPrefix("--") else { usage(args.isEmpty ? nil : "the first argument must be the STL file") }
args.removeFirst()

var job = Job()
var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var opsList: [OperationKind]? = nil
var simulate = false
var layFlat = false
var pngPath: String? = nil
var pngPaths = true
var keepOuts: [Region] = []
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
    case "--keepout":
        // x0,y0,x1,y1 in stock space
        let v = next().split(separator: ",").compactMap { Double($0) }
        guard v.count == 4, v.allSatisfy(\.isFinite) else { usage("--keepout needs four numbers: x0,y0,x1,y1") }
        keepOuts.append(Region(name: "Keep-out \(keepOuts.count + 1)", min: V2(min(v[0], v[2]), min(v[1], v[3])), max: V2(max(v[0], v[2]), max(v[1], v[3]))))
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
    case "--ops":
        var kinds: [OperationKind] = []
        for name in next().split(separator: ",") {
            guard let k = OperationKind(rawValue: String(name)) else { usage("unknown operation \"\(name)\"") }
            kinds.append(k)
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
        job.operations = kinds.map { k in
            let tool: Tool = {
                switch k {
                case .parallelFinish, .waterlineFinish: return library.closest(kind: .ball, diameter: 6)!
                case .vcarve: return library.closest(kind: .vBit, diameter: 6)!
                default: return library.closest(kind: .flat, diameter: 6)!
                }
            }()
            var op = Operation(kind: k, tool: tool, material: material)
            if k == .vcarve { op.vcarveSettings = vSettings }
            return op
        }
    } else {
        job.operations = JobTemplates.fullProcessing(probe, library: library, material: material)
    }
    job.regions = keepOuts
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
                             jobName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, stockSize: s)
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
        for v in StockSimulator.keepOutViolations(out.toolpaths, regions: job.regions, stockTop: ctx.stockTop) { print("  ✖︎ \(v)") }
        if let png = pngPath {
            let img = TopView.render(stock: sim.stock, stockSize: s, analysis: a, toolpaths: pngPaths ? out.toolpaths : [], regions: job.regions)
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
