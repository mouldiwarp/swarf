import Foundation
import simd

public enum PeckRetract: String, Codable, Sendable, CaseIterable {
    /// Back out above the stock after every peck: clears chips, best for deep holes.
    case full
    /// Lift slightly to snap the chip, then carry on: faster, fine for shallow holes.
    case chipBreak
    public var displayName: String { self == .full ? "Full retract" : "Chip break" }
}

public struct DrillSettings: Codable, Sendable, Equatable, Hashable {
    public var retract: PeckRetract = .full
    /// Lift (mm) for chip-break pecks.
    public var chipBreakLift = 0.5
    /// Drill holes whose diameter is within ± this of the tool diameter (mm).
    public var diameterTolerance = 0.5
    public init() {}
}

/// A round vertical hole found in the model. Coordinates are stock space.
public struct Hole: Sendable, Equatable {
    public var center: V2
    public var diameter: Double
    /// Z of the surface the hole opens from.
    public var rimZ: Double
    /// Z of the hole floor, nil when it goes right through the model.
    public var floorZ: Double?
}

extension CAMContext {
    /// Finds round vertical holes by contouring the top-down height map at every flat face level.
    public func detectHoles() -> [Hole] {
        let h = heights
        let res = h.res
        var found: [Hole] = []
        for level in flatLevels.reversed() {
            let L = Float(level) - 0.02
            let mask = h.map { $0 >= L ? 1 : 0 }
            guard let loops = Contours.isolines(mask, levels: [0.5]).first else { continue }
            for loop in loops where loop.signedArea < 0 && loop.points.count >= 8 {
                // Holes in material run clockwise. Fit a circle and check the loop is round.
                let n = Double(loop.points.count)
                let c = loop.points.reduce(V2.zero, +) / n
                let radii = loop.points.map { $0.dist(c) }
                let r = radii.reduce(0, +) / n
                guard r >= max(0.5, res), r <= 60 else { continue }
                guard (radii.max()! - radii.min()!) <= max(2.5 * res, 0.08 * r) else { continue }
                guard abs(abs(loop.signedArea) - .pi * r * r) <= 0.15 * .pi * r * r else { continue }
                // The inside must be lower than the rim (not a boss).
                guard h.nearest(c) < L else { continue }
                // Floor: lowest surface across the hole; none = through.
                var floor: Float = .infinity
                var through = false
                let k = Int((r * 0.7 / res).rounded(.down))
                let cc = h.cellCoord(c)
                let cx = Int(cc.x.rounded()), cy = Int(cc.y.rounded())
                for dy in -k...k {
                    for dx in -k...k where Double(dx * dx + dy * dy) * res * res <= r * r * 0.49 {
                        let x = cx + dx, y = cy + dy
                        guard x >= 0, y >= 0, x < h.width, y < h.height else { continue }
                        let v = h[x, y]
                        if v <= Grid2D.none / 2 { through = true } else { floor = min(floor, v) }
                    }
                }
                // The height map stamps walls conservatively (about half a cell into the hole each side).
                // A floor level with the model's underside means the hole goes right through.
                if !floor.isFinite || Double(floor) <= placed.modelBounds.min.z + 0.01 { through = true }
                let hole = Hole(center: c, diameter: 2 * r + res, rimZ: level, floorZ: through ? nil : Double(floor))
                if let i = found.firstIndex(where: { $0.center.dist(c) < max(0.5, res * 2) }) {
                    // Same axis seen from another level (e.g. a counterbore): keep both sizes as separate holes
                    // only if they differ in diameter.
                    if abs(found[i].diameter - hole.diameter) < 2 * res {
                        if (hole.floorZ ?? -1e9) < (found[i].floorZ ?? -1e9) { found[i].floorZ = hole.floorZ }
                        continue
                    }
                }
                found.append(hole)
            }
        }
        return found
    }

    func drill(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        guard op.tool.kind != .vBit else { throw CAMError.nothingToCut("Choose a drill or end mill for drilling, not a V-bit.") }
        let s = op.drillSettings
        let all = detectHoles()
        guard !all.isEmpty else { throw CAMError.nothingToCut("No round holes found in the model.") }
        let D = op.tool.diameter
        let R = op.tool.radius
        var holes: [Hole] = []
        var otherSizes: [Double] = []
        var blocked = 0
        for hole in all {
            guard abs(hole.diameter - D) <= s.diameterTolerance + 1e-9 else { otherSizes.append(hole.diameter); continue }
            let bottom = holeBottom(hole, op)
            if isForbiddenXY(hole.center, z: bottom, op: op, inflate: R) { blocked += 1; continue }
            holes.append(hole)
        }
        var warnings: [String] = []
        if !otherSizes.isEmpty {
            let sizes = Set(otherSizes.map { ($0 * 10).rounded() / 10 }).sorted().map { String(format: "%.1f", $0) }.joined(separator: ", ")
            warnings.append(String(format: "Skipped %d hole%@ that %@ match the Ø%.3g mm tool (Ø %@ mm). The cutout cuts larger through holes; use a pocket for larger blind holes.",
                                   otherSizes.count, otherSizes.count == 1 ? "" : "s", otherSizes.count == 1 ? "doesn't" : "don't", D, sizes))
        }
        if blocked > 0 { warnings.append("Skipped \(blocked) hole\(blocked == 1 ? "" : "s") inside keep-out regions.") }
        guard !holes.isEmpty else {
            throw CAMError.nothingToCut(String(format: "No holes match the Ø%.3g mm tool (±%.2g mm). %@", D, s.diameterTolerance,
                                               warnings.first ?? ""))
        }

        // Nearest-neighbour order from the origin.
        var order: [Hole] = []
        var here = V2.zero
        var left = holes
        while !left.isEmpty {
            let i = left.indices.min { left[$0].center.dist(here) < left[$1].center.dist(here) }!
            let next = left.remove(at: i)
            order.append(next); here = next.center
        }

        var b = builder(op)
        let top = stockTop
        let rPlane = min(safeZ, top + 1)
        let peck = max(0.1, op.cutting.stepdown)
        let lift = max(0.1, s.chipBreakLift)
        for (k, hole) in order.enumerated() {
            let c = hole.center
            let bottom = holeBottom(hole, op)
            if b.pos.z < safeZ - 1e-9 { b.retract() }
            b.rapid(V3(c.x, c.y, safeZ))
            b.rapid(V3(c.x, c.y, rPlane))
            var depth = top
            while depth > bottom + 1e-6 {
                let target = max(bottom, depth - peck)
                if depth < top - 1e-9 && s.retract == .full {
                    b.rapid(V3(c.x, c.y, min(rPlane, depth + 0.5)))
                }
                b.cut(V3(c.x, c.y, target))
                depth = target
                if depth > bottom + 1e-6 {
                    b.rapid(V3(c.x, c.y, s.retract == .full ? rPlane : min(rPlane, depth + lift)))
                }
            }
            b.rapid(V3(c.x, c.y, rPlane))
            progress?(Double(k + 1) / Double(order.count))
        }
        b.retract()
        var tp = makeToolpath(op, b)
        tp.warnings = warnings
        return tp
    }

    /// Tip Z for a hole: its floor (plus Z stock to leave), or below the stock for through holes.
    func holeBottom(_ hole: Hole, _ op: Operation) -> Double {
        let limit = testCutFloor(op) ?? -.infinity
        if let f = hole.floorZ { return max(limit, f + op.stockToLeaveZ) }
        var z = -op.throughDepth
        if op.tool.kind == .drill {
            // Bring the full diameter out of the bottom face, not just the point.
            z -= max(0, op.tool.radius - op.tool.tipDiameter / 2) / tan(max(1, op.tool.vAngle / 2) * .pi / 180)
        }
        return max(limit, z)
    }
}
