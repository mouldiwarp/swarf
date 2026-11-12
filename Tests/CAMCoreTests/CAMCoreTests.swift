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

    /// The pocket must come out at its true size. On the grid alone the wall pass stopped short of the walls by an
    /// amount that grew with depth (about 0.5 mm a side on a 20 mm deep guitar neck pocket).
    @Test func pocketWallsAreExactAtEveryDepth() throws {
        // 40 × 30 plate with a 24 × 14 pocket 12 mm deep; draft grid and an odd margin put the walls between grid nodes.
        let mesh = STL.merge([
            STL.box(V3(40, 30, 3)),
            STL.box(V3(40, 8, 12), at: V3(0, 0, 3)), STL.box(V3(40, 8, 12), at: V3(0, 22, 3)),
            STL.box(V3(8, 14, 12), at: V3(0, 8, 3)), STL.box(V3(8, 14, 12), at: V3(32, 8, 3)),
        ])
        var job = Job()
        job.quality = .draft
        job.stock.marginXY = 5.137
        let tool = lib.closest(kind: .flat, diameter: 6)!
        var op = Operation(kind: .pocket, tool: tool, material: material())
        op.boundary = .insideSilhouette
        job.operations = [op]
        let ctx = CAMContext(raw: mesh, job: job)
        let tp = try ctx.generate(op)
        let o = ctx.placed.modelBounds.min
        let want = (x0: o.x + 8 + 3, x1: o.x + 32 - 3, y0: o.y + 8 + 3, y1: o.y + 22 - 3)
        var levels: [Double: (Double, Double, Double, Double)] = [:]
        var prev = tp.start
        for m in tp.moves {
            defer { prev = m.to }
            // Flat passes only: ramps change Z as they go.
            guard m.kind != .rapid, m.to.z < ctx.stockTop - 0.5, abs(m.to.z - prev.z) < 1e-6 else { continue }
            let z = (m.to.z * 1000).rounded() / 1000
            let e = levels[z] ?? (.infinity, -.infinity, .infinity, -.infinity)
            levels[z] = (min(e.0, m.to.x), max(e.1, m.to.x), min(e.2, m.to.y), max(e.3, m.to.y))
        }
        #expect(levels.count >= 5)
        for (z, e) in levels {
            let err = max(abs(e.0 - want.x0), abs(e.1 - want.x1), abs(e.2 - want.y0), abs(e.3 - want.y1))
            #expect(err < 0.01, "at z \(z) the wall pass is \(err) mm off (grid \(ctx.res) mm)")
        }
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed).gougeCells == 0)
    }

    /// Flat-topped ring (annulus) from z0 to z1, centred at (30, 30): top face and both walls.
    static func ring(inner: Double, outer: Double, z0: Float, z1: Float, segments: Int = 96) -> [Triangle] {
        var tris: [Triangle] = []
        let c = V2(30, 30)
        func p(_ r: Double, _ i: Int, _ z: Float) -> SIMD3<Float> {
            let a = Double(i) / Double(segments) * 2 * .pi
            return SIMD3(Float(c.x + r * cos(a)), Float(c.y + r * sin(a)), z)
        }
        for i in 0..<segments {
            let j = i + 1
            tris += [Triangle(p(inner, i, z1), p(outer, i, z1), p(outer, j, z1)), Triangle(p(inner, i, z1), p(outer, j, z1), p(inner, j, z1))]
            tris += [Triangle(p(inner, i, z0), p(inner, i, z1), p(inner, j, z1)), Triangle(p(inner, i, z0), p(inner, j, z1), p(inner, j, z0))]
            tris += [Triangle(p(outer, i, z0), p(outer, j, z1), p(outer, i, z1)), Triangle(p(outer, i, z0), p(outer, j, z0), p(outer, j, z1))]
        }
        return tris
    }

    /// Base plate with a ring wall standing on it: a round cavity of radius `inner`, centred at (30, 30).
    static func roundCavity(inner: Double = 18, outer: Double = 26, height: Double = 12) -> Mesh {
        STL.merge([STL.box(V3(60, 60, 3)), Mesh(triangles: ring(inner: inner, outer: outer, z0: 3, z1: Float(3 + height)))])
    }

    /// Turns of more than 1° along flat cutting passes between `minR` and `maxR` from `centre`, and how many of them
    /// reverse the previous turn's direction. Moves that step between passes (radius changes by 0.5 mm or more) are
    /// links, not passes, and are skipped.
    static func wobble(_ tp: Toolpath, _ ctx: CAMContext, centre: V2, minR: Double = 0, maxR: Double) -> (turns: Int, flips: Int, moves: Int) {
        var turns = 0, flips = 0, flatMoves = 0
        var prev = tp.start, prevDir: Double? = nil, prevTurn = 0.0
        for m in tp.moves {
            defer { prev = m.to }
            let d = m.to.xy - prev.xy
            let r = simd_length(m.to.xy - centre)
            guard m.kind == .feed, m.to.z < ctx.stockTop - 0.5, abs(m.to.z - prev.z) < 1e-6, simd_length(d) > 1e-6,
                  r < maxR, r > minR, abs(r - simd_length(prev.xy - centre)) < 0.5 else {
                prevDir = nil; prevTurn = 0; continue
            }
            flatMoves += 1
            let a = atan2(d.y, d.x)
            if let pd = prevDir {
                var t = a - pd
                while t > .pi { t -= 2 * .pi }
                while t < -.pi { t += 2 * .pi }
                if abs(t) > .pi / 180 {
                    turns += 1
                    if prevTurn != 0, (t > 0) != (prevTurn > 0) { flips += 1 }
                    prevTurn = t
                }
            }
            prevDir = a
        }
        return (turns, flips, flatMoves)
    }

    @Test func pocketPassesAroundAThroughHoleAreSmooth() throws {
        // A recessed floor with a round through-hole: with the "inside model" boundary the hole is out of bounds, and
        // the passes around it are limited by a yes/no mask rather than a model wall. Traced from the grid they are a
        // staircase; they must come out smooth, reaching at most 0.75 cells past the grid's limit.
        let mesh = Mesh(triangles: Self.ring(inner: 10, outer: 28, z0: 0, z1: 3) + Self.ring(inner: 28, outer: 34, z0: 0, z1: 15))
        var job = Job()
        job.quality = .draft
        job.stock.marginXY = 5.137
        let tool = lib.closest(kind: .flat, diameter: 6)!
        var op = Operation(kind: .pocket, tool: tool, material: material())
        op.boundary = .insideSilhouette
        job.operations = [op]
        let ctx = CAMContext(raw: mesh, job: job)
        let tp = try ctx.generate(op)
        // The mesh's bounds start 34 mm before the ring's centre.
        let centre = ctx.placed.modelBounds.min.xy + V2(34, 34)
        let w = Self.wobble(tp, ctx, centre: centre, minR: 12, maxR: 18)
        #expect(w.moves > 20)
        #expect(Double(w.flips) < Double(w.turns) * 0.05, "\(w.flips) of \(w.turns) turns reverse direction")
        // The tool centre stays a tool radius outside the hole (to within the grid's reach plus 0.75 cells).
        let closest = tp.moves.filter { $0.kind != .rapid && $0.to.z < ctx.stockTop - 0.5 }.map { simd_length($0.to.xy - centre) }.min() ?? 0
        #expect(closest > 13 - 1.75 * ctx.res, "comes within \(closest) mm of the hole centre")
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed).gougeCells == 0)
    }

    @Test func pocketReachesAcrossAnEnclosedHole() throws {
        // A cavity whose floor is a 4 mm ring around a through-hole: narrower than the 6 mm cutter, so with the hole
        // out of bounds the cutter could never get in. The hole is waste, so the cutter may sweep over its edge and
        // clear the ring, but it must not spend time clearing the middle of the hole.
        let mesh = Mesh(triangles: Self.ring(inner: 10, outer: 14, z0: 0, z1: 3) + Self.ring(inner: 14, outer: 30, z0: 0, z1: 12))
        var job = Job()
        job.quality = .draft
        let tool = lib.closest(kind: .flat, diameter: 6)!
        var op = Operation(kind: .pocket, tool: tool, material: material())
        op.boundary = .insideSilhouette
        job.operations = [op]
        let ctx = CAMContext(raw: mesh, job: job)
        let tp = try ctx.generate(op)
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run([tp])
        let a = sim.analyze(model: ctx.placed)
        #expect(a.gougeCells == 0)
        // The floor ring (radius 10 to 14) is cleared down to the floor.
        let centre = ctx.placed.modelBounds.min.xy + V2(30, 30)
        var high = 0, ringCells = 0
        for y in 0..<sim.stock.height {
            for x in 0..<sim.stock.width {
                let r = simd_length(sim.stock.world(x, y) - centre)
                guard r > 10.5 && r < 13.5 else { continue }
                ringCells += 1
                if sim.stock[x, y] > 3.1 { high += 1 }
            }
        }
        #expect(ringCells > 100)
        #expect(high == 0, "\(high) of \(ringCells) cells of the floor ring are not cut down to the floor")
        // The cutter centre stays within the band (a diameter plus 1 mm) inside the hole's edge, never deeper.
        let deepest = tp.moves.filter { $0.kind != .rapid && $0.to.z < ctx.stockTop - 0.5 }.map { simd_length($0.to.xy - centre) }.min() ?? 0
        #expect(deepest > 10 - 7 - 3 - ctx.res, "the cutter goes \(10 - deepest) mm into the hole")
        #expect(deepest < 10, "the cutter never goes over the hole")
    }

    @Test func pocketPassesFollowCurvesSmoothly() throws {
        // Every concentric pass in a round cavity should be a smooth curve. Passes traced from the grid wobble: their
        // turning direction flips back and forth, which makes the machine brake and accelerate at every segment.
        var job = Job()
        job.quality = .draft
        job.stock.marginXY = 5.137
        let tool = lib.closest(kind: .flat, diameter: 6)!
        var op = Operation(kind: .pocket, tool: tool, material: material())
        op.boundary = .insideSilhouette
        job.operations = [op]
        let ctx = CAMContext(raw: Self.roundCavity(), job: job)
        let tp = try ctx.generate(op)
        // Inside the cavity only: the job also clears the moat around the ring, whose loops have real corners.
        let w = Self.wobble(tp, ctx, centre: ctx.placed.modelBounds.min.xy + V2(30, 30), maxR: 18)
        #expect(w.moves > 50)
        #expect(Double(w.flips) < Double(w.turns) * 0.05, "\(w.flips) of \(w.turns) turns reverse direction")
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run([tp])
        let a = sim.analyze(model: ctx.placed)
        #expect(a.gougeCells == 0)
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

@Suite struct WorkOriginTests {
    @Test func newJobsDefaultToCentreLeftTop() {
        #expect(Job().origin == WorkOrigin(x: .left, y: .center, z: .stockTop))
    }

    @Test func toolpathsStartAtTheWorkZero() throws {
        let tool = ToolLibrary.starter.closest(kind: .flat, diameter: 6)!
        for origin in [WorkOrigin.workbeeDefault, .swarfDefault, WorkOrigin(x: .right, y: .back)] {
            var job = Job()
            job.origin = origin
            let op = Operation(kind: .cutout, tool: tool)
            job.operations = [op]
            let ctx = CAMContext(raw: STL.box(V3(40, 30, 10)), job: job)
            let tp = try ctx.generate(op)
            let o = ctx.placed.originPoint(origin)
            #expect(abs(tp.start.x - o.x) < 1e-9 && abs(tp.start.y - o.y) < 1e-9)
            #expect(abs(tp.tessellated().first!.0.x - o.x) < 1e-9)
        }
    }
}

@Suite struct SmoothOutlineTests {
    /// A finely faceted round part: the cutout must sit on the exact offset circle, not on the grid's staircase,
    /// and come out as arcs rather than a cloud of tiny direction-changing segments.
    @Test func cutoutFollowsTheTrueOutline() throws {
        let radius = 20.0
        let mesh = STL.merge([STL.dome(radius: radius, segments: 360, rings: 8, center: V2(40, 40)),
                              STL.box(V3(1, 1, 1), at: V3(40, 40, -10))])  // keeps the dome off the bed
        let tool = ToolLibrary.starter.closest(kind: .flat, diameter: 6)!
        var op = Operation(kind: .cutout, tool: tool)
        op.tabs.enabled = false
        var job = Job()
        job.operations = [op]
        let ctx = CAMContext(raw: mesh, job: job)
        let b = ctx.placed.modelBounds
        let c = V2((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2)
        let loops = ctx.cutoutLoops(op)
        #expect(loops.count == 1)
        let want = radius + tool.radius
        let worst = loops.flatMap(\.points).map { abs($0.dist(c) - want) }.max() ?? 1
        #expect(worst < 0.02, "outline is \(worst) mm off the exact offset (grid is \(ctx.res) mm)")

        let tp = try ctx.generate(op)
        let post = PostProcessor(profile: .workbeeRRF, origin: ctx.placed.originPoint(job.origin), safeZ: ctx.safeZ,
                                 jobName: "t", stockSize: ctx.placed.stockSize)
        let lines = post.process([tp]).flatMap { $0.content.split(separator: "\n") }
        let arcs = lines.filter { $0.hasPrefix("G2") || $0.hasPrefix("G3") }.count
        let flatG1 = lines.filter { $0.hasPrefix("G1") && !$0.contains("Z") }.count
        #expect(arcs > flatG1, "\(arcs) arcs vs \(flatG1) planar G1 moves")
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed).gougeCells == 0)
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

    /// The grid only locates a hole to a fraction of a cell; the drill must still sit on the true centre.
    @Test func holeCentresAreExact() {
        // A coarse grid and an odd stock margin put the hole centres between grid nodes.
        var job = Job()
        job.quality = .draft
        job.stock.marginXY = 5.137
        let ctx = CAMContext(raw: Self.plate(), job: job)
        let holes = ctx.detectHoles().sorted { $0.center.x < $1.center.x }
        #expect(holes.count == 3)
        let off = ctx.placed.modelBounds.min
        for (k, h) in holes.enumerated() {
            let want = V2(off.x + Double(k) * 20 + 10, off.y + 10)
            #expect(h.center.dist(want) < 0.005, "hole \(k) is \(h.center.dist(want)) mm off-centre (grid \(ctx.res) mm)")
        }
        #expect(abs(holes[0].diameter - 6) < 0.01 && abs(holes[2].diameter - 10) < 0.01)
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
        #expect(g.contains("M3 P0 S18000"))
        #expect(g.contains("M5 P0"))
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

    @Test func fastNumberFormattingMatchesPrintf() {
        for decimals in [0, 1, 3, 4] {
            var profile = MachineProfile.workbeeRRF
            profile.decimals = decimals
            let post = PostProcessor(profile: profile, origin: .zero, safeZ: 15, jobName: "J", stockSize: V3(50, 50, 10))
            func reference(_ v: Double) -> String {
                var s = String(format: "%.\(decimals)f", v)
                if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
                return s == "-0" ? "0" : s
            }
            var values: [Double] = [0, -0.0, 1, -1, 0.5, 0.05, 0.0005, -0.0004, 10.1, 123.456789, -98.7654, 1e-7, 749.9995, 18000, -0.25]
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<5000 { values.append(Double.random(in: -800...800, using: &rng)) }
            for v in values {
                // Exact ties (x.xxx5) may round differently in binary; skip values within 1e-9 of one.
                let scaled = abs(v) * pow(10, Double(decimals))
                if abs(scaled - scaled.rounded(.down) - 0.5) < 1e-6 { continue }
                #expect(post.num(v) == reference(v), "\(v) at \(decimals) decimals")
            }
        }
    }

    @Test func materialAdjustmentIsDescribed() {
        #expect(Material.named("mdf").adjustmentSummary == nil)
        #expect(Material.named("hardwood").adjustmentSummary == "feed and plunge ×0.8, stepdown ×0.75")
        let d = Material.named("hardwood").apply(CuttingData(rpm: 18000, feed: 1200, plunge: 800, stepdown: 1.5, stepoverPercent: 45))
        #expect(d.feed == 960 && d.plunge == 640 && abs(d.stepdown - 1.125) < 0.01)
    }

    @Test func rrfRapidsRunAtTheRapidRateNotTheCuttingFeed() {
        // Outside CNC mode RRF runs a bare G0 at the last F, i.e. the cutting feed. Every G0 must carry the rapid rate,
        // and the next cutting move must restate its own feed.
        let a = ToolLibrary.starter.tools[0], b = ToolLibrary.starter.tools[1]
        let paths = [path(tool: a, from: V3(10, 10, 15), to: V3(20, 20, 9)), path(tool: b, from: V3(30, 10, 15), to: V3(40, 20, 9))]
        for profile in [MachineProfile.workbeeRRF, .duetGeneric] {
            let post = PostProcessor(profile: profile, origin: .zero, safeZ: 15, jobName: "J", stockSize: V3(50, 50, 10))
            for f in post.process(paths) {
                let lines = f.content.split(separator: "\n").map(String.init)
                let rapids = lines.filter { $0.hasPrefix("G0") }
                #expect(rapids.count >= 3)
                for r in rapids { #expect(r.hasSuffix(" F\(Int(profile.rapidRate))"), "\(profile.id): \(r)") }
                for (i, l) in lines.enumerated() where l.hasPrefix("G0") {
                    if let next = lines[(i + 1)...].first(where: { $0.hasPrefix("G1") || $0.hasPrefix("G2") || $0.hasPrefix("G3") }) {
                        #expect(next.contains(" F"), "\(profile.id): cutting move after a rapid has no feed: \(next)")
                    }
                }
            }
        }
    }

    @Test func rrfSpindleCommandsNameTheSpindle() {
        // RRF 3.3+ rejects a bare M3 when no tool is selected: "M3: No P parameter and no active tool with spindle".
        let a = ToolLibrary.starter.tools[0], b = ToolLibrary.starter.tools[1]
        let paths = [path(tool: a, from: V3(10, 10, 15), to: V3(20, 20, 9)), path(tool: b, from: V3(5, 5, 15), to: V3(9, 9, 9))]
        for profile in [MachineProfile.workbeeRRF, .duetGeneric] {
            let post = PostProcessor(profile: profile, origin: .zero, safeZ: 15, jobName: "J", stockSize: V3(50, 50, 10))
            for f in post.process(paths) {
                let lines = f.content.split(separator: "\n")
                let on = lines.filter { $0.hasPrefix("M3") }, off = lines.filter { $0.hasPrefix("M5") }
                #expect(!on.isEmpty && !off.isEmpty)
                for l in on + off { #expect(l.contains(" P0"), "\(profile.id): \(l)") }
            }
        }
    }

    @Test func exportFileNameCanBeChosen() {
        let a = ToolLibrary.starter.tools[0], b = ToolLibrary.starter.tools[1]
        let one = [path(tool: a, from: V3(10, 10, 15), to: V3(20, 20, 9))]
        let two = one + [path(tool: b, from: V3(5, 5, 15), to: V3(9, 9, 9))]
        var post = PostProcessor(profile: .workbeeRRF, origin: .zero, safeZ: 15, jobName: "Model", stockSize: V3(50, 50, 10))
        #expect(post.process(one)[0].name == "Model.gcode")
        post.fileName = "Strat body v2.gcode"
        #expect(post.process(one)[0].name == "Strat_body_v2.gcode")
        #expect(post.process(two).allSatisfy { $0.name.hasPrefix("Strat_body_v2_") })
        post.fileName = "../../etc/x"
        #expect(!post.process(one)[0].name.contains("/"))
        post.fileName = "   "
        #expect(post.process(one)[0].name == "Model.gcode")
        // Old projects have no export name and still open.
        let data = try! JSONEncoder().encode(Job())
        var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "exportName")
        let old = try! JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.exportName == nil)
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

@Suite struct MaxDepthTests {
    let lib = ToolLibrary.starter

    func deepest(_ tp: Toolpath) -> Double { tp.moves.filter { $0.kind != .rapid }.map(\.to.z).min() ?? .infinity }

    /// Generates `op` with and without a maximum depth: the limited one must stop exactly there (or above it) and
    /// the unlimited one must go deeper, so the limit is what stopped it. Returns the limited toolpath.
    @discardableResult
    func check(_ op: CAMCore.Operation, mesh: Mesh, job: Job = Job(), depth: Double, exact: Bool = true) throws -> (Toolpath, CAMContext) {
        var job = job
        job.quality = .draft
        var limited = op
        limited.maxDepth = depth
        job.operations = [limited]
        let ctx = CAMContext(raw: mesh, job: job)
        let free = try ctx.generate(op)
        let tp = try ctx.generate(limited)
        let floor = ctx.stockTop - depth
        #expect(deepest(free) < floor - 0.1, "\(op.kind): the unlimited cut should go deeper than \(depth) mm")
        #expect(deepest(tp) >= floor - 1e-6, "\(op.kind): cut to \(ctx.stockTop - deepest(tp)) mm, limit \(depth) mm")
        if exact { #expect(abs(deepest(tp) - floor) < 1e-6, "\(op.kind): stopped at \(ctx.stockTop - deepest(tp)) mm") }
        return (tp, ctx)
    }

    /// 3D finishing of a faceted dome needs the same 0.15 mm allowance as the other 3D tests.
    func noGouges(_ tp: Toolpath, _ ctx: CAMContext, tolerance: Double = 0.05) {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed, tolerance: tolerance).gougeCells == 0, "\(tp.kind) gouged")
    }

    @Test func pocketAndCutoutStopAtTheirOwnDepth() throws {
        let flat = lib.closest(kind: .flat, diameter: 3.175)!
        let (p, pc) = try check(CAMCore.Operation(kind: .pocket, tool: flat), mesh: OperationTests().pocketPlate(), depth: 2)
        noGouges(p, pc)
        let (c, cc) = try check(CAMCore.Operation(kind: .cutout, tool: lib.closest(kind: .flat, diameter: 6)!), mesh: STL.box(V3(40, 30, 20)), depth: 7)
        noGouges(c, cc)
    }

    @Test func threeDStrategiesStopAtTheirOwnDepth() throws {
        let dome = STL.dome(radius: 20, segments: 48, rings: 24, center: V2(25, 25))
        let flat = lib.closest(kind: .flat, diameter: 6)!, ball = lib.closest(kind: .ball, diameter: 3)!
        let (r, rc) = try check(CAMCore.Operation(kind: .roughing, tool: flat), mesh: dome, depth: 6, exact: false)
        noGouges(r, rc, tolerance: 0.15)
        let (f, fc) = try check(CAMCore.Operation(kind: .parallelFinish, tool: ball), mesh: dome, depth: 6, exact: false)
        noGouges(f, fc, tolerance: 0.15)
        try check(CAMCore.Operation(kind: .waterlineFinish, tool: ball), mesh: dome, depth: 6, exact: false)
    }

    @Test func drillingFacingAndVCarveStopAtTheirOwnDepth() throws {
        var drill = CAMCore.Operation(kind: .drill, tool: lib.tools[0])
        drill.cutting.stepdown = 1.5
        try check(drill, mesh: DrillTests.plate(), depth: 3)

        var job = Job()
        job.stock.extraTop = 3
        var face = CAMCore.Operation(kind: .facing, tool: lib.closest(kind: .flat, diameter: 6)!)
        face.facingDepth = 3
        try check(face, mesh: STL.box(V3(30, 30, 10)), job: job, depth: 1.5)

        let (mesh, vjob) = VCarveTests().lJob()
        try check(vjob.operations[0], mesh: mesh, job: vjob, depth: 0.5, exact: false)
    }

    @Test func noLimitByDefaultAndOldProjectsStillOpen() throws {
        let op = CAMCore.Operation(kind: .pocket, tool: lib.tools[0])
        #expect(op.maxDepth == nil)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
        obj.removeValue(forKey: "maxDepth")
        let old = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.maxDepth == nil)
    }

    @Test func theShallowerOfTestCutAndMaximumDepthWins() throws {
        var job = TestCutTests().testJob(8, 4, 4)
        job.quality = .draft
        var op = CAMCore.Operation(kind: .cutout, tool: lib.closest(kind: .flat, diameter: 6)!)
        op.maxDepth = 5
        job.operations = [op]
        let ctx = CAMContext(raw: STL.box(V3(40, 30, 20)), job: job)
        #expect(abs(deepest(try ctx.generate(op)) - (ctx.stockTop - 5)) < 1e-6)
        op.maxDepth = 12
        #expect(abs(deepest(try ctx.generate(op)) - (ctx.stockTop - 8)) < 1e-6)
    }
}
