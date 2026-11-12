import Foundation
import simd

/// Rest machining: what a smaller tool can still cut after a larger one has done its work.
///
/// The larger ("reference") tool's field gives the lowest surface it can leave: at each cell, the lowest point of the
/// cutter over every placement that covers the cell (a grey-scale erosion of its tool field). The same for this
/// operation's tool gives the surface it can leave. Where the reference leaves material more than `tolerance` above
/// the smaller tool's surface, there is something to cut: tight inside corners, slots narrower than the reference tool,
/// concave curves tighter than it. Tool positions whose cutter touches any of that material may cut; everything else
/// is left alone. Both fields use this operation's own boundary, floor, depth limit and stock to leave, so the larger
/// tool is assumed to have cleared the same area.
public struct RestField: Sendable {
    /// For each tool position: the top (Z) of the leftover material its cutter would touch, or `Grid2D.none` where it
    /// touches none.
    public let materialTop: Grid2D
    /// Plan area (mm²) of leftover material this tool can remove.
    public let leftoverArea: Double
    /// Thickest leftover this tool can remove (mm).
    public let maxThickness: Double
    /// Plan area (mm²) of leftover material only a longer tool could remove: the shank, wider than the cutter, would hit
    /// a wall above the flutes.
    public let unreachableArea: Double
    /// Thickest such material (mm).
    public let unreachableDepth: Double

    /// True where the cutter would touch leftover material.
    public func touches(_ p: V2) -> Bool { materialTop.nearest(p) > Grid2D.none / 2 }
}

extension CAMContext {
    /// Leftover thinner than this (mm) is ignored: grid noise, and not worth a pass.
    static let restTolerance: Float = 0.1

    /// The lowest surface a tool can leave when it goes everywhere its field allows: at each cell, the lowest point of
    /// the cutter over every placement covering it. Capped at the stock top (there is never material above it).
    func machinedSurface(_ T: Grid2D, tool: Tool, extraRadius: Double) -> Grid2D {
        let neg = T.map { $0 >= Grid2D.forbidThreshold ? Grid2D.none : -$0 }
        let d = ToolDilation.dilate(neg, tool: tool, extraRadius: extraRadius)
        let top = Float(stockTop)
        return d.map { v in v <= Grid2D.none / 2 ? top : min(top, -v) }
    }

    /// The leftover material for a rest-machining operation (nil when `op.restFrom` is not set). Cached.
    public func restField(_ op: Operation) -> RestField? {
        guard op.kind.supportsRest, let ref = op.restFrom else { return nil }
        var refOp = op
        refOp.tool = ref
        refOp.restFrom = nil
        let key = fieldKey(op) + "#rest#" + fieldKey(refOp) + "\(ref.shankDiameter)/\(ref.fluteLength)"
        lock.lock()
        if let r = restCache[key] { lock.unlock(); return r }
        lock.unlock()

        let leave = op.stockToLeaveXY
        let Ts = toolField(op)
        let R = machinedSurface(toolField(refOp), tool: ref, extraRadius: leave)
        let S = machinedSurface(Ts, tool: op.tool, extraRadius: leave)
        // The same tool without its shank shows what only the shank stops it reaching.
        var S0 = S
        if op.tool.hasWideShank {
            var bare = op
            bare.tool.shankDiameter = op.tool.diameter
            S0 = machinedSurface(toolField(bare), tool: bare.tool, extraRadius: leave)
        }
        let tol = Self.restTolerance
        let cell = Ts.res * Ts.res
        var src = [Float](repeating: Grid2D.none, count: Ts.data.count)
        var area = 0.0, unreachable = 0.0, unreachableDepth: Float = 0, thickest: Float = 0
        for i in src.indices {
            let r = R.data[i], s = S.data[i]
            if r - s > tol { src[i] = r; area += cell; thickest = max(thickest, r - s) }
            let s0 = S0.data[i]
            if r - s0 > tol && s - s0 > tol {
                unreachable += cell
                unreachableDepth = max(unreachableDepth, min(r, s) - s0)
            }
        }
        // Positions whose cutter (plus a cell, so the edge of the material is always taken) touches leftover material.
        let reach = op.tool.radius + leave + Ts.res
        let top = ToolDilation.dilate(Grid2D(like: Ts, data: src), kernel: ToolDilation.disc(radius: reach, res: Ts.res))
        let field = RestField(materialTop: top, leftoverArea: area, maxThickness: Double(thickest), unreachableArea: unreachable, unreachableDepth: Double(unreachableDepth))
        lock.lock(); restCache[key] = field; lock.unlock()
        return field
    }

    /// What a rest-machining operation should tell the user, or nil.
    func restWarning(_ op: Operation) -> String? {
        guard let ref = op.restFrom, let rf = restField(op) else { return nil }
        var parts: [String] = []
        if rf.leftoverArea < 0.5 {
            parts.append(String(format: "Nothing left for this tool: the Ø%g mm %@ already reaches everywhere it can.", ref.diameter,
                                ref.kind.displayName.lowercased()))
        }
        if rf.unreachableArea >= 0.5 {
            parts.append(String(format: "About %.0f mm² of leftover, up to %.1f mm thick, is too deep for this tool: its Ø%g mm shank would hit the wall above its %g mm flutes. A bit with longer flutes can reach it.",
                                rf.unreachableArea, rf.unreachableDepth, op.tool.shankDiameter, op.tool.fluteLength))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// How much a smaller tool could clear after `op` (plan area mm², and the thickest leftover in mm), for suggesting
    /// rest machining. Nil when the operation can't use it.
    public func restPotential(after op: Operation, with smaller: Tool) -> (area: Double, maxThickness: Double)? {
        guard op.kind.supportsRest, op.restFrom == nil else { return nil }
        if op.machiningSide != side {
            guard op.machiningSide == .b, job.activeFlip != nil else { return nil }
            return sideB.restPotential(after: op, with: smaller)
        }
        var rest = op
        rest.tool = smaller
        rest.restFrom = op.tool
        guard let rf = restField(rest) else { return nil }
        return (rf.leftoverArea, rf.maxThickness)
    }
}
