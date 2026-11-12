import Foundation
import Testing
import simd
@testable import CAMCore

@Suite struct FlipTests {
    let lib = ToolLibrary.starter
    var flat6: Tool { lib.closest(kind: .flat, diameter: 6)! }

    /// 80 × 40 × 20 body: a 20 × 10 × 5 pocket in the top and a 16 × 10 × 6 cavity in the underside.
    func body(height: Double = 20) -> Mesh {
        let h = height
        return STL.merge([
            STL.box(V3(80, 40, h - 11), at: V3(0, 0, 6)),
            // underside layer (z 0–6) around the cavity at x 50–66, y 15–25
            STL.box(V3(50, 40, 6)), STL.box(V3(14, 40, 6), at: V3(66, 0, 0)),
            STL.box(V3(16, 15, 6), at: V3(50, 0, 0)), STL.box(V3(16, 15, 6), at: V3(50, 25, 0)),
            // top layer (z h-5 … h) around the pocket at x 14–34, y 15–25
            STL.box(V3(14, 40, 5), at: V3(0, 0, h - 5)), STL.box(V3(46, 40, 5), at: V3(34, 0, h - 5)),
            STL.box(V3(20, 15, 5), at: V3(14, 0, h - 5)), STL.box(V3(20, 15, 5), at: V3(14, 25, h - 5)),
        ])
    }

    func job(margin: Double = 30) -> Job {
        var j = Job()
        j.quality = .draft
        j.stock.marginXY = margin
        j.flipSettings.enabled = true
        return j
    }

    func ops() -> [CAMCore.Operation] {
        let dowels = CAMCore.Operation(kind: .dowelHoles, tool: flat6)
        var top = CAMCore.Operation(kind: .pocket, tool: flat6)
        top.name = "Top pocket"
        var cut = CAMCore.Operation(kind: .cutout, tool: flat6)
        cut.tabs.enabled = true
        var back = CAMCore.Operation(kind: .pocket, tool: flat6)
        back.name = "Back cavity"
        back.machiningSide = .b
        return [dowels, top, cut, back]
    }

    func context(_ ops: [CAMCore.Operation], job j: Job? = nil, mesh: Mesh? = nil) -> CAMContext {
        var j = j ?? job()
        j.operations = ops
        return CAMContext(raw: mesh ?? body(), job: j)
    }

    @Test func rolledPlacementIsTheExactMirror() {
        let ctx = context(ops())
        let a = ctx.placed, b = a.rolledAboutX()
        let s = a.stockSize
        #expect(abs(b.modelBounds.min.y - (s.y - a.modelBounds.max.y)) < 1e-3)
        #expect(abs(b.modelBounds.max.z - (s.z - a.modelBounds.min.z)) < 1e-3)
        #expect(abs(b.modelBounds.min.x - a.modelBounds.min.x) < 1e-6)
        #expect(b.stockSize == s)
        // Same machine position for the work zero on both sides.
        #expect(b.originPoint(.swarfDefault) == a.originPoint(.swarfDefault))
    }

    @Test func dowelHolesSitOnTheFlipAxisBeyondThePart() throws {
        let all = ops()
        let ctx = context(all)
        let tp = try ctx.generate(all[0])
        let s = ctx.placed.stockSize
        let cuts = tp.moves.filter { $0.kind != .rapid }
        #expect(!cuts.isEmpty)
        let xs = Set(cuts.map { ($0.to.x * 100).rounded() })
        #expect(xs.count == 2)
        for m in cuts {
            // On the roll axis, so each hole lands on itself after the flip.
            #expect(abs(m.to.y - s.y / 2) < 1e-9)
            #expect(m.to.x < ctx.placed.modelBounds.min.x - 10 || m.to.x > ctx.placed.modelBounds.max.x + 10)
        }
        // Through the stock and 5 mm into the spoilboard, with no "below the stock" warning.
        #expect(abs((cuts.map(\.to.z).min() ?? 0) + 5) < 1e-9)
        #expect(!tp.warnings.contains { $0.contains("below the stock") })
    }

    @Test func dowelsNeedRoomInTheStock() {
        let all = ops()
        let ctx = context(all, job: job(margin: 5))
        #expect(throws: CAMError.self) { try ctx.generate(all[0]) }
        do { _ = try ctx.generate(all[0]) } catch { #expect(error.localizedDescription.contains("No room for a dowel hole")) }
    }

    @Test func dowelDepthIsLimitedByTheCutter() throws {
        // 48 mm stock + 5 mm into the spoilboard is more than the 50 mm flute.
        let all = ops()
        let deep = context(all, mesh: body(height: 48))
        do {
            _ = try deep.generate(all[0])
            Issue.record("expected the dowel holes to be refused")
        } catch { #expect(error.localizedDescription.contains("only cuts 50")) }
        // 44 + 5 fits, with a warning that it is close.
        let near = try context(all, mesh: body(height: 44)).generate(all[0])
        #expect(near.warnings.contains { $0.contains("flute length") })
        // Less spoilboard depth makes 48 mm stock fit.
        var j = job()
        j.flipSettings.spoilboardDepth = 2
        #expect(throws: Never.self) { try context(all, job: j, mesh: body(height: 48)).generate(all[0]) }
    }

    @Test func sideBMachinesTheUndersideCavity() throws {
        let all = ops()
        let ctx = context(all)
        let tp = try ctx.generate(all[3])
        #expect(tp.side == .b)
        let s = ctx.placed.stockSize
        let mb = ctx.placed.modelBounds
        // Seen from side A, the cuts reach up into the cavity (ceiling 6 mm above the bottom) and stay inside it.
        let a = tp.rolledAboutX(stockSize: s)
        let cuts = a.moves.filter { $0.kind != .rapid && $0.to.z < s.z - 0.5 }
        #expect(!cuts.isEmpty)
        #expect(abs((cuts.map(\.to.z).max() ?? 0) - (mb.min.z + 6)) < 0.01)
        for m in cuts {
            #expect(m.to.x > mb.min.x + 50 - 1e-6 && m.to.x < mb.min.x + 66 + 1e-6)
            #expect(m.to.y > mb.min.y + 15 - 1e-6 && m.to.y < mb.min.y + 25 + 1e-6)
        }
    }

    @Test func twoSidedJobSimulatesWithoutGouges() throws {
        let all = ops()
        let ctx = context(all)
        let tps = try all.map { try ctx.generate($0) }
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        let a = sim.analyze(model: ctx.placed, tolerance: 0.1)
        #expect(a.gougeCells == 0, "max gouge \(a.maxGouge)")
        #expect(!a.undersideDeviation.isEmpty)
        // The cavity is cleared from below: the underside at its centre is at the cavity ceiling.
        let mb = ctx.placed.modelBounds
        let c = V2(mb.min.x + 58, mb.min.y + 20)
        let bottom = try #require(sim.bottom)
        #expect(abs(Double(bottom.nearest(c)) - (mb.min.z + 6)) < 0.1)
        // ...and the top pocket from above.
        #expect(abs(Double(sim.stock.nearest(V2(mb.min.x + 24, mb.min.y + 20))) - (mb.max.z - 5)) < 0.1)
    }

    @Test func sideBLeavesTheTabsAndFrame() throws {
        var all = ops()
        // 3D roughing on the back ranges around the part, right where the tabs are.
        var rough = CAMCore.Operation(kind: .roughing, tool: flat6)
        rough.machiningSide = .b
        rough.stockToLeaveXY = 0; rough.stockToLeaveZ = 0
        rough.boundaryMargin = 15  // wide enough to reach the tabs and the frame
        all.append(rough)
        let ctx = context(all)
        let cut = all[2]
        let tps = try [cut, rough].map { try ctx.generate($0) }
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        let bottom = try #require(sim.bottom)
        let anchors = ctx.tabAnchors(cut, finishLoops: ctx.cutoutLoops(cut))
        #expect(anchors.count == cut.tabs.countPerLoop)
        for p in anchors {
            let top = sim.stock.nearest(p), low = bottom.nearest(p)
            #expect(top - low > Float(cut.tabs.height) - 0.3, "tab at \(p) is \(top - low) mm thick")
        }
        // The frame is untouched from below.
        let frame = V2(ctx.placed.stockSize.x / 2, 4)
        #expect(bottom.nearest(frame) < 0.01)
        let a = sim.analyze(model: ctx.placed, tolerance: 0.1)
        #expect(a.gougeCells == 0, "max gouge \(a.maxGouge)")
    }

    @Test func onlySomeOperationsRunOnSideB() {
        let ctx = context(ops())
        for kind in [OperationKind.cutout, .facing, .vcarve] {
            var op = CAMCore.Operation(kind: kind, tool: kind == .vcarve ? lib.closest(kind: .vBit, diameter: 12) ?? flat6 : flat6)
            op.machiningSide = .b
            #expect(throws: CAMError.self) { try ctx.generate(op) }
        }
        // Without two-sided machining, side-B and dowel operations are refused rather than cut on the top.
        var j = job()
        j.flipSettings.enabled = false
        let off = context(ops(), job: j)
        #expect(throws: CAMError.self) { try off.generate(ops()[3]) }
        #expect(throws: CAMError.self) { try off.generate(ops()[0]) }
    }

    @Test func exportWritesOneSetOfFilesPerStep() throws {
        let all = ops()
        let ctx = context(all)
        let tps = try all.map { try ctx.generate($0) }
        let post = PostProcessor(profile: .workbeeRRF, origin: ctx.placed.originPoint(.swarfDefault), safeZ: ctx.safeZ,
                                 jobName: "Body", stockSize: ctx.placed.stockSize)
        // Side B comes last even if it is listed earlier.
        let files = post.process([tps[3], tps[0], tps[1], tps[2]])
        #expect(files.map(\.name) == ["Body_1_dowels.gcode", "Body_2_sideA.gcode", "Body_3_sideB.gcode"])
        #expect(files[2].content.contains("Re-probe Z"))
        #expect(files[2].toolpathIDs == [all[3].id])
        // Side-B coordinates are what the machine sees after the flip: the cavity is cut from the new top down.
        #expect(files[2].content.contains("Z-"))
        // A one-sided job keeps its old file names.
        #expect(post.process([tps[1], tps[2]]).map(\.name) == ["Body.gcode"])
    }

    @Test func fullProcessingAddsDowelsAndSideB() {
        let ctx = context([])
        let ops = JobTemplates.fullProcessing(ctx, library: lib, material: .named("mdf"))
        #expect(ops.first?.kind == .dowelHoles)
        let b = ops.filter { $0.machiningSide == .b }
        #expect(!b.isEmpty)
        #expect(b.allSatisfy { $0.kind.allowedOnSideB })
        #expect(ops.contains { $0.kind == .cutout && $0.machiningSide == .a })
        // Side B comes after side A.
        let lastA = ops.lastIndex { $0.machiningSide == .a && $0.kind != .dowelHoles }!
        #expect(ops.firstIndex { $0.machiningSide == .b }! > lastA)
    }

    @Test func oldProjectsOpenAsOneSided() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Job())) as! [String: Any]
        json.removeValue(forKey: "flip")
        let old = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.activeFlip == nil)
        var opJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CAMCore.Operation(kind: .pocket, tool: flat6))) as! [String: Any]
        opJSON.removeValue(forKey: "side")
        let op = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: opJSON))
        #expect(op.machiningSide == .a)
    }
}
