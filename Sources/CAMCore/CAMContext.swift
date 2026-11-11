import Foundation
import simd

public enum CAMError: Error, LocalizedError {
    case noModel
    case nothingToCut(String)

    public var errorDescription: String? {
        switch self {
        case .noModel: return "No model loaded."
        case .nothingToCut(let s): return s
        }
    }
}

public typealias ProgressHandler = @Sendable (Double) -> Void

/// Prepared geometry shared by every operation of a job.
public final class CAMContext: @unchecked Sendable {
    public let placed: PlacedModel
    public let job: Job
    /// Model top surface; `Grid2D.none` where there is no model.
    public let heights: Grid2D
    /// Distance (mm) from each cell to the model silhouette (0 inside).
    public let silhouetteDistance: Grid2D
    public let flatLevels: [Double]

    private var fieldCache: [String: Grid2D] = [:]
    private let lock = NSLock()

    public var stockTop: Double { placed.stockTop }
    public var safeZ: Double { placed.stockTop + job.safeHeight }
    public var res: Double { heights.res }

    public init(raw: Mesh, job: Job) {
        self.job = job
        placed = PlacedModel(raw: raw, orientation: job.orientation, stock: job.stock)
        let s = placed.stockSize
        let res = max(0.05, min(0.5, max(s.x, s.y) / job.quality.divisions))
        let maxTool = job.operations.map { $0.tool.radius + max(0, $0.boundaryMargin) + $0.stockToLeaveXY }.max() ?? 5
        let margin = max(8, maxTool + 4) + 2 * res
        let template = Grid2D(covering: V2(-margin, -margin), V2(s.x + margin, s.y + margin), res: res, fill: Grid2D.none)
        heights = Heightmap.rasterizeTop(placed.mesh, into: template)
        let h = heights
        let d = DistanceTransform.distance(width: h.width, height: h.height, res: res) { h.data[$0] > Grid2D.none / 2 }
        silhouetteDistance = Grid2D(like: h, data: d)
        flatLevels = placed.mesh.flatUpwardFaceHeights()
    }

    // MARK: Regions

    func regions(for op: Operation) -> [Region] {
        job.regions.filter { r in r.enabled && (op.regionIDs == nil || op.regionIDs!.contains(r.id)) }
    }

    func isForbiddenXY(_ p: V2, z: Double, op: Operation, inflate: Double) -> Bool {
        let rs = regions(for: op)
        for r in rs where r.kind == .keepOut && r.contains(p, inflate: inflate) {
            if let pz = r.protectBelowZ { if z < pz - 1e-6 { return true } } else { return true }
        }
        let only = rs.filter { $0.kind == .machineOnly }
        if !only.isEmpty && !only.contains(where: { $0.contains(p) }) { return true }
        return false
    }

    // MARK: Fields

    public func floorZ(_ op: Operation) -> Double {
        if let f = op.floorZ { return f }
        let mb = placed.modelBounds.min.z
        if op.kind == .pocket { return max(0, mb) }
        return mb <= 0.01 ? min(op.bottomSkin, stockTop) : mb
    }

    /// Effective obstacle heights for an operation (model + floor + boundary + regions + stock-to-leave).
    func obstacleHeights(_ op: Operation) -> Grid2D {
        let floor = Float(floorZ(op))
        let leaveZ = Float(op.stockToLeaveZ)
        let R = op.tool.radius + op.stockToLeaveXY
        let s = placed.stockSize
        var g = heights
        let sil = silhouetteDistance
        let rs = regions(for: op)
        let onlyRegions = rs.filter { $0.kind == .machineOnly }
        let keepOuts = rs.filter { $0.kind == .keepOut }
        let margin = Float(op.boundaryMargin + R)
        let res = g.res
        for y in 0..<g.height {
            for x in 0..<g.width {
                let i = y * g.width + x
                let p = g.world(x, y)
                var v = max(g.data[i], floor) + leaveZ
                // Outside the stock (expanded by the cutter radius) there is nothing to reach.
                let outsideStock = p.x < -R - res || p.y < -R - res || p.x > s.x + R + res || p.y > s.y + R + res
                switch op.boundary {
                case .stock:
                    if outsideStock { v = Grid2D.forbid }
                case .silhouette:
                    if outsideStock || sil.data[i] > margin { v = Grid2D.forbid }
                case .insideSilhouette:
                    if sil.data[i] > 0 { v = Grid2D.forbid }
                }
                if !onlyRegions.isEmpty && !onlyRegions.contains(where: { $0.contains(p, inflate: R) }) { v = Grid2D.forbid }
                for r in keepOuts where r.contains(p, inflate: res) {
                    v = max(v, r.protectBelowZ.map { Float($0) } ?? Grid2D.forbid)
                }
                g.data[i] = v
            }
        }
        // 3D strategies: make the field conservative (half-cell max) so contact points that fall
        // between grid nodes on steep slopes can never cause a gouge.
        if op.kind == .roughing || op.kind == .parallelFinish || op.kind == .waterlineFinish {
            let src = g.data
            let W = g.width, H = g.height
            g.data.withUnsafeMutableBufferPointer { dst in
                let d = dst.baseAddress!
                src.withUnsafeBufferPointer { sb in
                    let s = sb.baseAddress!
                    Parallel.forEach(H) { rows in
                        for y in rows {
                            for x in 0..<W {
                                let c = s[y * W + x]
                                if c >= Grid2D.forbidThreshold { continue }
                                var m = c
                                for yy in max(0, y - 1)...min(H - 1, y + 1) {
                                    for xx in max(0, x - 1)...min(W - 1, x + 1) {
                                        let v = s[yy * W + xx]
                                        if v < Grid2D.forbidThreshold { m = max(m, (v + c) * 0.5) }
                                    }
                                }
                                d[y * W + x] = m
                            }
                        }
                    }
                }
            }
        }
        return g
    }

    /// Tool-tip height field for an operation (cached).
    public func toolField(_ op: Operation) -> Grid2D {
        let key = "\(op.tool.kind)|\(op.tool.diameter)|\(op.tool.cornerRadius)|\(op.tool.vAngle)|\(op.stockToLeaveXY)|\(op.stockToLeaveZ)|\(op.boundary)|\(op.boundaryMargin)|\(floorZ(op))|\(regions(for: op).map { "\($0.min)\($0.max)\($0.kind)\(String(describing: $0.protectBelowZ))" })"
        lock.lock()
        if let f = fieldCache[key] { lock.unlock(); return f }
        lock.unlock()
        let h = obstacleHeights(op)
        let t = ToolDilation.dilate(h, tool: op.tool, extraRadius: op.stockToLeaveXY)
        lock.lock(); fieldCache[key] = t; lock.unlock()
        return t
    }

    // MARK: Generation

    public func generate(_ op: Operation, progress: ProgressHandler? = nil) throws -> Toolpath {
        let start = V3(0, 0, safeZ)
        var tp: Toolpath
        switch op.kind {
        case .facing: tp = try facing(op, progress: progress)
        case .roughing, .pocket: tp = try clearing(op, progress: progress)
        case .parallelFinish: tp = try parallel(op, progress: progress)
        case .waterlineFinish: tp = try waterline(op, progress: progress)
        case .cutout: tp = try cutout(op, progress: progress)
        }
        tp.start = start
        if tp.moves.isEmpty { tp.warnings.append("Operation produced no toolpath.") }
        let advice = FeedsAndSpeeds.check(tool: op.tool, data: op.cutting, material: .named(job.stock.materialID))
        tp.warnings.append(contentsOf: advice.warnings)
        let deepest = tp.moves.map(\.to.z).min() ?? stockTop
        if stockTop - deepest > op.tool.fluteLength + 0.01 {
            tp.warnings.append(String(format: "Cut depth %.1f mm exceeds the tool's flute length (%.1f mm).", stockTop - deepest, op.tool.fluteLength))
        }
        progress?(1)
        return tp
    }

    func makeToolpath(_ op: Operation, _ b: PathBuilder) -> Toolpath {
        Toolpath(id: op.id, name: op.name, kind: op.kind, tool: op.tool, rpm: op.cutting.rpm,
                 start: V3(0, 0, safeZ), moves: b.moves)
    }

    func builder(_ op: Operation) -> PathBuilder {
        PathBuilder(start: V3(0, 0, safeZ), safeZ: safeZ, feed: op.cutting.feed, plunge: op.cutting.plunge)
    }
}
