import Foundation
import simd

/// What a V-carve operation engraves.
public enum VCarveSource: String, Codable, Sendable, CaseIterable {
    /// Areas inside the model outline whose surface sits below the model's top face (e.g. engraved text on a plaque).
    case recesses
    /// The model's whole outline, carved into the stock top (e.g. an STL of extruded lettering or a logo).
    case silhouette

    public var displayName: String {
        switch self {
        case .recesses: return "Recesses in the top face"
        case .silhouette: return "Model outline"
        }
    }
}

public struct VCarveSettings: Codable, Sendable, Equatable, Hashable {
    public var source: VCarveSource = .recesses
    /// Flat-bottom depth limit (mm below the carve surface). 0 = unlimited (true V-carve).
    public var maxDepth = 0.0
    /// Remove skeleton spurs shorter than this many grid cells (pixel noise on the outline).
    public var pruneCells = 4
    public init() {}
}

/// V-carving: the V-bit follows the medial axis (skeleton) of the region with depth = distance-to-edge / tan(½ angle),
/// so the cone's surface edge traces the outline exactly and corners come out sharp.
extension CAMContext {
    /// Height of the surface being engraved.
    public func vcarveTopZ(_ op: Operation) -> Double {
        op.vcarveSettings.source == .silhouette ? stockTop : min(stockTop, placed.modelBounds.max.z)
    }

    /// Region to engrave on the context grid (1 = engrave, 0 = leave).
    public func vcarveMask(_ op: Operation) -> Grid2D {
        let g = heights
        let W = g.width, H = g.height
        let top = Float(vcarveTopZ(op))
        let s = placed.stockSize
        let rs = regions(for: op)
        let only = rs.filter { $0.kind == .machineOnly }
        let keepOuts = rs.filter { $0.kind == .keepOut }
        let source = op.vcarveSettings.source
        var m = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let p = g.world(x, y)
                guard p.x >= 0, p.y >= 0, p.x <= s.x, p.y <= s.y else { continue }
                let h = g.data[i]
                guard h > Grid2D.none / 2 else { continue }
                if source == .recesses && h >= top - 0.02 { continue }
                if keepOuts.contains(where: { $0.contains(p, inflate: g.res) }) { continue }
                if !only.isEmpty && !only.contains(where: { $0.contains(p) }) { continue }
                m[i] = 1
            }
        }
        return Grid2D(like: g, data: m)
    }

    func vcarve(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        guard op.tool.kind == .vBit else {
            throw CAMError.nothingToCut("V-carving needs a V-bit. Choose a V-bit tool for this operation.")
        }
        let settings = op.vcarveSettings
        let maskGrid = vcarveMask(op)
        let mask = maskGrid.data.map { $0 > 0.5 }
        guard mask.contains(true) else {
            throw CAMError.nothingToCut(settings.source == .recesses
                ? "No recesses found below the model's top face to engrave."
                : "Nothing to engrave inside the stock.")
        }
        let W = maskGrid.width, H = maskGrid.height, res = maskGrid.res
        let topZ = vcarveTopZ(op)
        let tanHalf = tan(max(1, min(178, op.tool.vAngle)) / 2 * .pi / 180)
        let tipR = op.tool.tipDiameter / 2
        let limit = settings.maxDepth > 0 ? settings.maxDepth : .infinity

        // Conservative distance to the outline. The true edge lies up to about half a cell beyond the nearest outside
        // centre; silhouette masks are also stamped conservatively (edges widened), so allow a full cell there.
        let raw = DistanceTransform.distance(width: W, height: H, res: res) { !mask[$0] }
        let shrink = Float(res * (settings.source == .silhouette ? 1.0 : 0.6))
        let dist = Grid2D(like: maskGrid, data: zip(raw, mask).map { d, inside in inside ? max(0, d - shrink) : 0 })
        func distAt(_ p: V2) -> Double {
            let v = dist.sample(p)
            return v > Grid2D.forbidThreshold || v < 0 ? 0 : Double(v)
        }
        func depth(_ d: Double) -> Double { min(limit, max(0, d - tipR) / tanHalf) }
        progress?(0.1)
        try Task.checkCancellation()

        // 1. Medial axis.
        let skel = VCarveSkeleton.thin(mask, width: W, height: H)
        try Task.checkCancellation()
        progress?(0.4)
        var chains = VCarveSkeleton.trace(skel, width: W, height: H, prune: settings.pruneCells)
        progress?(0.5)

        var raw2D: [(pts: [V2], closed: Bool)] = []
        for c in chains {
            var pts = c.cells.map { maskGrid.world($0 % W, $0 / W) }
            // A branch from a junction to a free end whose edge-distance drops almost 1:1 with its length heads
            // straight at the outline: that is a bump in a smooth edge, not a corner (corners are added below).
            if !c.closed && c.freeStart != c.freeEnd && pts.count >= 2 {
                var len = 0.0
                for k in 1..<pts.count { len += simd_distance(pts[k - 1], pts[k]) }
                let drop = abs(distAt(pts[0]) - distAt(pts[pts.count - 1]))
                if len > 0 && drop / len > 0.8 { continue }
            }
            if !c.closed && pts.count >= 2 {
                // Extend free ends toward sharp corners while the distance keeps shrinking.
                if c.freeStart { pts.reverse(); pts = extend(pts, distAt, step: res * 0.5); pts.reverse() }
                if c.freeEnd { pts = extend(pts, distAt, step: res * 0.5) }
            }
            raw2D.append((smooth(pts, closed: c.closed, passes: 2), c.closed))
        }
        chains.removeAll()
        // Thinning rounds off convex corners, so add explicit branches from every sharp corner
        // along its bisector until they meet the skeleton.
        func nearSkeleton(_ p: V2) -> Bool {
            let c = maskGrid.cellCoord(p)
            let cx = Int(c.x.rounded()), cy = Int(c.y.rounded())
            for y in (cy - 1)...(cy + 1) where y >= 0 && y < H {
                for x in (cx - 1)...(cx + 1) where x >= 0 && x < W && skel[y * W + x] { return true }
            }
            return false
        }
        let window = max(res * 4, 0.3)
        for loop in Contours.isolines(maskGrid, levels: [0.5])[0] where loop.points.count >= 4 {
            let path = ClosedPath(loop)
            guard path.perimeter > window * 3 else { continue }
            let n = loop.points.count
            // turning measured over ±window so pixel stair-steps don't register as corners
            var turn = [Double](repeating: 0, count: n)
            var dirs = [(V2, V2)](repeating: (.zero, .zero), count: n)
            for i in 0..<n {
                let sp = path.cum[i]
                let v = path.point(at: sp)
                let a = path.point(at: sp - window), c = path.point(at: sp + window)
                let lu = simd_length(v - a), lw = simd_length(c - v)
                guard lu > 1e-9, lw > 1e-9 else { continue }
                let u = (v - a) / lu, w = (c - v) / lw
                turn[i] = atan2(u.x * w.y - u.y * w.x, simd_dot(u, w))
                dirs[i] = (u, w)
            }
            let threshold = 35 * Double.pi / 180
            for i in 0..<n where turn[i] > threshold {
                // non-maximum suppression along the outline
                var isMax = true
                var k = 1
                while k < n / 2 && isMax {
                    for j in [(i + k) % n, (i - k + n) % n] {
                        let ds = abs(path.cum[j] - path.cum[i])
                        let arc = min(ds, path.perimeter - ds)
                        if arc > window { continue }
                        if turn[j] > turn[i] || (turn[j] == turn[i] && j < i) { isMax = false }
                    }
                    let ds = abs(path.cum[(i + k) % n] - path.cum[i])
                    if min(ds, path.perimeter - ds) > window { break }
                    k += 1
                }
                guard isMax else { continue }
                let v = loop.points[i]
                let (u, w) = dirs[i]
                let bis = simd_normalize(u.perp + w.perp)
                let sinHalf = max(0.05, cos(turn[i] / 2))
                let warm = res * 2 / sinHalf
                var pts = [v]
                var p = v, dPrev = distAt(v), t = 0.0
                while t < 100 {
                    let q = p + bis * res
                    t += res
                    let dq = distAt(q)
                    if t > warm && (dq <= 0 || dq - dPrev < 0.5 * res * sinHalf) { break }
                    pts.append(q); p = q; dPrev = dq
                    if t > warm && nearSkeleton(q) { break }
                }
                if pts.count >= 3 { raw2D.append((pts, false)) }
            }
        }

        var paths: [VPath] = []
        for (pts, closed) in raw2D {
            var p3 = pts.map { V3($0, topZ - depth(distAt($0))) }
            if closed, let f = p3.first { p3.append(f) }
            p3 = Polyline.simplify(p3, tolerance: 0.01)
            if p3.count == 1 || (p3.count == 2 && simd_distance(p3[0], p3[1]) < 1e-6) {
                paths.append(VPath(points: [p3[0]], closed: false))
            } else if p3.count >= 2 {
                paths.append(VPath(points: p3, closed: closed))
            }
        }

        // 2. Flat-bottom clearing where the region is wider than the depth limit allows.
        var flatLoops: [Loop] = []
        let maxD = Double(dist.data.max() ?? 0)
        if limit.isFinite {
            let rLim = tipR + limit * tanHalf
            if maxD > rLim + res * 0.25 {
                let effWidth = max(op.tool.tipDiameter, res * 2)
                let so = max(res * 1.5, min(op.stepover, max(effWidth, rLim)))
                var levels: [Float] = []
                var r = rLim
                while r < maxD { levels.append(Float(r)); r += so }
                for ls in Contours.isolines(dist, levels: levels) {
                    for l in ls where l.perimeter > res * 3 {
                        flatLoops.append(Polyline.simplify(loop: l, tolerance: min(0.01, res * 0.1)))
                    }
                }
            }
        }
        progress?(0.6)

        // 3. Depth passes.
        let deepest = max(paths.flatMap { $0.points.map { topZ - $0.z } }.max() ?? 0, flatLoops.isEmpty ? 0 : limit)
        guard deepest > 1e-3 else { throw CAMError.nothingToCut("The engraving region is narrower than the V-bit tip.") }
        let sd = max(0.05, op.cutting.stepdown)
        let nPasses = max(1, Int(ceil(deepest / sd - 1e-6)))
        var b = builder(op)
        let hopZ = min(safeZ, stockTop + 2)
        let approach = stockTop + 0.5
        for k in 1...nPasses {
            try Task.checkCancellation()
            let dk = k == nPasses ? deepest : Double(k) * sd
            let dPrev = Double(k - 1) * sd
            var runs: [VPath] = []
            for p in paths {
                // keep only stretches not already finished by the previous pass (plus one neighbour either side)
                let need = p.points.map { topZ - $0.z > dPrev + 0.005 }
                if !need.contains(true) { continue }
                let clamped = p.points.map { V3($0.x, $0.y, max($0.z, topZ - dk)) }
                if p.points.count == 1 || (p.closed && need.allSatisfy { $0 }) {
                    runs.append(VPath(points: clamped, closed: p.closed)); continue
                }
                var i = 0
                while i < clamped.count {
                    guard need[i] else { i += 1; continue }
                    var j = i
                    while j + 1 < clamped.count && need[j + 1] { j += 1 }
                    let a = max(0, i - 1), e = min(clamped.count - 1, j + 1)
                    runs.append(VPath(points: Array(clamped[a...e]), closed: false))
                    i = j + 1
                }
            }
            if limit > dPrev + 0.005 {
                let z = topZ - min(limit, dk)
                for l in flatLoops {
                    var pts = l.points.map { V3($0, z) }
                    pts.append(pts[0])
                    runs.append(VPath(points: pts, closed: true))
                }
            }
            // nearest-neighbour ordering, reversing open runs when that is shorter
            while !runs.isEmpty {
                let here = b.pos.xy
                var best = 0, bestD = Double.infinity, bestRev = false, bestRot = 0
                for (ri, r) in runs.enumerated() {
                    if r.closed {
                        for (pi, p) in r.points.enumerated() {
                            let d = simd_distance_squared(p.xy, here)
                            if d < bestD { bestD = d; best = ri; bestRev = false; bestRot = pi }
                        }
                    } else {
                        let d0 = simd_distance_squared(r.points[0].xy, here)
                        let d1 = simd_distance_squared(r.points[r.points.count - 1].xy, here)
                        if d0 < bestD { bestD = d0; best = ri; bestRev = false; bestRot = 0 }
                        if d1 < bestD { bestD = d1; best = ri; bestRev = true; bestRot = 0 }
                    }
                }
                var r = runs.remove(at: best)
                if bestRev { r.points.reverse() }
                if r.closed && bestRot > 0 {
                    let body = Array(r.points.dropLast())
                    let rot = Array(body[bestRot...] + body[..<bestRot])
                    r.points = rot + [rot[0]]
                }
                let start = r.points[0]
                let gap = bestD.squareRoot()
                if gap < 1e-6 && abs(b.pos.z - start.z) < 1e-6 {
                    // continuous
                } else if gap < res * 1.5 && b.pos.z <= stockTop {
                    // adjacent: go up to the shallower of the two depths, across, then down
                    let upZ = max(b.pos.z, start.z)
                    b.cut(V3(b.pos.x, b.pos.y, upZ))
                    b.cut(V3(start.x, start.y, upZ))
                    b.cut(start)
                } else if gap < 25 {
                    if b.pos.z < hopZ { b.rapid(V3(b.pos.x, b.pos.y, hopZ)) }
                    b.rapid(V3(start.x, start.y, hopZ))
                    b.rapid(V3(start.x, start.y, approach))
                    b.cut(start)
                } else {
                    b.travel(to: start, approachZ: approach)
                }
                b.polyline(Array(r.points.dropFirst()))
            }
            progress?(0.6 + 0.4 * Double(k) / Double(nPasses))
        }
        b.retract()
        var tp = makeToolpath(op, b)
        tp.engraveMask = maskGrid
        if limit.isFinite && !flatLoops.isEmpty {
            tp.warnings.append("Flat areas wider than the depth limit are cleared with the V-bit; for large flat areas a Pocket with an end mill is faster.")
        }
        return tp
    }

    private func extend(_ pts: [V2], _ distAt: (V2) -> Double, step: Double) -> [V2] {
        guard pts.count >= 2 else { return pts }
        let back = pts[max(0, pts.count - 4)]
        var dir = pts[pts.count - 1] - back
        let len = simd_length(dir)
        guard len > 1e-9 else { return pts }
        dir /= len
        var out = pts
        var last = pts[pts.count - 1]
        var dLast = distAt(last)
        for _ in 0..<200 {
            let q = last + dir * step
            let dq = distAt(q)
            if dq <= 1e-4 || dq >= dLast - step * 0.1 { break }
            out.append(q); last = q; dLast = dq
        }
        return out
    }

    private func smooth(_ pts: [V2], closed: Bool, passes: Int) -> [V2] {
        guard pts.count >= 3 else { return pts }
        var p = pts
        let n = p.count
        for _ in 0..<passes {
            var q = p
            for i in 0..<n {
                if !closed && (i == 0 || i == n - 1) { continue }
                let a = p[(i - 1 + n) % n], c = p[(i + 1) % n]
                q[i] = a * 0.25 + p[i] * 0.5 + c * 0.25
            }
            p = q
        }
        return p
    }
}

struct VPath {
    var points: [V3]
    var closed: Bool
}

/// Binary skeletonisation (Zhang–Suen thinning) and tracing into polylines.
enum VCarveSkeleton {
    static func thin(_ mask: [Bool], width W: Int, height H: Int) -> [Bool] {
        var img = [UInt8](repeating: 0, count: W * H)
        var fg: [Int] = []
        for i in 0..<(W * H) where mask[i] {
            let x = i % W, y = i / W
            // keep a one-cell empty border so neighbour lookups never leave the grid
            if x == 0 || y == 0 || x == W - 1 || y == H - 1 { continue }
            img[i] = 1; fg.append(i)
        }
        var changed = true
        var remove: [Int] = []
        while changed {
            changed = false
            for step in 0..<2 {
                remove.removeAll(keepingCapacity: true)
                for i in fg where img[i] == 1 {
                    // P2..P9 clockwise starting north (+y)
                    let p2 = img[i + W], p3 = img[i + W + 1], p4 = img[i + 1], p5 = img[i - W + 1]
                    let p6 = img[i - W], p7 = img[i - W - 1], p8 = img[i - 1], p9 = img[i + W - 1]
                    let bcount = Int(p2) + Int(p3) + Int(p4) + Int(p5) + Int(p6) + Int(p7) + Int(p8) + Int(p9)
                    if bcount < 2 || bcount > 6 { continue }
                    var a = 0
                    if p2 == 0 && p3 == 1 { a += 1 }; if p3 == 0 && p4 == 1 { a += 1 }
                    if p4 == 0 && p5 == 1 { a += 1 }; if p5 == 0 && p6 == 1 { a += 1 }
                    if p6 == 0 && p7 == 1 { a += 1 }; if p7 == 0 && p8 == 1 { a += 1 }
                    if p8 == 0 && p9 == 1 { a += 1 }; if p9 == 0 && p2 == 1 { a += 1 }
                    if a != 1 { continue }
                    if step == 0 {
                        if p2 * p4 * p6 != 0 || p4 * p6 * p8 != 0 { continue }
                    } else {
                        if p2 * p4 * p8 != 0 || p2 * p6 * p8 != 0 { continue }
                    }
                    remove.append(i)
                }
                if !remove.isEmpty {
                    changed = true
                    for i in remove { img[i] = 0 }
                }
            }
            fg.removeAll { img[$0] == 0 }
        }
        return img.map { $0 != 0 }
    }

    struct Chain {
        var cells: [Int]
        var closed: Bool
        var freeStart: Bool  // starts at an endpoint (degree 1)
        var freeEnd: Bool
    }

    /// Trace skeleton pixels into chains between junctions/endpoints, plus closed cycles.
    static func trace(_ sk: [Bool], width W: Int, height H: Int, prune: Int) -> [Chain] {
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < W && y < H && sk[y * W + x] }
        func neighbours(_ i: Int) -> [Int] {
            let x = i % W, y = i / W
            var out: [Int] = []
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where on(x + dx, y + dy) { out.append((y + dy) * W + x + dx) }
            for (dx, dy) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] where on(x + dx, y + dy) {
                // a diagonal step is redundant when an orthogonal path through a shared neighbour exists
                if on(x + dx, y) || on(x, y + dy) { continue }
                out.append((y + dy) * W + x + dx)
            }
            return out
        }
        var pixels: [Int] = []
        for i in 0..<(W * H) where sk[i] { pixels.append(i) }
        var adj: [Int: [Int]] = [:]
        adj.reserveCapacity(pixels.count)
        for i in pixels { adj[i] = neighbours(i) }
        var visited = Set<Int64>()
        func key(_ a: Int, _ b: Int) -> Int64 { Int64(min(a, b)) << 32 | Int64(max(a, b)) }
        var chains: [Chain] = []
        func walk(from a: Int, via n: Int) -> Chain {
            var cells = [a, n]
            visited.insert(key(a, n))
            var prev = a, cur = n
            while adj[cur]!.count == 2 {
                guard let next = adj[cur]!.first(where: { $0 != prev && !visited.contains(key(cur, $0)) }) else { break }
                visited.insert(key(cur, next))
                cells.append(next)
                prev = cur; cur = next
                if cur == a { break }
            }
            return Chain(cells: cells, closed: cells.first == cells.last, freeStart: adj[a]!.count == 1, freeEnd: adj[cur]!.count == 1)
        }
        for i in pixels {
            let nb = adj[i]!
            if nb.isEmpty { chains.append(Chain(cells: [i], closed: false, freeStart: false, freeEnd: false)); continue }
            if nb.count == 2 { continue }
            for n in nb where !visited.contains(key(i, n)) { chains.append(walk(from: i, via: n)) }
        }
        // pure cycles (every pixel degree 2)
        for i in pixels where adj[i]!.count == 2 {
            for n in adj[i]! where !visited.contains(key(i, n)) {
                var c = walk(from: i, via: n)
                if c.closed { c.cells.removeLast() }
                chains.append(c)
            }
        }
        // prune short spurs: an endpoint chain hanging off a junction
        if prune > 0 {
            chains.removeAll { c in
                guard !c.closed, c.cells.count < prune else { return false }
                let deg0 = adj[c.cells.first!]!.count, deg1 = adj[c.cells.last!]!.count
                return (deg0 == 1 && deg1 >= 3) || (deg1 == 1 && deg0 >= 3)
            }
        }
        return chains.map { c in
            var c = c
            if c.closed, c.cells.first == c.cells.last { c.cells.removeLast() }
            return c
        }
    }
}
