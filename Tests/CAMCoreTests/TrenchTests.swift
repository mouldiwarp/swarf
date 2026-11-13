import Foundation
import Testing
@testable import CAMCore

@Suite struct CutoutTrenchTests {
    let tool = ToolLibrary.starter.closest(kind: .flat, diameter: 6)!

    func trenchOp(tabs: Bool = true) -> CAMCore.Operation {
        var op = CAMCore.Operation(kind: .cutout, tool: tool, material: .named("mdf"))
        op.cutting.stepdown = 2
        op.tabs.enabled = tabs
        op.cutoutTrenchSettings.enabled = true
        op.cutoutTrenchSettings.widthFactor = 1.5
        return op
    }

    func context(_ op: CAMCore.Operation, mesh: Mesh = STL.box(V3(60, 40, 18))) -> CAMContext {
        var job = Job()
        job.quality = .draft
        job.stock.marginXY = 20
        job.operations = [op]
        return CAMContext(raw: mesh, job: job)
    }

    func simulate(_ tp: Toolpath, _ ctx: CAMContext) -> (StockSimulator, StockSimulator.Analysis) {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run([tp])
        return (sim, sim.analyze(model: ctx.placed, tolerance: 0.1))
    }

    /// The roughing slot is 1.5 × the cutter wide, cut all the way through; beyond it the stock is untouched.
    @Test func trenchWidensTheSlot() throws {
        let op = trenchOp(tabs: false)
        let ctx = context(op)
        let tp = try ctx.generate(op)
        let (sim, a) = simulate(tp, ctx)
        #expect(a.gougeCells == 0)
        #expect(tp.warnings.allSatisfy { !$0.contains("trench") })
        let b = ctx.placed.modelBounds
        let x = b.min.x + 30
        // From the wall: 6 mm cutter + 0.5 mm roughing allowance + 3 mm trench = 9.5 mm.
        for d in [0.5, 3, 6, 9.2] {
            #expect(sim.stock.nearest(V2(x, b.min.y - d)) <= 0.01, "not cut through \(d) mm from the wall")
        }
        #expect(sim.stock.nearest(V2(x, b.min.y - 10.2)) > Float(ctx.stockTop) - 0.01)

        // Without the trench the slot stops at 6.5 mm.
        var plain = op
        plain.cutoutTrenchSettings.enabled = false
        let (simPlain, _) = simulate(try ctx.generate(plain), ctx)
        #expect(simPlain.stock.nearest(V2(x, b.min.y - 8)) > Float(ctx.stockTop) - 0.01)
    }

    /// Every roughing level cuts the outer pass first, then the pass at the part, without lifting out in between.
    @Test func outerPassThenInnerAtEveryLevel() throws {
        let op = trenchOp()
        let ctx = context(op)
        let tp = try ctx.generate(op)
        let R = op.tool.radius
        var firstOuter: [Double: Int] = [:], firstInner: [Double: Int] = [:], finish = Set<Double>()
        var prevZ = Double.nan
        for (i, m) in tp.moves.enumerated() {
            defer { prevZ = m.to.z }
            guard m.kind == .feed, m.to.z == prevZ, abs(m.to.z - op.tabs.height) > 1e-6, m.to.z < ctx.stockTop - 0.1 else { continue }
            let d = Double(ctx.silhouetteDistance.sample(m.to.xy))
            let z = (m.to.z * 100).rounded() / 100
            if abs(d - (R + 3.5)) < 0.2 { firstOuter[z] = firstOuter[z] ?? i }
            else if abs(d - (R + 0.5)) < 0.2 { firstInner[z] = firstInner[z] ?? i }
            else if abs(d - R) < 0.2 { finish.insert(z) }
            else if d > R + 0.7 && d < R + 3.3 { continue }  // crossing between the passes
            else { Issue.record("Cut at unexpected offset \(d)") }
        }
        #expect(firstOuter.count == 10)
        #expect(Set(firstOuter.keys) == Set(firstInner.keys))
        for (z, i) in firstOuter { #expect(i < firstInner[z]!, "inner before outer at z \(z)") }
        #expect(finish.count == 3)
        // No more retracts than without the trench: none between passes or levels.
        var plain = op
        plain.cutoutTrenchSettings.enabled = false
        func retracts(_ t: Toolpath) -> Int { t.moves.filter { $0.kind == .rapid && $0.to.z >= ctx.safeZ - 1e-6 }.count }
        #expect(retracts(tp) == retracts(try ctx.generate(plain)))
    }

    /// Tabs span the whole width of the trench, so the part stays joined to the stock.
    @Test func tabsCrossTheWholeTrench() throws {
        let op = trenchOp()
        let ctx = context(op)
        let tp = try ctx.generate(op)
        let (sim, a) = simulate(tp, ctx)
        #expect(a.gougeCells == 0)
        let b = ctx.placed.modelBounds
        let anchors = ctx.tabAnchors(op, finishLoops: ctx.cutoutLoops(op))
        #expect(anchors.count == 4)
        for p in anchors {
            // Outward normal of the side the tab sits on.
            let n: V2 = p.y < b.min.y ? V2(0, -1) : p.y > b.max.y ? V2(0, 1) : p.x < b.min.x ? V2(-1, 0) : V2(1, 0)
            let wall = n.x != 0 ? V2(n.x < 0 ? b.min.x : b.max.x, p.y) : V2(p.x, n.y < 0 ? b.min.y : b.max.y)
            for d in [0.5, 3, 6, 9] {
                #expect(sim.stock.nearest(wall + n * d) >= Float(op.tabs.height) - 0.15, "tab cut \(d) mm out at \(p)")
            }
        }
    }

    /// The pass next to the part runs faster (1.25× by default); the outer pass and the finishing pass don't.
    @Test func secondPassRunsFaster() throws {
        let op = trenchOp()
        let ctx = context(op)
        let tp = try ctx.generate(op)
        let R = op.tool.radius, F = op.cutting.feed
        var seen = Set<String>()
        var prev = tp.start
        for m in tp.moves {
            defer { prev = m.to }
            // Moves along a pass, not the short crossings between passes (which run at the normal feed).
            guard m.kind == .feed, m.to.z < op.tabs.height - 0.1 else { continue }
            let d = Double(ctx.silhouetteDistance.sample(m.to.xy))
            guard abs(Double(ctx.silhouetteDistance.sample(prev.xy)) - d) < 0.2 else { continue }
            if abs(d - (R + 0.5)) < 0.2 { #expect(abs(m.feed - F * 1.25) < 1e-6); seen.insert("inner") }
            else if abs(d - (R + 3.5)) < 0.2 { #expect(abs(m.feed - F) < 1e-6); seen.insert("outer") }
            else if abs(d - R) < 0.2 { #expect(abs(m.feed - F) < 1e-6); seen.insert("finish") }
        }
        #expect(seen == ["inner", "outer", "finish"])
        var same = op
        same.cutoutTrenchSettings.innerFeedFactor = 1
        let slow = try ctx.generate(same)
        #expect(slow.moves.allSatisfy { $0.kind != .feed || abs($0.feed - F) < 1e-6 })
        let t = { (x: Toolpath) in x.stats(rapidRate: 5000, acceleration: 500).seconds }
        #expect(t(tp) < t(slow))
        // Out-of-range values are clamped; old trench settings without it get the default.
        same.cutoutTrenchSettings.innerFeed = 9
        #expect(same.cutoutTrenchSettings.innerFeedFactor == 2)
        #expect(CutoutTrench().innerFeedFactor == 1.25)
    }

    /// A hole too small for the trench is cut as a plain slot, and the warning says so.
    @Test func smallHoleFallsBackToAPlainSlot() throws {
        let walls: [(V2, V2)] = [(V2(0, 0), V2(50, 19)), (V2(0, 31), V2(50, 50)), (V2(0, 19), V2(19, 31)), (V2(31, 19), V2(50, 31))]
        let mesh = STL.merge(walls.map { lo, hi in STL.box(V3(hi.x - lo.x, hi.y - lo.y, 10), at: V3(lo.x, lo.y, 0)) })
        var op = trenchOp(tabs: false)
        op.cutting.stepdown = 3
        let ctx = context(op, mesh: mesh)
        let tp = try ctx.generate(op)
        #expect(tp.warnings.contains { $0.contains("One outline has no room for the trench") })
        #expect(simulate(tp, ctx).1.gougeCells == 0)
        // The outer profile still gets its trench.
        let R = op.tool.radius
        #expect(tp.moves.contains { $0.kind == .feed && $0.to.z < 5 && abs(Double(ctx.silhouetteDistance.sample($0.to.xy)) - (R + 3.5)) < 0.2 })
    }

    @Test func offByDefaultAndOldProjectsStillOpen() throws {
        let op = CAMCore.Operation(kind: .cutout, tool: tool)
        #expect(!op.cutoutTrenchSettings.enabled)
        #expect(op.trenchExtra == 0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
        json.removeValue(forKey: "cutoutTrench")
        let old = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.cutoutTrench == nil)
        let on = trenchOp()
        let back = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONEncoder().encode(on))
        #expect(back.cutoutTrenchSettings == on.cutoutTrenchSettings)
    }

    /// Side B and dowel holes know the slot is wider.
    @Test func slotWidthIncludesTheTrench() {
        var op = trenchOp()
        #expect(abs(op.cutoutSlotWidth - (6 + 0.5 + 3)) < 1e-9)
        op.cutoutTrenchSettings.widthFactor = 99
        #expect(abs(op.trenchExtra - 12) < 1e-9)
        let ctx = context(trenchOp())
        let plain = CAMCore.Operation(kind: .cutout, tool: tool)
        let wide = ctx.frameProtection(cutouts: [trenchOp()])!.slotOuter
        let narrow = ctx.frameProtection(cutouts: [plain])!.slotOuter
        #expect(abs(wide - narrow - 3) < 1e-9)
    }
}
