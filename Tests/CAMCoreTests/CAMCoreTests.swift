import Foundation
import Testing
import simd
@testable import CAMCore

@Suite struct GeometryTests {
    @Test func stlBinaryRoundTrip() throws {
        let box = STL.box(V3(10, 20, 30))
        let data = STL.binaryData(box)
        let back = try STL.parse(data)
        #expect(back.triangles.count == 12)
        #expect(simd_distance(back.bounds.max, V3(10, 20, 30)) < 1e-5)
        #expect(back.diagnostics().isWatertight)
    }

    @Test func stlASCII() throws {
        let text = """
        solid t
        facet normal 0 0 1
         outer loop
          vertex 0 0 0
          vertex 1 0 0
          vertex 0 1 0
         endloop
        endfacet
        endsolid t
        """
        let m = try STL.parse(Data(text.utf8))
        #expect(m.triangles.count == 1)
        #expect(m.triangles[0].b == SIMD3<Float>(1, 0, 0))
    }

    @Test func faceDownPutsNormalOnBed() {
        var o = Orientation()
        let n = simd_normalize(V3(1, 1, 0))
        o.faceDown(normal: n)
        let r = o.rotation.apply(n)
        #expect(simd_distance(r, V3(0, 0, -1)) < 1e-9)
        o = Orientation()
        o.faceUp(normal: V3(0, -1, 0))
        #expect(simd_distance(o.rotation.apply(V3(0, -1, 0)), V3(0, 0, 1)) < 1e-9)
    }

    @Test func ninetyDegreeRotationsStayExact() {
        var o = Orientation()
        for _ in 0..<4 { o.rotate(axis: V3(1, 0, 0), degrees: 90) }
        #expect(o.rotation == .identity)
    }

    @Test func layFlatPicksLargestFace() {
        // A 50x50x2 plate standing on its edge should be laid flat.
        let plate = STL.box(V3(2, 50, 50))
        let rot = Placement.layFlatRotation(plate)
        let b = plate.transformed(rotation: rot).bounds.size
        #expect(abs(b.z - 2) < 1e-4)
    }

    @Test func placementSitsModelInStock() {
        var stock = StockSetup()
        stock.marginXY = 5
        let p = PlacedModel(raw: STL.box(V3(10, 10, 4), at: V3(-100, 50, 7)), orientation: Orientation(), stock: stock)
        #expect(abs(p.stockSize.x - 20) < 1e-6)
        #expect(abs(p.modelBounds.min.x - 5) < 1e-4)
        #expect(abs(p.modelBounds.min.z) < 1e-4)
        #expect(abs(p.modelBounds.max.z - p.stockTop) < 1e-4)
        #expect(p.originPoint(.workbeeDefault) == V3(0, 0, 4))
    }

    @Test func distanceTransformMatchesBruteForce() {
        let W = 23, H = 17
        let features: Set<Int> = [5, 100, 200, 390]
        let d = DistanceTransform.distance(width: W, height: H, res: 0.5) { features.contains($0) }
        for i in 0..<(W * H) {
            let x = i % W, y = i / W
            let best = features.map { f -> Double in
                let fx = f % W, fy = f / W
                return (Double((fx - x) * (fx - x) + (fy - y) * (fy - y))).squareRoot() * 0.5
            }.min()!
            #expect(abs(Double(d[i]) - best) < 1e-4)
        }
    }

    @Test func circleContourAreaAndOrientation() {
        var g = Grid2D(covering: V2(-12, -12), V2(12, 12), res: 0.1, fill: 0)
        for y in 0..<g.height { for x in 0..<g.width { g[x, y] = Float(10 - simd_length(g.world(x, y))) } }
        let loops = Contours.isolines(g, levels: [0])[0]
        #expect(loops.count == 1)
        let area = loops[0].signedArea
        #expect(area > 0)  // inside (value > iso) on the left => CCW
        #expect(abs(area - .pi * 100) / (.pi * 100) < 0.002)
    }

    @Test func ballDilationOfSpikeIsSphere() {
        var g = Grid2D(covering: V2(-5, -5), V2(5, 5), res: 0.1, fill: -100)
        g[50, 50] = 0
        let ball = Tool(name: "b", kind: .ball, diameter: 6, defaults: CuttingData(rpm: 1, feed: 1, plunge: 1, stepdown: 1, stepoverPercent: 10))
        for gpu in [false, true] {
            let t = ToolDilation.dilate(g, tool: ball, useGPU: gpu)
            #expect(abs(t[50, 50] - 0) < 1e-5)
            // 2 mm away the tip must sit r - sqrt(r^2 - d^2) lower.
            let expected = Float(-(3 - (9.0 - 4).squareRoot()))
            #expect(abs(t[70, 50] - expected) < 1e-4)
        }
    }
}

@Suite struct OperationTests {
    func material() -> Material { .named("mdf") }
    let lib = ToolLibrary.starter

    func pocketPlate() -> Mesh {
        STL.merge([
            STL.box(V3(40, 30, 6)),
            STL.box(V3(40, 8, 4), at: V3(0, 0, 6)), STL.box(V3(40, 8, 4), at: V3(0, 22, 6)),
            STL.box(V3(8, 14, 4), at: V3(0, 8, 6)), STL.box(V3(8, 14, 4), at: V3(32, 8, 6)),
        ])
    }

    @Test func pocketClearsWithoutGouges() async throws {
        var job = Job()
        job.quality = .draft
        job.operations = [Operation(kind: .pocket, tool: lib.closest(kind: .flat, diameter: 3.175)!, material: material())]
        let ctx = CAMContext(raw: pocketPlate(), job: job)
        let out = await ctx.generateAll()
        #expect(out.errors.isEmpty)
        let tp = try #require(out.toolpaths.first)
        // Floor of the pocket is at z = 6.
        let minZ = tp.moves.map(\.to.z).min()!
        #expect(abs(minZ - 6) < 1e-3)
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(out.toolpaths)
        let a = sim.analyze(model: ctx.placed, tolerance: 0.1)
        #expect(a.gougeCells == 0)
        // Only the tool-radius corners may remain.
        #expect(a.leftoverCells < 40)
    }

    @Test func cutoutHasTabsAtHeight() async throws {
        var job = Job()
        job.quality = .draft
        var op = Operation(kind: .cutout, tool: lib.closest(kind: .flat, diameter: 3.175)!, material: material())
        op.tabs.height = 2.5
        op.tabs.countPerLoop = 3
        job.operations = [op]
        let ctx = CAMContext(raw: STL.box(V3(40, 30, 6)), job: job)
        let out = await ctx.generateAll()
        let tp = try #require(out.toolpaths.first)
        let zs = tp.moves.map(\.to.z)
        #expect(abs(zs.min()! - (-op.throughDepth)) < 1e-6)
        #expect(zs.contains { abs($0 - 2.5) < 1e-6 })
        // Tool centre must stay one radius outside the part.
        for m in tp.moves where m.to.z < ctx.stockTop {
            let p = m.to.xy - ctx.placed.modelBounds.min.xy
            let inside = p.x > 0.5 && p.y > 0.5 && p.x < 39.5 && p.y < 29.5
            #expect(!inside)
        }
    }

    @Test func keepOutIsRespectedByRoughingAndFinishing() async throws {
        var job = Job()
        job.quality = .draft
        let mesh = STL.merge([STL.box(V3(60, 60, 3)), STL.dome(radius: 20, segments: 24, rings: 12, center: V2(30, 30)).translated(V3(0, 0, 3))])
        let probe = CAMContext(raw: mesh, job: job)
        let c = probe.placed.modelBounds.center.xy
        job.regions = [Region(name: "Logo", min: c + V2(-5, -5), max: c + V2(5, 5))]
        job.operations = [
            Operation(kind: .roughing, tool: lib.closest(kind: .flat, diameter: 6)!, material: material()),
            Operation(kind: .parallelFinish, tool: lib.closest(kind: .ball, diameter: 3)!, material: material()),
            Operation(kind: .waterlineFinish, tool: lib.closest(kind: .ball, diameter: 3)!, material: material()),
        ]
        let ctx = CAMContext(raw: mesh, job: job)
        let out = await ctx.generateAll()
        #expect(out.toolpaths.count == 3)
        #expect(StockSimulator.keepOutViolations(out.toolpaths, regions: job.regions).isEmpty)
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: StockSimulator.defaultResolution(for: ctx.placed.stockSize))
        sim.run(out.toolpaths)
        let an = sim.analyze(model: ctx.placed, tolerance: 0.15)
        #expect(an.gougeCells == 0)
    }

    @Test func fullProcessingTemplateChoosesStrategies() {
        let ctx = CAMContext(raw: STL.merge([STL.box(V3(50, 50, 4)), STL.dome(radius: 15, center: V2(25, 25)).translated(V3(0, 0, 4))]), job: Job())
        let ops = JobTemplates.fullProcessing(ctx, library: lib, material: material())
        #expect(ops.map(\.kind) == [.roughing, .parallelFinish, .waterlineFinish, .cutout])
    }
}

@Suite struct VCarveTests {
    let lib = ToolLibrary.starter
    var vbit90: Tool { lib.tools.first { $0.kind == .vBit && $0.vAngle == 90 }! }

    /// An "L" of 4 mm wide strokes, 2 mm tall, standing on thicker stock.
    func lJob(maxDepth: Double = 0) -> (Mesh, Job) {
        let mesh = STL.merge([STL.box(V3(40, 4, 2)), STL.box(V3(4, 24, 2))])
        var job = Job()
        job.stock.extraBottom = 10
        var op = Operation(kind: .vcarve, tool: vbit90, material: .named("mdf"))
        op.vcarveSettings.source = .silhouette
        op.vcarveSettings.maxDepth = maxDepth
        op.cutting.stepdown = 5
        job.operations = [op]
        return (mesh, job)
    }

    /// Analytic distance from a point (model space) to the L's outline: >0 inside, <0 outside.
    func signedEdgeDistance(_ p: V2) -> Double {
        func rect(_ lo: V2, _ hi: V2) -> Double {
            let dx = max(lo.x - p.x, p.x - hi.x), dy = max(lo.y - p.y, p.y - hi.y)
            if dx <= 0 && dy <= 0 { return -max(dx, dy) }
            return -(simd_length(V2(max(dx, 0), max(dy, 0))))
        }
        return max(rect(V2(0, 0), V2(40, 4)), rect(V2(0, 0), V2(4, 24)))
    }

    @Test func vcarveFollowsTheOutlineExactly() async throws {
        let (mesh, job) = lJob()
        let ctx = CAMContext(raw: mesh, job: job)
        let out = await ctx.generateAll()
        #expect(out.errors.isEmpty)
        let tp = try #require(out.toolpaths.first)
        let top = ctx.stockTop
        // 4 mm stroke with a 90° bit bottoms out 2 mm deep.
        let deepest = top - tp.moves.map(\.to.z).min()!
        #expect(deepest > 1.8 && deepest < 2.02, "deepest \(deepest) res \(ctx.res)")
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run(out.toolpaths)
        let off = ctx.placed.modelBounds.min.xy
        var overcut = 0, missed = 0, wrongDepth = 0
        for y in 0..<sim.stock.height {
            for x in 0..<sim.stock.width {
                let p = sim.stock.world(x, y)
                let d = signedEdgeDistance(p - off)
                let cut = top - Double(sim.stock[x, y])
                if d < -0.15 && cut > 0.02 { overcut += 1 }
                if d > 0.3 && cut < 0.1 { missed += 1 }
                // in the straight part of the horizontal bar the groove is a clean 90° V
                let q = p - off
                if q.x > 10 && q.x < 36 && d > 0.2 && abs(cut - d) > 0.15 { wrongDepth += 1 }
            }
        }
        #expect(overcut == 0)
        #expect(missed == 0)
        #expect(wrongDepth == 0)
        let a = sim.analyze(model: ctx.placed, tolerance: 0.1, engraved: out.toolpaths.compactMap(\.engraveMask))
        #expect(a.gougeCells == 0)
    }

    @Test func vcarveDepthLimitGivesFlatBottom() async throws {
        let (mesh, job) = lJob(maxDepth: 0.8)
        let ctx = CAMContext(raw: mesh, job: job)
        let out = await ctx.generateAll()
        let tp = try #require(out.toolpaths.first)
        let top = ctx.stockTop
        #expect(abs((top - tp.moves.map(\.to.z).min()!) - 0.8) < 1e-6)
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run(out.toolpaths)
        let off = ctx.placed.modelBounds.min.xy
        var overcut = 0, shallow = 0
        for y in 0..<sim.stock.height {
            for x in 0..<sim.stock.width {
                let p = sim.stock.world(x, y)
                let d = signedEdgeDistance(p - off)
                let cut = top - Double(sim.stock[x, y])
                if d < -0.15 && cut > 0.02 { overcut += 1 }
                if d > 1.0 && cut < 0.8 - 0.35 { shallow += 1 }  // flat floor, small ridges allowed
            }
        }
        #expect(overcut == 0)
        #expect(shallow == 0)
    }

    @Test func vcarveEngravesRecessesOnly() async throws {
        // 60x30 plaque, 6 mm tall, with a 30x4 slot sunk 2 mm into its top.
        let mesh = STL.merge([
            STL.box(V3(60, 30, 4)),
            STL.box(V3(60, 13, 2), at: V3(0, 0, 4)), STL.box(V3(60, 13, 2), at: V3(0, 17, 4)),
            STL.box(V3(10, 4, 2), at: V3(0, 13, 4)), STL.box(V3(20, 4, 2), at: V3(40, 13, 4)),
        ])
        var job = Job()
        var op = Operation(kind: .vcarve, tool: vbit90, material: .named("mdf"))
        op.cutting.stepdown = 1
        job.operations = [op]
        let ctx = CAMContext(raw: mesh, job: job)
        let out = await ctx.generateAll()
        #expect(out.errors.isEmpty)
        let tp = try #require(out.toolpaths.first)
        #expect(Set(tp.moves.filter { $0.kind != .rapid }.map { ($0.to.z * 1000).rounded() }).count > 3)  // multiple depth passes
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run(out.toolpaths)
        let a = sim.analyze(model: ctx.placed, tolerance: 0.1, engraved: out.toolpaths.compactMap(\.engraveMask))
        #expect(a.gougeCells == 0)
        let off = ctx.placed.modelBounds.min.xy
        var outside = 0
        for y in 0..<sim.stock.height {
            for x in 0..<sim.stock.width {
                let q = sim.stock.world(x, y) - off
                let inSlot = q.x > 10 - 0.15 && q.x < 40 + 0.15 && q.y > 13 - 0.15 && q.y < 17 + 0.15
                if !inSlot && Double(sim.stock[x, y]) < ctx.stockTop - 0.02 { outside += 1 }
            }
        }
        #expect(outside == 0)
        // Without a V-bit the operation explains itself.
        var bad = job
        bad.operations[0].tool = lib.closest(kind: .flat, diameter: 6)!
        let r = await CAMContext(raw: mesh, job: bad).generateAll()
        #expect(r.errors.count == 1)
    }

    @Test func keepOutCheckUsesEffectiveVBitRadius() {
        var tool = vbit90
        tool.tipDiameter = 0
        #expect(abs(tool.cuttingRadius(depth: 0.5) - 0.5) < 1e-9)
        #expect(abs(tool.cuttingRadius(depth: 10) - tool.radius) < 1e-9)
    }
}

@Suite struct PassLevelTests {
    @Test func cutoutUsesEvenStepdowns() async throws {
        var job = Job()
        job.quality = .draft
        var op = Operation(kind: .cutout, tool: ToolLibrary.starter.tools[0], material: .named("mdf"))
        op.tabs.enabled = false
        job.operations = [op]
        let ctx = CAMContext(raw: STL.box(V3(40, 30, 18)), job: job)
        let tp = try #require(await ctx.generateAll().toolpaths.first)
        let zs = Set(tp.moves.filter { $0.kind == .feed }.map { ($0.to.z * 1000).rounded() / 1000 }).sorted(by: >)
        var prev = 18.0
        for z in zs { #expect(prev - z <= op.cutting.stepdown + 1e-6); prev = z }
    }

    @Test func toolJSONWithOldFluteFieldsStillDecodes() throws {
        let data = try JSONEncoder().encode(ToolLibrary.starter.tools[0])
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["flute"] = "compression"; obj["upcutLen"] = 6
        let t = try JSONDecoder().decode(Tool.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(t.fluteLength == 50)
    }
}

@Suite struct ProjectTests {
    @Test func jobRoundTripsThroughJSON() throws {
        var job = Job()
        job.orientation.rotate(axis: V3(1, 0, 0), degrees: 90)
        job.regions = [Region(name: "Logo", min: V2(1, 2), max: V2(10, 20))]
        job.regions[0].protectBelowZ = 4
        var op = Operation(kind: .cutout, tool: ToolLibrary.starter.tools[1])
        op.tabs.manualPositions = [V2(5, 5)]
        op.regionIDs = [job.regions[0].id]
        job.operations = [op, Operation(kind: .parallelFinish, tool: ToolLibrary.starter.tools[4])]
        let data = try JSONEncoder().encode(job)
        let back = try JSONDecoder().decode(Job.self, from: data)
        #expect(back == job)
    }

    @Test func machineProfilesHaveUniqueIDs() {
        let ids = MachineProfile.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(MachineProfile.find("does-not-exist").id == MachineProfile.workbeeRRF.id)
    }
}

@Suite struct PostTests {
    func simpleToolpath() -> Toolpath {
        let tool = ToolLibrary.starter.tools[0]
        var moves: [Move] = [Move(.rapid, V3(10, 10, 15)), Move(.plunge, V3(10, 10, 9), feed: 400)]
        // Quarter circle of radius 10 around (10, 20) as many short segments
        for i in 1...40 {
            let a = -Double.pi / 2 + Double(i) / 40 * .pi / 2
            moves.append(Move(.feed, V3(10 + 10 * cos(a), 20 + 10 * sin(a), 9), feed: 1500))
        }
        moves.append(Move(.rapid, V3(20, 20, 15)))
        return Toolpath(id: UUID(), name: "Test", kind: .cutout, tool: tool, rpm: 18000, start: V3(0, 0, 15), moves: moves)
    }

    @Test func workbeeRRFDialect() {
        let post = PostProcessor(profile: .workbeeRRF, origin: V3(0, 0, 10), safeZ: 15, jobName: "Job", stockSize: V3(50, 50, 10))
        let files = post.process([simpleToolpath()])
        #expect(files.count == 1)
        let g = files[0].content
        #expect(files[0].name == "Job.gcode")
        #expect(g.contains("G21"))
        #expect(g.contains("M3 S18000"))
        #expect(g.contains("G4 S5"))
        #expect(!g.contains("M6"))
        #expect(g.contains("G3 ") || g.contains("G2 "))  // arc fitted
        #expect(g.contains("; Operation: Test"))
        // Z is relative to stock top: plunge to 9 => Z-1
        #expect(g.contains("G1 Z-1 F400"))
        // Every motion line carries its G word.
        for line in g.split(separator: "\n") where line.hasPrefix("X") || line.hasPrefix("Y") || line.hasPrefix("Z") {
            Issue.record("Modal motion line without G word: \(line)")
        }
    }

    @Test func grblDialectAndSplitFiles() {
        var other = simpleToolpath()
        other.tool = ToolLibrary.starter.tools[1]
        let post = PostProcessor(profile: .grbl, origin: V3(0, 0, 10), safeZ: 15, jobName: "Two Tools", stockSize: V3(50, 50, 10))
        let files = post.process([simpleToolpath(), other])
        #expect(files.count == 2)
        #expect(files[0].content.contains("(Machine: Generic GRBL 1.1)"))
        #expect(files[0].content.contains("G4 P3"))
        #expect(files[1].name.hasPrefix("Two_Tools_2_T2"))
    }

    @Test func m6ProfileSingleFile() {
        var other = simpleToolpath()
        other.tool = ToolLibrary.starter.tools[1]
        let post = PostProcessor(profile: .linuxcnc, origin: .zero, safeZ: 15, jobName: "J", stockSize: V3(50, 50, 10))
        let files = post.process([simpleToolpath(), other])
        #expect(files.count == 1)
        #expect(files[0].content.contains("T1 M6"))
        #expect(files[0].content.contains("T2 M6"))
    }

    @Test func arcFitterReproducesCircle() {
        let tp = simpleToolpath()
        let fitted = ArcFitter.fit(tp.moves, tolerance: 0.01)
        let arcs = fitted.filter(\.isArc)
        #expect(arcs.count == 1)
        #expect(simd_distance(arcs[0].center!, V2(10, 20)) < 0.01)
        #expect(arcs[0].kind == .arcCCW)
    }
}
