import Foundation
import Testing
import simd
@testable import CAMCore

@Suite struct RestMachiningTests {
    let lib = ToolLibrary.starter

    /// A 60 × 50 plate with a 40 × 30 cavity, 14 mm deep with square inside corners, and a slot 4 mm wide and 6 mm long
    /// off its right-hand side. The floor is at z = 6, the wall tops at z = 20.
    static let walls: [(V2, V2)] = [
        (V2(0, 0), V2(60, 10)), (V2(0, 40), V2(60, 50)), (V2(0, 10), V2(10, 40)),
        (V2(50, 10), V2(60, 23)), (V2(50, 27), V2(60, 40)), (V2(56, 23), V2(60, 27)),
    ]

    static func cavityPlate() -> Mesh {
        STL.merge([STL.box(V3(60, 50, 6))] + walls.map { lo, hi in STL.box(V3(hi.x - lo.x, hi.y - lo.y, 14), at: V3(lo.x, lo.y, 6)) })
    }

    /// XY distance (model coordinates) from `p` to the nearest wall.
    static func wallDistance(_ p: V2) -> Double {
        var best = Double.infinity
        for (lo, hi) in walls {
            let d: V2 = simd_max(simd_max(lo - p, p - hi), V2.zero)
            best = min(best, simd_length(d))
        }
        return best
    }

    func job(_ ops: [CAMCore.Operation]) -> Job {
        var j = Job()
        j.quality = .draft
        j.operations = ops
        return j
    }

    func cutPoints(_ tp: Toolpath) -> [V3] { tp.moves.filter { $0.kind != .rapid }.map(\.to) }

    func simulate(_ tps: [Toolpath], _ ctx: CAMContext) -> StockSimulator.Analysis {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        return sim.analyze(model: ctx.placed, tolerance: 0.1)
    }

    /// A 2 mm bit after a 6 mm one cuts only the corners and the slot, clears most of what was left, and doesn't gouge.
    @Test func restClearsCornersAndTheSlotOnly() throws {
        let big = CAMCore.Operation(kind: .pocket, tool: lib.tools[0])
        var small = ToolLibrary.smallFlats[0]
        small.shankDiameter = small.diameter  // shank modelling is tested separately
        small.fluteLength = 20
        var rest = CAMCore.Operation(kind: .pocket, tool: small)
        rest.restFrom = big.tool
        let full = CAMCore.Operation(kind: .pocket, tool: small)
        let ctx = CAMContext(raw: Self.cavityPlate(), job: job([big, rest]))
        let tpBig = try ctx.generate(big), tpRest = try ctx.generate(rest), tpFull = try ctx.generate(full)

        let before = simulate([tpBig], ctx), after = simulate([tpBig, tpRest], ctx)
        #expect(after.gougeCells == 0)
        #expect(before.leftoverCells > 100)
        #expect(Double(after.leftoverCells) < Double(before.leftoverCells) * 0.2, "leftover \(before.leftoverCells) → \(after.leftoverCells)")

        // Every cut is near a corner of the cavity or in the slot.
        let o = ctx.placed.modelBounds.min.xy
        let corners = [V2(10, 10), V2(50, 10), V2(10, 40), V2(50, 40), V2(50, 23), V2(50, 27)]
        for p in cutPoints(tpRest) where p.z < ctx.stockTop - 0.01 {
            let m = p.xy - o
            let nearCorner = corners.contains { simd_distance($0, m) < 4.5 }
            #expect(nearCorner || m.x > 47, "rest cut at \(m.x), \(m.y)")
        }
        // Far less cutting than pocketing the whole cavity with the small bit.
        let restLen = tpRest.stats(rapidRate: 5000, acceleration: 500).cutLength
        let fullLen = tpFull.stats(rapidRate: 5000, acceleration: 500).cutLength
        #expect(restLen < fullLen * 0.25, "rest \(restLen) mm vs full \(fullLen) mm")
        // One corner at a time, top to bottom: few retracts to the safe height, not one per corner per level.
        let retracts = tpRest.moves.filter { $0.kind == .rapid && $0.to.z >= ctx.safeZ - 1e-6 }.count
        #expect(retracts < 20, "\(retracts) retracts")
    }

    /// A 0.9 mm bit on a 4 mm shank with 3 mm flutes keeps its shank off the walls: near a wall it only reaches 3 mm
    /// down, and it says the rest is out of reach.
    @Test func wideShankStaysOffTheWalls() throws {
        let big = CAMCore.Operation(kind: .pocket, tool: lib.tools[0])
        let tiny = try #require(ToolLibrary.smallFlats.first { $0.diameter == 0.9 && $0.shankDiameter == 4 })
        var rest = CAMCore.Operation(kind: .pocket, tool: tiny)
        rest.restFrom = big.tool
        let ctx = CAMContext(raw: Self.cavityPlate(), job: job([big, rest]))
        let tp = try ctx.generate(rest)
        #expect(!tp.moves.isEmpty)
        let o = ctx.placed.modelBounds.min.xy
        let wallTop = ctx.placed.modelBounds.max.z
        var deepNearWall = 0
        for p in cutPoints(tp) {
            let d = Self.wallDistance(p.xy - o)
            #expect(d >= tiny.radius - 0.05, "cutter in the wall at \(p)")
            if p.z < wallTop - tiny.fluteLength - 0.05 && d < tiny.shankDiameter / 2 - 0.05 { deepNearWall += 1 }
        }
        #expect(deepNearWall == 0)
        #expect(tp.warnings.contains { $0.contains("too deep for this tool") })
        #expect(!tp.warnings.contains { $0.contains("exceeds the tool's flute length") })
        #expect(simulate([try ctx.generate(big), tp], ctx).gougeCells == 0)
    }

    /// Rest finishing with a smaller ball only runs where the larger ball left material: along the inside of the walls.
    @Test func restFinishingStaysInTheCorners() throws {
        let big = try #require(lib.closest(kind: .ball, diameter: 6))
        let small = try #require(lib.closest(kind: .ball, diameter: 3))
        var op = CAMCore.Operation(kind: .parallelFinish, tool: small)
        op.boundary = .insideSilhouette
        op.cutting.stepoverPercent = 20
        var full = op
        op.restFrom = big
        let ctx = CAMContext(raw: Self.cavityPlate(), job: job([op]))
        let tp = try ctx.generate(op)
        full.restFrom = nil
        let tpFull = try ctx.generate(full)
        #expect(!tp.moves.isEmpty)
        let o = ctx.placed.modelBounds.min.xy
        for p in cutPoints(tp) where p.z < ctx.stockTop - 0.01 {
            let m = p.xy - o
            #expect(Self.wallDistance(m) < big.radius + small.radius + 1, "rest finish at \(m.x), \(m.y)")
        }
        #expect(tp.stats(rapidRate: 5000, acceleration: 500).cutLength < tpFull.stats(rapidRate: 5000, acceleration: 500).cutLength * 0.6)
        #expect(simulate([tp], ctx).gougeCells == 0)
    }

    /// Nothing to do when the "larger" tool is no larger.
    @Test func sameSizeLeavesNothing() throws {
        var op = CAMCore.Operation(kind: .pocket, tool: lib.tools[0])
        op.restFrom = lib.tools[0]
        let ctx = CAMContext(raw: Self.cavityPlate(), job: job([op]))
        let tp = try ctx.generate(op)
        #expect(tp.moves.filter { $0.kind != .rapid && $0.to.z < ctx.stockTop - 0.01 }.isEmpty)
        #expect(tp.warnings.contains { $0.contains("Nothing left") })
    }

    @Test func suggestsRestMachiningForSquareCorners() throws {
        let big = CAMCore.Operation(kind: .pocket, tool: lib.tools[0])
        let ctx = CAMContext(raw: Self.cavityPlate(), job: job([big]))
        let p = try #require(ctx.restPotential(after: big, with: ToolLibrary.smallFlats[0]))
        #expect(p.area > 10)
        #expect(p.maxThickness > 10)
    }

    @Test func oldProjectsHaveNoRestMachining() throws {
        let op = CAMCore.Operation(kind: .pocket, tool: lib.tools[0])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
        #expect(json["restFrom"] == nil)
        json.removeValue(forKey: "restFrom")
        let old = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.restFrom == nil)
        var withRest = op
        withRest.restFrom = lib.tools[0]
        let back = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONEncoder().encode(withRest))
        #expect(back.restFrom == lib.tools[0])
    }

    @Test func starterLibraryHasSmallBitsOnBothShanks() {
        for d in [2.0, 1.0, 0.9] {
            for shank in [3.175, 4.0] {
                #expect(lib.tools.contains { $0.kind == .flat && $0.diameter == d && $0.shankDiameter == shank && $0.hasWideShank })
            }
        }
        #expect(Set(lib.tools.map(\.number)).count == lib.tools.count)
    }
}
