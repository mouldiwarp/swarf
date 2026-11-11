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
    // A 90° bit keeps the expected groove depth equal to the distance from the edge.
    var vbit90: Tool { Tool(number: 20, name: "90° test V-bit", kind: .vBit, diameter: 6.35, vAngle: 90, flutes: 2, fluteLength: 6,
                            stickout: 25, defaults: CuttingData(rpm: 18000, feed: 1000, plunge: 300, stepdown: 1, stepoverPercent: 20)) }

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

@Suite struct StarterLibraryTests {
    @Test func vBitsAre60And45Degree6mm() {
        let v = ToolLibrary.starter.tools.filter { $0.kind == .vBit }
        #expect(v.map(\.vAngle).sorted() == [45, 60])
        #expect(v.allSatisfy { $0.diameter == 6 })
        // Flute length covers the full cone height: r / tan(half angle).
        for t in v { #expect(abs(t.fluteLength - 3 / tan(t.vAngle / 2 * .pi / 180)) < 0.05) }
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

@Suite struct CutoutFinishTests {
    @Test func roughsWithAllowanceThenFinishesAtFourTimesStepdown() async throws {
        var job = Job()
        job.quality = .draft
        var op = Operation(kind: .cutout, tool: ToolLibrary.starter.tools[0], material: .named("mdf"))
        op.cutting.stepdown = 2
        op.tabs.countPerLoop = 4
        job.operations = [op]
        #expect(op.finishStepdown == 8)
        let ctx = CAMContext(raw: STL.box(V3(60, 40, 18)), job: job)
        let tp = try ctx.generate(op)
        let R = op.tool.radius
        // Classify cutting moves below the tab height by their distance from the part.
        var roughZ = Set<Double>(), finishZ = Set<Double>()
        var prevZ = Double.nan
        for m in tp.moves {
            defer { prevZ = m.to.z }
            guard m.kind == .feed && abs(m.to.z - op.tabs.height) > 1e-6 && m.to.z < 17.9 else { continue }
            let d = Double(ctx.silhouetteDistance.sample(m.to.xy))
            let z = (m.to.z * 100).rounded() / 100
            if abs(d - (R + 0.5)) < 0.2 { if m.to.z == prevZ { roughZ.insert(z) } }
            else if abs(d - R) < 0.2 { if m.to.z == prevZ { finishZ.insert(z) } }
            else { Issue.record("Cut at unexpected offset \(d)") }
        }
        // Roughing: 18.3 mm in 2 mm-or-less passes → 10 levels. Finishing: 8 mm-or-less → 3 levels.
        #expect(roughZ.count == 10)
        #expect(finishZ.count == 3)
        #expect(finishZ.min() == -0.3 && roughZ.min() == -0.3)
        // Roughing all comes before finishing (single outer loop).
        let firstFinish = tp.moves.firstIndex { $0.kind == .feed && abs(Double(ctx.silhouetteDistance.sample($0.to.xy)) - R) < 0.2 && $0.to.z < 17 }!
        let lastRough = tp.moves.lastIndex { $0.kind == .feed && abs(Double(ctx.silhouetteDistance.sample($0.to.xy)) - (R + 0.5)) < 0.2 }!
        #expect(lastRough < firstFinish)
        // Tabs survive in both passes: the 4 tabs reach tab height on the finished outline.
        let finishAtTab = tp.moves.filter { $0.kind == .feed && abs(Double(ctx.silhouetteDistance.sample($0.to.xy)) - R) < 0.2 && abs($0.to.z - op.tabs.height) < 1e-6 }
        #expect(finishAtTab.count >= 4)
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed, tolerance: 0.1).gougeCells == 0)
    }

    @Test func finishCanBeTurnedOff() throws {
        var op = Operation(kind: .cutout, tool: ToolLibrary.starter.tools[0], material: .named("mdf"))
        op.cutoutFinishSettings.enabled = false
        op.finishStepdown = 5
        #expect(op.finishStepdown == 5)
        var job = Job(); job.quality = .draft; job.operations = [op]
        let ctx = CAMContext(raw: STL.box(V3(60, 40, 18)), job: job)
        let tp = try ctx.generate(op)
        for m in tp.moves where m.kind == .feed && m.to.z < 17 {
            #expect(abs(Double(ctx.silhouetteDistance.sample(m.to.xy)) - op.tool.radius) < 0.2)
        }
    }
}

@Suite struct DrillTests {
    /// 60 × 20 × 10 plate with three holes in 20 mm cells: Ø6 through, Ø6 blind (floor at z 5), Ø10 through.
    static func plate() -> Mesh {
        var tris: [Triangle] = []
        let holes: [(r: Float, floor: Float?)] = [(3, nil), (3, 5), (5, nil)]
        let N = 96, top: Float = 10
        func sq(_ a: Float) -> SIMD2<Float> {  // point on the 20 mm square at angle a
            let d = SIMD2<Float>(cos(a), sin(a))
            return d * (10 / max(abs(d.x), abs(d.y)))
        }
        for (k, hole) in holes.enumerated() {
            let c = SIMD2<Float>(Float(k) * 20 + 10, 10)
            for i in 0..<N {
                let a0 = Float(i) / Float(N) * 2 * .pi, a1 = Float(i + 1) / Float(N) * 2 * .pi
                let p0 = c + hole.r * SIMD2(cos(a0), sin(a0)), p1 = c + hole.r * SIMD2(cos(a1), sin(a1))
                let s0 = c + sq(a0), s1 = c + sq(a1)
                func v(_ p: SIMD2<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(p.x, p.y, z) }
                tris.append(Triangle(v(p0, top), v(s0, top), v(p1, top)))
                tris.append(Triangle(v(p1, top), v(s0, top), v(s1, top)))
                let fz = hole.floor ?? 0
                tris.append(Triangle(v(p0, top), v(p1, fz), v(p0, fz)))
                tris.append(Triangle(v(p0, top), v(p1, top), v(p1, fz)))
                if let f = hole.floor { tris.append(Triangle(v(c, f), v(p0, f), v(p1, f))) }
                tris.append(Triangle(v(p0, 0), v(p1, 0), v(s0, 0)))
                tris.append(Triangle(v(p1, 0), v(s1, 0), v(s0, 0)))
            }
        }
        return Mesh(triangles: tris)
    }

    @Test func findsRoundHoles() {
        let ctx = CAMContext(raw: Self.plate(), job: Job())
        let holes = ctx.detectHoles().sorted { $0.center.x < $1.center.x }
        #expect(holes.count == 3)
        guard holes.count == 3 else { return }
        #expect(abs(holes[0].diameter - 6) < 0.3 && holes[0].floorZ == nil)
        #expect(abs(holes[1].diameter - 6) < 0.3 && abs((holes[1].floorZ ?? 0) - (ctx.stockTop - 5)) < 0.05)
        #expect(abs(holes[2].diameter - 10) < 0.3 && holes[2].floorZ == nil)
    }

    @Test func pecksMatchingHoles() throws {
        var job = Job()
        let tool = ToolLibrary.starter.tools[0]  // 6 mm flat
        var op = Operation(kind: .drill, tool: tool, material: .named("mdf"))
        op.cutting.stepdown = 2
        job.operations = [op]
        let ctx = CAMContext(raw: Self.plate(), job: job)
        let tp = try ctx.generate(op)
        // Two Ø6 holes drilled, the Ø10 one skipped with a warning.
        let plunges = tp.moves.filter { $0.kind == .plunge }
        let xy = Set(plunges.map { V2(($0.to.x * 10).rounded(), ($0.to.y * 10).rounded()) })
        #expect(xy.count == 2)
        #expect(tp.warnings.contains { $0.contains("Skipped 1 hole") })
        // Every peck goes at most 2 mm past the deepest point reached so far at that hole.
        let top = ctx.stockTop
        var deepest: [V2: Double] = [:]
        var p = tp.start
        for m in tp.moves {
            let k = V2((m.to.x * 10).rounded(), (m.to.y * 10).rounded())
            if m.kind == .plunge {
                let d = deepest[k] ?? top
                #expect(d - m.to.z <= 2 + 1e-6)
                #expect(abs(m.to.x - p.x) < 1e-9 && abs(m.to.y - p.y) < 1e-9)
                deepest[k] = min(d, m.to.z)
            } else if m.kind == .rapid && m.to.z < (deepest[k] ?? top) + 0.5 - 1e-6 {
                Issue.record("Rapid into uncut material at \(m.to)")
            }
            p = m.to
        }
        let bottoms = deepest.values.sorted()
        #expect(abs(bottoms[0] - -op.throughDepth) < 1e-6)  // through hole
        #expect(abs(bottoms[1] - (top - 5)) < 0.05)        // blind hole floor
        // Simulated stock: no gouges.
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed, tolerance: 0.1).gougeCells == 0)
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

@Suite struct RobustnessTests {
    /// Overwrites the Y of the first vertex of `triangle` (or of every triangle) with NaN in a binary STL.
    func poisoned(_ mesh: Mesh, triangle: Int?) -> Data {
        var data = STL.binaryData(mesh)
        let nan = withUnsafeBytes(of: Float.nan) { Array($0) }
        for t in 0..<mesh.triangles.count where triangle == nil || triangle == t {
            let off = 84 + t * 50 + 12 + 4
            data.replaceSubrange(off..<off + 4, with: nan)
        }
        return data
    }

    @Test func binarySTLSkipsBadTrianglesAndRejectsAllBad() throws {
        let box = STL.box(V3(10, 10, 10))
        #expect(try STL.parse(poisoned(box, triangle: 3)).triangles.count == 11)
        #expect(throws: STLError.self) { try STL.parse(poisoned(box, triangle: nil)) }
    }

    @Test func asciiSTLReportsBadNumbersAndTruncation() {
        let badNumber = "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1.0abc 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n"
        #expect(throws: STLError.self) { try STL.parse(Data(badNumber.utf8)) }
        let truncated = "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\n"
        #expect(throws: STLError.self) { try STL.parse(Data(truncated.utf8)) }
        let huge = "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1e30 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid t\n"
        #expect(throws: STLError.self) { try STL.parse(Data(huge.utf8)) }
    }

    @Test func missingFileGivesReadableError() {
        #expect(throws: STLError.self) { try STL.read(url: URL(fileURLWithPath: "/nonexistent/swarf-test.stl")) }
    }

    @Test func invalidOperationSettingsAreRejectedBeforeCutting() {
        let ctx = CAMContext(raw: STL.box(V3(40, 40, 10)), job: Job())
        let good = Operation(kind: .roughing, tool: ToolLibrary.starter.tools[0])
        var zeroFeed = good; zeroFeed.cutting.feed = 0
        var nanStepdown = good; nanStepdown.cutting.stepdown = .nan
        var noDiameter = good; noDiameter.tool.diameter = 0
        var infiniteRPM = good; infiniteRPM.cutting.rpm = .infinity
        for op in [zeroFeed, nanStepdown, noDiameter, infiniteRPM] {
            #expect(throws: CAMError.self) { try ctx.generate(op) }
        }
    }

    @Test func nonsensePlacementSettingsFallBackToSafeValues() {
        var job = Job()
        job.orientation.scale = 0
        job.stock.marginXY = -.infinity
        let placed = PlacedModel(raw: STL.box(V3(20, 20, 5)), orientation: job.orientation, stock: job.stock)
        for v in [placed.stockSize.x, placed.stockSize.y, placed.stockSize.z] {
            #expect(v.isFinite && v > 0)
        }
    }

    @Test func gridStaysWithinTheCellBudgetForHugeStock() {
        let s = V3(20000, 20000, 50)
        let res = CAMContext.gridResolution(stockSize: s, quality: .fine)
        #expect((s.x + 16) / res * (s.y + 16) / res <= CAMContext.maxGridCells * 1.001)
        // Ordinary stock is unaffected by the cap.
        #expect(CAMContext.gridResolution(stockSize: V3(300, 200, 20), quality: .normal) <= 0.5)
    }

    @Test func topViewDrawsRegionsThatAreInsideOutOrOffTheStock() {
        let size = V3(40, 30, 10)
        let sim = StockSimulator(stockSize: size, resolution: 0.5)
        let regions = [Region(name: "inverted", min: V2(30, 20), max: V2(5, 5)),
                       Region(name: "outside", min: V2(-500, -500), max: V2(-400, -400)),
                       Region(name: "huge", min: V2(-1e6, -1e6), max: V2(1e6, 1e6))]
        let img = TopView.render(stock: sim.stock, stockSize: size, analysis: nil, toolpaths: [], regions: regions)
        #expect(img.width > 0 && img.rgb.count == img.width * img.height * 3)
        let big = TopView.render(stock: sim.stock, stockSize: V3(5000, 3000, 10), analysis: nil, toolpaths: [], pixelsPerMM: 8)
        #expect(max(big.width, big.height) <= 6100)
    }

    @Test func fusionImportRejectsOtherJSONAndSkipsUnusableTools() throws {
        #expect(throws: ToolImportError.self) { try ToolLibrary.importFusion(Data("{\"hello\": 1}".utf8)) }
        #expect(throws: ToolImportError.self) { try ToolLibrary.importFusion(Data("not json".utf8)) }
        let lib = """
        {"data": [
          {"type": "flat end mill", "description": "zero", "geometry": {"DC": 0}},
          {"type": "flat end mill", "description": "ok", "geometry": {"DC": 6, "LCF": -4, "NOF": 0},
           "start-values": {"presets": [{"n": 0, "v_f": -100}]}}
        ]}
        """
        let tools = try ToolLibrary.importFusion(Data(lib.utf8))
        #expect(tools.count == 1)
        #expect(tools[0].name == "ok")
        #expect(tools[0].fluteLength > 0 && tools[0].flutes >= 1 && tools[0].defaults.feed > 0 && tools[0].defaults.rpm > 0)
    }
}

@Suite struct PostSafetyTests {
    func path(tool: Tool, name: String = "Op", from: V3, to: V3) -> Toolpath {
        Toolpath(id: UUID(), name: name, kind: .pocket, tool: tool, rpm: 18000, start: V3(0, 0, 15),
                 moves: [Move(.rapid, from), Move(.plunge, V3(from.x, from.y, 9), feed: 400), Move(.feed, to, feed: 1500),
                         Move(.rapid, V3(to.x, to.y, 15))])
    }

    func motionLines(_ g: String, after marker: String) -> [Substring] {
        let lines = g.split(separator: "\n")
        guard let i = lines.firstIndex(where: { $0.contains(marker) }) else { return [] }
        return lines[(i + 1)...].filter { ($0.hasPrefix("G0") || $0.hasPrefix("G1")) && ($0.contains("X") || $0.contains("Y")) }
    }

    @Test func firstMoveAfterAToolChangeStatesXAndY() {
        // The second tool starts exactly where the first one stopped. The machine may have moved for the tool
        // change, so the position must be stated again rather than assumed.
        let a = ToolLibrary.starter.tools[0], b = ToolLibrary.starter.tools[1]
        let first = path(tool: a, from: V3(10, 10, 15), to: V3(20, 20, 9))
        let second = path(tool: b, from: V3(20, 20, 15), to: V3(30, 20, 9))
        for profile in [MachineProfile.linuxcnc, .duetGeneric] {
            let post = PostProcessor(profile: profile, origin: .zero, safeZ: 15, jobName: "J", stockSize: V3(50, 50, 10))
            let g = post.process([first, second])[0].content
            let marker = profile.toolChange == .m6 ? "T\(b.number) M6" : "M291"
            let line = motionLines(g, after: marker).first
            #expect(line != nil)
            #expect(line?.contains("X20") == true && line?.contains("Y20") == true, "\(profile.id): \(line ?? "")")
            // The feed is restated for the new tool as well.
            let feeds = g.split(separator: "\n").drop(while: { !$0.contains(marker) }).filter { $0.hasPrefix("G1") }
            #expect(feeds.first?.contains("F") == true)
        }
    }

    @Test func feedChangeOnAZeroLengthMoveIsNotLost() {
        let tool = ToolLibrary.starter.tools[0]
        let tp = Toolpath(id: UUID(), name: "Op", kind: .pocket, tool: tool, rpm: 18000, start: V3(0, 0, 15),
                          moves: [Move(.rapid, V3(10, 10, 15)), Move(.plunge, V3(10, 10, 9), feed: 400),
                                  Move(.feed, V3(10, 10, 9), feed: 1500), Move(.feed, V3(30, 10, 9), feed: 1500)])
        let post = PostProcessor(profile: .grbl, origin: .zero, safeZ: 15, jobName: "J", stockSize: V3(50, 50, 10))
        let g = post.process([tp])[0].content
        #expect(g.contains("G1 X30 F1500"), "\(g)")
    }

    @Test func rrfToolChangePromptEscapesQuotes() {
        var a = ToolLibrary.starter.tools[0], b = ToolLibrary.starter.tools[1]
        a.name = "First"; b.name = "1/4\" flat"
        let post = PostProcessor(profile: .duetGeneric, origin: .zero, safeZ: 15, jobName: "J", stockSize: V3(50, 50, 10))
        let g = post.process([path(tool: a, from: V3(10, 10, 15), to: V3(20, 20, 9)), path(tool: b, from: V3(5, 5, 15), to: V3(9, 9, 9))])[0].content
        let prompt = g.split(separator: "\n").first { $0.hasPrefix("M291") }
        #expect(prompt?.contains("1/4\"\" flat.") == true, "\(prompt ?? "")")
        // Quotes stay balanced, so the firmware sees one P string and one R string.
        #expect((prompt?.filter { $0 == "\"" }.count ?? 1) % 2 == 0)
    }

    @Test func namesCannotInjectGCodeOrLeaveASCII() {
        var tool = ToolLibrary.starter.tools[0]
        tool.name = "Ø6 60° — bit\nM3 S99999"
        let tp = path(tool: tool, name: "Pocket\r\nG0 Z-50 (deep)", from: V3(10, 10, 15), to: V3(20, 20, 9))
        for profile in [MachineProfile.workbeeRRF, .grbl] {
            let post = PostProcessor(profile: profile, origin: .zero, safeZ: 15, jobName: "Tëst\nG0 X999", stockSize: V3(50, 50, 10))
            let g = post.process([tp])[0].content
            #expect(g.unicodeScalars.allSatisfy { $0.value == 10 || ($0.value >= 0x20 && $0.value < 0x7F) })
            for line in g.split(separator: "\n") {
                #expect(!line.hasPrefix("G0 Z-50") && !line.hasPrefix("G0 X999") && !line.hasPrefix("M3 S99999"), "\(line)")
            }
            if profile.commentStyle == .parentheses {
                // One comment per line: no nested or unbalanced brackets.
                for line in g.split(separator: "\n") where line.hasPrefix("(") {
                    #expect(line.filter { $0 == "(" }.count == 1 && line.filter { $0 == ")" }.count == 1 && line.hasSuffix(")"))
                }
            }
        }
    }

    @Test func fileNamesStayInsideTheChosenFolder() {
        var a = ToolLibrary.starter.tools[0], b = ToolLibrary.starter.tools[1]
        a.name = "../../evil"; b.name = "a:b\\c*?"
        let post = PostProcessor(profile: .grbl, origin: .zero, safeZ: 15, jobName: "../../etc/passwd", stockSize: V3(50, 50, 10))
        let files = post.process([path(tool: a, from: V3(10, 10, 15), to: V3(20, 20, 9)), path(tool: b, from: V3(5, 5, 15), to: V3(9, 9, 9))])
        #expect(files.count == 2)
        for f in files {
            #expect(!f.name.hasPrefix(".") && !f.name.contains("/") && !f.name.contains(":") && !f.name.contains("\\"))
            #expect(f.name.hasSuffix(".nc"))
        }
        let blank = PostProcessor(profile: .grbl, origin: .zero, safeZ: 15, jobName: " / ", stockSize: V3(50, 50, 10))
        #expect(blank.process([path(tool: a, from: V3(10, 10, 15), to: V3(20, 20, 9))])[0].name == "job.nc")
    }
}

@Suite struct TestCutTests {
    let lib = ToolLibrary.starter

    func testJob(_ cut: Double = 8, _ pocket: Double = 4, _ drill: Double = 4) -> Job {
        var job = Job()
        job.quality = .draft
        var t = TestCut()
        t.enabled = true
        t.cutoutDepth = cut; t.pocketDepth = pocket; t.drillDepth = drill
        job.testCut = t
        return job
    }

    func deepest(_ tp: Toolpath) -> Double { tp.moves.filter { $0.kind != .rapid }.map(\.to.z).min() ?? .infinity }

    @Test func cutoutStopsAtTheCutoutDepth() throws {
        var job = testJob()
        let op = Operation(kind: .cutout, tool: lib.closest(kind: .flat, diameter: 6)!)
        job.operations = [op]
        let ctx = CAMContext(raw: STL.box(V3(40, 30, 20)), job: job)
        let tp = try ctx.generate(op)
        #expect(abs(deepest(tp) - (ctx.stockTop - 8)) < 1e-6)
        #expect(tp.warnings.contains { $0.hasPrefix("Test cut") })
    }

    @Test func pocketsAndRoughingStopAtThePocketDepth() throws {
        // The plate's pocket is 4 mm deep; a 2 mm limit must stop it short. A 20 mm block roughed must stop at 4 mm.
        var job = testJob(8, 2, 4)
        let pocket = Operation(kind: .pocket, tool: lib.closest(kind: .flat, diameter: 3.175)!)
        job.operations = [pocket]
        let plate = OperationTests().pocketPlate()
        let ctx = CAMContext(raw: plate, job: job)
        #expect(abs(deepest(try ctx.generate(pocket)) - (ctx.stockTop - 2)) < 1e-6)

        var job2 = testJob()
        let rough = Operation(kind: .roughing, tool: lib.closest(kind: .flat, diameter: 6)!)
        job2.operations = [rough]
        job2.stock.extraTop = 0
        let ctx2 = CAMContext(raw: STL.dome(radius: 20, segments: 48, rings: 24, center: V2(25, 25)).translated(V3(0, 0, 0)), job: job2)
        let tp = try ctx2.generate(rough)
        #expect(deepest(tp) >= ctx2.stockTop - 4 - 1e-6)
    }

    @Test func drilledHolesStopAtTheDrillDepth() throws {
        var job = testJob()
        var op = Operation(kind: .drill, tool: lib.tools[0])
        op.cutting.stepdown = 1.5
        job.operations = [op]
        let ctx = CAMContext(raw: DrillTests.plate(), job: job)
        let tp = try ctx.generate(op)
        // Both the through hole and the 5 mm blind hole stop 4 mm down.
        let bottoms = Dictionary(grouping: tp.moves.filter { $0.kind == .plunge }, by: { V2(($0.to.x).rounded(), ($0.to.y).rounded()) })
            .mapValues { $0.map(\.to.z).min()! }
        #expect(bottoms.count == 2)
        for z in bottoms.values { #expect(abs(z - (ctx.stockTop - 4)) < 1e-6) }
    }

    @Test func offByDefaultAndOldProjectsStillOpen() throws {
        #expect(Job().activeTestCut == nil)
        var job = testJob()
        job.testCut?.enabled = false
        let op = Operation(kind: .cutout, tool: lib.closest(kind: .flat, diameter: 6)!)
        job.operations = [op]
        let ctx = CAMContext(raw: STL.box(V3(40, 30, 20)), job: job)
        #expect(deepest(try ctx.generate(op)) < 0)
        // A job saved before test-cut mode existed has no "testCut" key.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Job())) as! [String: Any]
        json.removeValue(forKey: "testCut")
        let old = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.activeTestCut == nil)
    }

    @Test func filesAreMarkedAsTests() {
        let tp = PostSafetyTests().path(tool: lib.tools[0], from: V3(10, 10, 15), to: V3(20, 20, 9))
        let post = PostProcessor(profile: .workbeeRRF, origin: .zero, safeZ: 15, jobName: "Body", stockSize: V3(50, 50, 10),
                                 testCut: testJob().activeTestCut)
        let f = post.process([tp])[0]
        #expect(f.name == "Body_TEST.gcode")
        #expect(f.content.contains("; TEST CUT - depths limited to: cutouts 8 mm, pockets and carving 4 mm, holes 4 mm."))
    }
}
