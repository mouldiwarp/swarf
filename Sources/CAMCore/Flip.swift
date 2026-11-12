import Foundation
import simd

/// The face of the stock an operation machines in a two-sided (flip) job.
public enum MachiningSide: String, Codable, Sendable, CaseIterable {
    /// The top, machined first. The part is cut out from this side.
    case a
    /// The back, machined after the stock is rolled over onto the dowels.
    case b
    public var displayName: String { self == .a ? "Side A (top)" : "Side B (back)" }
}

/// Two-sided machining with dowel registration.
///
/// 1. Dowel holes are drilled through the stock and into the spoilboard on the stock's Y centre line.
/// 2. Side A (the top) is machined and the part cut out with tabs.
/// 3. The stock is rolled 180° about the X axis (front and back edges swap, the ends stay put) and dropped over
///    dowels in the spoilboard holes.
/// 4. Side B (the back) is machined.
///
/// The roll maps the stock rectangle onto itself, so every work zero keeps its machine position; only Z is
/// re-probed. In stock space side B sees (x, y, z) → (x, W − y, T − z).
public struct FlipSetup: Codable, Sendable, Equatable, Hashable {
    public var enabled = false
    /// How far the dowel holes go into the spoilboard below the stock (mm).
    public var spoilboardDepth = 5.0
    /// Extra clearance (mm) between a dowel hole and the cutout slot around the part.
    public var clearance = 3.0
    public init() {}
}

/// One step of a two-sided job, in the order it runs.
public enum FlipStage: Int, Sendable, Comparable, CaseIterable {
    case dowels, sideA, sideB
    public static func < (a: FlipStage, b: FlipStage) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .dowels: return "Dowel holes"
        case .sideA: return "Side A (top)"
        case .sideB: return "Side B (back)"
        }
    }

    var fileTag: String {
        switch self {
        case .dowels: return "dowels"
        case .sideA: return "sideA"
        case .sideB: return "sideB"
        }
    }
}

extension Operation {
    /// Where this operation runs in a two-sided job.
    public var flipStage: FlipStage { kind == .dowelHoles ? .dowels : machiningSide == .b ? .sideB : .sideA }
}

extension Toolpath {
    public var flipStage: FlipStage { kind == .dowelHoles ? .dowels : side == .b ? .sideB : .sideA }

    /// The same moves seen from the other side of the stock: rolled 180° about the stock's X centre line.
    /// Maps side-B machine coordinates onto the side-A view of the part (and back again).
    public func rolledAboutX(stockSize s: V3) -> Toolpath {
        var t = self
        func r(_ p: V3) -> V3 { V3(p.x, s.y - p.y, s.z - p.z) }
        t.start = r(start)
        t.moves = moves.map { m in
            var k = m.kind
            if k == .arcCW { k = .arcCCW } else if k == .arcCCW { k = .arcCW }  // mirroring Y reverses arcs
            return Move(k, r(m.to), feed: m.feed, center: m.center.map { V2($0.x, s.y - $0.y) })
        }
        return t
    }
}

extension PlacedModel {
    /// The placed model as the machine sees it after the stock is rolled about X: same stock, part upside down
    /// and front-to-back. An exact transform of this placement, so both sides line up.
    public func rolledAboutX() -> PlacedModel {
        let roll = Rotation(simd_double3x3(diagonal: V3(1, -1, -1)))
        let m = mesh.transformed(rotation: roll, translation: V3(0, stockSize.y, stockSize.z))
        return PlacedModel(mesh: m, stockSize: stockSize)
    }

    init(mesh: Mesh, stockSize: V3) {
        self.mesh = mesh
        self.stockSize = stockSize
        modelBounds = mesh.bounds
    }
}

/// What side-B operations must leave alone: the stock frame around the part (it holds the dowels and the clamps)
/// and the tabs that side A's cutout left holding the part. Distances are from the model silhouette.
struct FrameProtection: Sendable {
    /// Beyond this distance from the part the stock was never cut: the frame.
    var slotOuter: Double
    /// Tab centres (side-B stock space) and the radius that covers each tab.
    var tabs: [(center: V2, radius: Double)]

    func protects(_ p: V2, silhouetteDistance d: Float) -> Bool {
        if Double(d) > slotOuter { return true }
        guard d > 0 else { return false }
        return tabs.contains { simd_distance_squared($0.center, p) <= $0.radius * $0.radius }
    }
}

extension CAMContext {
    /// Side-A cutouts in the job: they decide the slot around the part and where the tabs are.
    func sideACutouts(_ ops: [Operation]) -> [Operation] {
        ops.filter { $0.enabled && $0.kind == .cutout && $0.machiningSide == .a }
    }

    /// The frame and tabs, in side-B stock space, left by this (side A) context's cutouts.
    func frameProtection(cutouts: [Operation]) -> FrameProtection? {
        guard !cutouts.isEmpty else { return nil }
        var outer = 0.0
        var tabs: [(V2, Double)] = []
        let W = placed.stockSize.y
        for c in cutouts {
            let fin = c.cutoutFinishSettings
            let allowance = fin.enabled ? max(0, fin.allowance) : 0
            outer = max(outer, c.tool.diameter + max(0, c.stockToLeaveXY) + allowance + 0.5)
            guard c.tabs.enabled else { continue }
            let anchors = tabAnchors(c, finishLoops: cutoutLoops(c))
            let flank = c.tabs.shape == .triangular ? c.tabs.height : 0
            let r = c.tabs.width / 2 + flank + c.tool.diameter + 1
            for a in anchors { tabs.append((V2(a.x, W - a.y), r)) }
        }
        return FrameProtection(slotOuter: outer, tabs: tabs)
    }

    /// Side-B context for this side-A context, protecting the frame and tabs left by `cutouts`
    /// (default: the job's own side-A cutouts).
    public func makeSideB(cutouts: [Operation]? = nil) -> CAMContext {
        // Regions are drawn on the side-A view. Mirror them onto the back; a keep-out that only protected material
        // below a height on side A protects the whole column on side B.
        var j = job
        let W = placed.stockSize.y
        j.regions = job.regions.map { r in
            var m = r
            m.min = V2(r.min.x, W - r.max.y)
            m.max = V2(r.max.x, W - r.min.y)
            m.protectBelowZ = nil
            return m
        }
        return CAMContext(placed: placed.rolledAboutX(), job: j, side: .b,
                          protection: frameProtection(cutouts: sideACutouts(cutouts ?? job.operations)))
    }

    // MARK: Dowel holes

    /// Dowel hole centres (stock space, identical on both sides): on the stock's Y centre line, one in the waste
    /// beyond each end of the part. Throws with the room needed when the stock is too short.
    public func dowelPositions(toolDiameter D: Double) throws -> [V2] {
        guard side == .a else { throw CAMError.invalidSettings("Dowel holes are drilled before side A.") }
        let flip = job.flipSettings
        let s = placed.stockSize
        let yc = s.y / 2
        let slot = sideACutouts(job.operations).map { c -> Double in
            let fin = c.cutoutFinishSettings
            return c.tool.diameter + max(0, c.stockToLeaveXY) + (fin.enabled ? max(0, fin.allowance) : 0)
        }.max() ?? 6.5
        let r = D / 2
        let fromPart = r + slot + max(0, flip.clearance)
        let fromEnd = r + 2
        // Where the part crosses the centre line (the silhouette distance is exact enough here: we only need room).
        let sil = silhouetteDistance
        var lo = Double.infinity, hi = -Double.infinity
        let cy = Int(sil.cellCoord(V2(0, yc)).y.rounded())
        if cy >= 0 && cy < sil.height {
            for x in 0..<sil.width where sil[x, cy] <= 0 {
                let wx = sil.world(x, cy).x
                lo = min(lo, wx); hi = max(hi, wx)
            }
        }
        if !lo.isFinite { lo = placed.modelBounds.min.x; hi = placed.modelBounds.max.x }
        var out: [V2] = []
        for (end, gap) in [("left", (0.0, lo)), ("right", (hi, s.x))] {
            let x = (gap.0 + gap.1) / 2
            let p = V2(x, yc)
            let toPart = Double(sil.nearest(p))
            let toEnd = min(x, s.x - x)
            guard toPart >= fromPart - 1e-6, toEnd >= fromEnd - 1e-6 else {
                let need = 2 * fromPart
                throw CAMError.nothingToCut(String(format: "No room for a dowel hole at the %@ end: it needs about %.0f mm of stock between the part and the stock end on the centre line, and there is %.0f mm. Increase the stock margin or the stock length.",
                                                   end, need, max(0, gap.1 - gap.0)))
            }
            out.append(p)
        }
        return out
    }

    func dowelHoles(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        guard op.tool.kind == .flat || op.tool.kind == .drill else {
            throw CAMError.invalidSettings("\(op.name): use a flat end mill or a drill for dowel holes.")
        }
        let centres = try dowelPositions(toolDiameter: op.tool.diameter)
        let spoil = max(0, job.flipSettings.spoilboardDepth)
        var bottom = -spoil
        if op.tool.kind == .drill {
            bottom -= max(0, op.tool.radius - op.tool.tipDiameter / 2) / tan(max(1, op.tool.vAngle / 2) * .pi / 180)
        }
        if let f = depthFloor(op) { bottom = max(bottom, f) }
        let depth = stockTop - bottom
        // The cutter must reach through the stock without the collet touching it.
        if depth > op.tool.fluteLength + 1e-6 {
            throw CAMError.invalidSettings(String(format: "%@: the holes are %.1f mm deep (%.1f mm stock + %.1f mm into the spoilboard), but %@ only cuts %.1f mm. Use thinner stock, a longer cutter, or less spoilboard depth.",
                                                  op.name, depth, stockTop, spoil, op.tool.name, op.tool.fluteLength))
        }
        var b = builder(op)
        peckHoles(centres.map { ($0, bottom) }, op: op, b: &b, progress: progress)
        var tp = makeToolpath(op, b)
        if depth > op.tool.fluteLength - 3 {
            tp.warnings.append(String(format: "Holes are %.1f mm deep, within %.1f mm of the %.1f mm flute length. Set the cutter's stick-out so the collet stays clear of the stock.",
                                      depth, op.tool.fluteLength - depth, op.tool.fluteLength))
        }
        return tp
    }
}
