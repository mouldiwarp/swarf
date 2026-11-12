import Foundation
import simd

/// Arc-length parameterised closed polygon.
struct ClosedPath {
    let pts: [V2]
    let cum: [Double]
    var perimeter: Double { cum.last! }

    init(_ loop: Loop) {
        pts = loop.points
        var c = [0.0]
        for i in 0..<pts.count { c.append(c[i] + pts[i].dist(pts[(i + 1) % pts.count])) }
        cum = c
    }

    func point(at s: Double) -> V2 {
        let P = perimeter
        var u = s.truncatingRemainder(dividingBy: P)
        if u < 0 { u += P }
        var lo = 0, hi = pts.count
        while lo < hi - 1 {
            let m = (lo + hi) / 2
            if cum[m] <= u { lo = m } else { hi = m }
        }
        let seg = cum[lo + 1] - cum[lo]
        let t = seg > 1e-12 ? (u - cum[lo]) / seg : 0
        return pts[lo] + (pts[(lo + 1) % pts.count] - pts[lo]) * t
    }

    /// Nearest arc-length parameter to point p.
    func param(nearest p: V2) -> Double {
        var best = Double.infinity, bs = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            let ab = b - a
            let l2 = simd_length_squared(ab)
            let t = l2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
            let d = simd_distance_squared(a + ab * t, p)
            if d < best { best = d; bs = cum[i] + t * (cum[i + 1] - cum[i]) }
        }
        return bs
    }

    /// Samples (unwrapped parameter, point) from s0 to s1 including every vertex and the given break parameters.
    func samples(from s0: Double, to s1: Double, breaks: [Double] = []) -> [(Double, V2)] {
        guard s1 > s0 else { return [(s0, point(at: s0))] }
        let P = perimeter
        var params: [Double] = [s0, s1]
        let k0 = Int(floor(s0 / P)), k1 = Int(floor(s1 / P))
        for k in k0...k1 {
            let base = Double(k) * P
            for c in cum.dropLast() where base + c > s0 && base + c < s1 { params.append(base + c) }
            for b in breaks where base + b > s0 && base + b < s1 { params.append(base + b) }
        }
        params.sort()
        var out: [(Double, V2)] = []
        for s in params where out.last.map({ s - $0.0 > 1e-7 }) ?? true { out.append((s, point(at: s))) }
        return out
    }

    /// Turning (curvature proxy) in a window around s.
    func turning(at s: Double, window: Double) -> Double {
        let a = point(at: s - window), b = point(at: s), c = point(at: s + window)
        let u = b - a, v = c - b
        let lu = simd_length(u), lv = simd_length(v)
        if lu < 1e-9 || lv < 1e-9 { return 0 }
        return 1 - simd_dot(u, v) / (lu * lv)
    }
}

extension CAMContext {
    // MARK: Facing

    func facing(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        var b = builder(op)
        let s = placed.stockSize
        let R = op.tool.radius
        let so = op.stepover
        let depth = min(op.facingDepth, depthFloor(op).map { stockTop - $0 } ?? .infinity)
        let target = stockTop - depth
        let passes = max(1, Int(ceil(depth / max(0.05, op.cutting.stepdown))))
        var ys: [Double] = []
        var y = 0.0
        while y < s.y { ys.append(y); y += so }
        ys.append(s.y)
        let xa = -R - 2, xb = s.x + R + 2
        for p in 1...passes {
            try Task.checkCancellation()
            let z = stockTop - Double(p) * (stockTop - target) / Double(passes)
            var first = true
            for (i, yy) in ys.enumerated() {
                let forward = !op.zigzag || i % 2 == 0
                let from = V3(forward ? xa : xb, yy, z), to = V3(forward ? xb : xa, yy, z)
                let pieces = avoidRegions([from, to], op: op, step: 1)
                for (j, piece) in pieces.enumerated() {
                    guard let f = piece.first else { continue }
                    if first || j > 0 || !op.zigzag || simd_distance(b.pos, f) > so * 1.5 + 1e-6 {
                        b.travel(to: f, approachZ: z + 1)
                    } else {
                        b.cut(f)
                    }
                    b.polyline(Array(piece.dropFirst()))
                    first = false
                }
            }
            progress?(Double(p) / Double(passes))
        }
        b.retract()
        return makeToolpath(op, b)
    }

    /// Split a polyline where it enters keep-out regions (inflated by the tool radius).
    func avoidRegions(_ pts: [V3], op: Operation, step: Double) -> [[V3]] {
        let rs = regions(for: op)
        if rs.isEmpty { return [pts] }
        var out: [[V3]] = [], cur: [V3] = []
        let R = op.tool.radius
        func ok(_ p: V3) -> Bool { !isForbiddenXY(p.xy, z: p.z, op: op, inflate: R) }
        for i in 0..<pts.count {
            if i == 0 {
                if ok(pts[0]) { cur.append(pts[0]) }
                continue
            }
            let a = pts[i - 1], c = pts[i]
            let n = max(1, Int(ceil(simd_distance(a, c) / step)))
            for k in 1...n {
                let p = a + (c - a) * (Double(k) / Double(n))
                if ok(p) {
                    if k == n || cur.isEmpty { cur.append(p) }
                } else if !cur.isEmpty {
                    // close the run at the last good sample
                    let back = a + (c - a) * (Double(k - 1) / Double(n))
                    if simd_distance(back, cur.last!) > 1e-6 { cur.append(back) }
                    out.append(cur); cur = []
                }
            }
        }
        if cur.count > 1 { out.append(cur) }
        return out.filter { $0.count > 1 }
    }

    // MARK: Area clearing (3D roughing & 2.5D pockets)

    func clearing(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        let T = toolField(op)
        var b = builder(op)
        let floor = floorZ(op) + op.stockToLeaveZ
        let sd = max(0.05, op.cutting.stepdown)
        // Pockets with a flat end mill put the wall pass on the exact model wall (see below). That pass can sit up to
        // two cells further out than the grid says, so keep the next pass close enough to leave no ridge.
        let exactWalls = op.kind == .pocket && op.tool.kind == .flat
        let so = min(op.stepover, op.tool.diameter * 0.95 - (exactWalls ? 2 * T.res : 0))
        let wallOffset = op.tool.radius + op.stockToLeaveXY
        var footprints: [Double: Footprint] = [:]
        func wallAllowed(_ p: V2, _ z: Double) -> Bool {
            if isForbiddenXY(p, z: z, op: op, inflate: op.tool.radius) { return false }
            let s = placed.stockSize, R = op.tool.radius
            switch op.boundary {
            case .stock: return p.x >= -R && p.y >= -R && p.x <= s.x + R && p.y <= s.y + R
            case .silhouette: return Double(silhouetteDistance.sample(p)) <= op.boundaryMargin + wallOffset
            case .insideSilhouette: return silhouetteDistance.sample(p) <= 0
            }
        }
        var levels: [Double] = []
        var z = stockTop - sd
        while z > floor + 1e-6 { levels.append(z); z -= sd }
        levels.append(floor)
        for f in flatLevels {
            let fz = f + op.stockToLeaveZ
            if fz > floor + 1e-3 && fz < stockTop - 1e-3 { levels.append(fz) }
        }
        levels.sort(by: >)
        levels = levels.reduce(into: [Double]()) { acc, v in if acc.last.map({ $0 - v > 0.02 }) ?? true { acc.append(v) } }

        let W = T.width, H = T.height
        let ramp = max(0.5, op.cutting.rampAngle) * .pi / 180
        var prevZ = stockTop
        let simplifyTol = min(0.01, T.res * 0.1)
        let negT = T.map { -$0 }

        for (li, z) in levels.enumerated() {
            try Task.checkCancellation()
            let zf = Float(z) + 1e-4
            var anyAllowed = false
            for v in T.data where v <= zf { anyAllowed = true; break }
            if !anyAllowed { break }
            let dist = DistanceTransform.distance(width: W, height: H, res: T.res) { T.data[$0] > zf }
            let D = Grid2D(like: T, data: dist)
            let maxD = Double(dist.lazy.filter { $0 < 1e19 }.max() ?? 0)
            // Component labels (4-connected) of the allowed region.
            var label = [Int32](repeating: -1, count: W * H)
            var nextLabel: Int32 = 0
            var stack: [Int] = []
            for i in 0..<(W * H) where label[i] < 0 && T.data[i] <= zf {
                label[i] = nextLabel; stack.append(i)
                while let c = stack.popLast() {
                    let x = c % W, y = c / W
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < W && ny < H {
                        let n = ny * W + nx
                        if label[n] < 0 && T.data[n] <= zf { label[n] = nextLabel; stack.append(n) }
                    }
                }
                nextLabel += 1
            }
            // Offsets: k=0 from the exact tool field, k>=1 from the distance field.
            var loopsByK: [(Int, Loop)] = []
            // The grid puts the wall pass up to a cell or so short of the wall, and by an amount that changes with depth
            // (the contour is interpolated across the wall's full height). For a flat end mill the exact limit is
            // simple: stay `wallOffset` from all material that stands above this level.
            let fp: Footprint? = exactWalls ? {
                if let f = footprints[z] { return f }
                let f = Footprint(mesh: placed.mesh, minZ: z + 0.01)
                footprints[z] = f
                return f
            }() : nil
            for l in Contours.isolines(negT, levels: [-zf])[0] {
                let wall = fp?.refine(l, level: wallOffset, maxShift: 2 * T.res) { wallAllowed($0, z) } ?? l
                loopsByK.append((0, wall))
            }
            var offs: [Float] = []
            var k = 1
            while Double(k) * so < maxD { offs.append(Float(Double(k) * so)); k += 1 }
            if !offs.isEmpty {
                for (ki, ls) in Contours.isolines(D, levels: offs).enumerated() {
                    for l in ls { loopsByK.append((ki + 1, l)) }
                }
            }
            var comps: [Int32: [(Int, Loop)]] = [:]
            for (k, l0) in loopsByK {
                guard abs(l0.signedArea) > T.res * T.res * 2, l0.perimeter > T.res * 4 else { continue }
                let l = Polyline.simplify(loop: l0, tolerance: simplifyTol)
                guard l.points.count >= 3 else { continue }
                var lab: Int32 = -1
                for i in stride(from: 0, to: l.points.count, by: max(1, l.points.count / 8)) {
                    let p = l.points[i], q = l.points[(i + 1) % l.points.count]
                    let dir = q - p
                    let len = simd_length(dir)
                    if len < 1e-9 { continue }
                    let inward = dir.perp / len  // left side
                    let c = T.cellCoord(p + inward * T.res * 0.75)
                    let x = Int(c.x.rounded()), y = Int(c.y.rounded())
                    if x >= 0, y >= 0, x < W, y < H, label[y * W + x] >= 0 { lab = label[y * W + x]; break }
                }
                comps[lab, default: []].append((k, l))
            }
            var remaining = comps
            while !remaining.isEmpty {
                // nearest component
                let pos = b.pos.xy
                let key = remaining.keys.min { a, c in
                    let da = remaining[a]!.map { simd_distance_squared($0.1.points[0], pos) }.min()!
                    let dc = remaining[c]!.map { simd_distance_squared($0.1.points[0], pos) }.min()!
                    return da < dc
                }!
                var loops = remaining.removeValue(forKey: key)!
                loops.sort { $0.0 > $1.0 }
                var firstInComp = true
                while !loops.isEmpty {
                    let topK = loops[0].0
                    let candidates = loops.indices.filter { loops[$0].0 == topK }
                    let here = b.pos.xy
                    let pick = candidates.min { i, j in
                        let li = loops[i].1, lj = loops[j].1
                        let di = li.points.map { simd_distance_squared($0, here) }.min()!
                        let dj = lj.points.map { simd_distance_squared($0, here) }.min()!
                        return di < dj
                    }!
                    var loop = loops.remove(at: pick).1
                    if op.direction == .conventional { loop = loop.reversed() }
                    loop = loop.starting(near: here)
                    let start = V3(loop.points[0], z)
                    let linkLen = simd_distance(here, loop.points[0])
                    var linked = false
                    if !firstInComp && abs(b.pos.z - z) < 1e-6 && linkLen < max(so * 2.5, op.tool.diameter) {
                        // Stay down if the straight link stays inside the allowed region.
                        let n = max(2, Int(ceil(linkLen / T.res)))
                        let end = loop.points[0]
                        linked = (0...n).allSatisfy { i in
                            let p = here + (end - here) * (Double(i) / Double(n))
                            if D.nearest(p) > 0 && T.sample(p) <= zf { return true }
                            // Near an exact wall pass the grid is too cautious; ask the model itself.
                            guard let fp else { return false }
                            let clear = (fp.nearest(p, within: wallOffset)?.dist ?? .infinity) >= wallOffset - 1e-6
                            return clear && wallAllowed(p, z)
                        }
                    }
                    let path = ClosedPath(loop)
                    if linked {
                        b.cut(start)
                        for (_, p) in path.samples(from: 0, to: path.perimeter).dropFirst() { b.cut(V3(p, z)) }
                    } else {
                        let topZ = min(prevZ, stockTop)
                        b.travel(to: V3(loop.points[0], topZ), approachZ: topZ + 1)
                        let dz = topZ - z
                        let rampLen = dz / tan(ramp)
                        if path.perimeter < op.tool.diameter * 0.5 || dz < 1e-6 {
                            b.cut(start)
                            for (_, p) in path.samples(from: 0, to: path.perimeter).dropFirst() { b.cut(V3(p, z)) }
                        } else {
                            for (s, p) in path.samples(from: 0, to: rampLen).dropFirst() {
                                b.cut(V3(p, topZ - dz * min(1, s / rampLen)))
                            }
                            for (_, p) in path.samples(from: rampLen, to: rampLen + path.perimeter).dropFirst() { b.cut(V3(p, z)) }
                            // finish back at the loop start so the next link starts cleanly
                            let rest = rampLen.truncatingRemainder(dividingBy: path.perimeter)
                            if rest > 1e-6 {
                                // already at start+rampLen; nothing else needed
                            }
                        }
                    }
                    firstInComp = false
                }
            }
            prevZ = z
            progress?(Double(li + 1) / Double(levels.count))
        }
        b.retract()
        var tp = makeToolpath(op, b)
        if tp.moves.count < 3 { tp.warnings.append("Nothing to clear with this tool and boundary.") }
        return tp
    }

    // MARK: Parallel (raster) finishing

    func slopeAngle(_ T: Grid2D, _ p: V2) -> Double {
        let h = T.res
        let gx = Double(T.sample(p + V2(h, 0)) - T.sample(p - V2(h, 0))) / (2 * h)
        let gy = Double(T.sample(p + V2(0, h)) - T.sample(p - V2(0, h))) / (2 * h)
        let g = (gx * gx + gy * gy).squareRoot()
        if !g.isFinite || g > 1e6 { return 90 }
        return atan(g) * 180 / .pi
    }

    func parallel(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        let T = toolField(op)
        var b = builder(op)
        let floor = floorZ(op) + op.stockToLeaveZ
        let so = op.stepover
        let th = op.rasterAngle * .pi / 180
        let u = V2(cos(th), sin(th)), v = V2(-sin(th), cos(th))
        // valid bbox
        var lo = V2(repeating: .infinity), hi = V2(repeating: -.infinity)
        for y in 0..<T.height {
            for x in 0..<T.width where T[x, y] < Grid2D.forbidThreshold {
                let p = T.world(x, y)
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        guard lo.x <= hi.x else { throw CAMError.nothingToCut("No reachable area for parallel finishing.") }
        let corners = [lo, V2(hi.x, lo.y), hi, V2(lo.x, hi.y)]
        let umin = corners.map { simd_dot($0, u) }.min()!, umax = corners.map { simd_dot($0, u) }.max()!
        let vmin = corners.map { simd_dot($0, v) }.min()!, vmax = corners.map { simd_dot($0, v) }.max()!
        let step = max(0.05, T.res * 0.75)
        let nLines = Int(ceil((vmax - vmin) / so)) + 1
        let slopeLimit = op.slopeLimit
        var lines: [[[V3]]] = []
        for k in 0..<nLines {
            try Task.checkCancellation()
            let vk = vmin + Double(k) * so
            var segs: [[V3]] = [], cur: [V3] = []
            var t = umin
            while t <= umax + 1e-9 {
                let p = u * t + v * vk
                let tz = T.sampleMax(p)
                var ok = tz < Grid2D.forbidThreshold
                if ok && slopeLimit > 0 && slopeAngle(T, p) > slopeLimit + 5 { ok = false }
                if ok && !regions(for: op).isEmpty && isForbiddenXY(p, z: Double(tz), op: op, inflate: 0) { ok = false }
                if ok {
                    cur.append(V3(p, max(Double(tz), floor)))
                } else if !cur.isEmpty {
                    segs.append(cur); cur = []
                }
                t += step
            }
            if !cur.isEmpty { segs.append(cur) }
            let simplified = segs.filter { $0.count >= 2 }.map { Polyline.simplify($0, tolerance: 0.005) }
            lines.append(op.zigzag && k % 2 == 1 ? simplified.reversed().map { $0.reversed() } : simplified)
            if k % 20 == 0 { progress?(Double(k) / Double(nLines)) }
        }
        var first = true
        for segs in lines {
            for seg in segs {
                guard let s0 = seg.first else { continue }
                var linked = false
                if !first {
                    let a = b.pos, d = simd_distance(a.xy, s0.xy)
                    if d < so * 3 {
                        let n = max(2, Int(ceil(d / step)))
                        var link: [V3] = []
                        linked = true
                        for i in 1..<n {
                            let p = a.xy + (s0.xy - a.xy) * (Double(i) / Double(n))
                            let tz = T.sampleMax(p)
                            if tz >= Grid2D.forbidThreshold { linked = false; break }
                            link.append(V3(p, max(Double(tz), floor)))
                        }
                        if linked { b.polyline(link) }
                    }
                }
                if !linked { b.travel(to: s0, approachZ: s0.z + 2 + op.stockToLeaveZ) } else { b.cut(s0) }
                b.polyline(Array(seg.dropFirst()))
                first = false
            }
        }
        b.retract()
        return makeToolpath(op, b)
    }

    // MARK: Waterline finishing

    func waterline(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        let T = toolField(op)
        var b = builder(op)
        let floor = floorZ(op) + op.stockToLeaveZ
        let sd = max(0.05, op.cutting.stepdown)
        var top = floor
        for v in T.data where v < Grid2D.forbidThreshold { top = max(top, Double(v)) }
        top = min(top, stockTop)
        var levels: [Double] = []
        var z = top - sd
        while z > floor + 1e-6 { levels.append(z); z -= sd }
        levels.append(floor + 0.001)
        let negT = T.map { -$0 }
        let all = Contours.isolines(negT, levels: levels.map { -Float($0) })
        let slopeLimit = op.slopeLimit
        for (li, loops) in all.enumerated() {
            try Task.checkCancellation()
            let z = levels[li]
            var runs: [[V3]] = []
            for l0 in loops {
                let l = Polyline.simplify(loop: l0, tolerance: 0.005)
                var lp = l.points
                if op.direction == .conventional { lp.reverse() }
                guard lp.count >= 2 else { continue }
                let good = lp.map { p -> Bool in
                    if T.sample(p) >= Grid2D.forbidThreshold { return false }
                    if slopeLimit > 0 && slopeAngle(T, p) < slopeLimit { return false }
                    if !regions(for: op).isEmpty && isForbiddenXY(p, z: z, op: op, inflate: 0) { return false }
                    return true
                }
                if good.allSatisfy({ $0 }) {
                    runs.append((lp + [lp[0]]).map { V3($0, z) })
                    continue
                }
                guard let firstBad = good.firstIndex(of: false) else { continue }
                var cur: [V3] = []
                for j in 1...lp.count {
                    let i = (firstBad + j) % lp.count
                    if good[i] { cur.append(V3(lp[i], z)) } else if !cur.isEmpty { runs.append(cur); cur = [] }
                }
                if !cur.isEmpty { runs.append(cur) }
            }
            runs = runs.filter { Polyline.length($0) > 1 }
            while !runs.isEmpty {
                let here = b.pos
                let i = runs.indices.min { simd_distance_squared(runs[$0][0], here) < simd_distance_squared(runs[$1][0], here) }!
                let r = runs.remove(at: i)
                if simd_distance(here, r[0]) < 1e-3 { b.cut(r[0]) } else { b.travel(to: r[0], approachZ: z + 2) }
                b.polyline(Array(r.dropFirst()))
            }
            progress?(Double(li + 1) / Double(all.count))
        }
        b.retract()
        return makeToolpath(op, b)
    }

    // MARK: Cutout with tabs

    /// Cutout outlines offset by the tool radius + XY stock to leave + `extra` (roughing allowance).
    public func cutoutLoops(_ op: Operation, extra: Double = 0) -> [Loop] {
        let r = Float(op.tool.radius + op.stockToLeaveXY + extra)
        let g = silhouetteDistance
        let loops = Contours.isolines(g, levels: [r])[0]
        let fp = footprint
        let edge = g.res * 2
        let maxX = g.origin.x + Double(g.width - 1) * g.res, maxY = g.origin.y + Double(g.height - 1) * g.res
        return loops.compactMap { l -> Loop? in
            let bb = l.bounds
            if bb.min.x < g.origin.x + edge || bb.min.y < g.origin.y + edge || bb.max.x > maxX - edge || bb.max.y > maxY - edge { return nil }
            if l.perimeter < op.tool.diameter { return nil }
            let isHole = l.signedArea > 0  // free space on the left => CCW loops sit inside holes
            if isHole && !op.cutHoles { return nil }
            // The grid contour wobbles by up to half a cell; put it on the exact offset of the model outline.
            let exact = fp.refine(l, level: Double(r), maxShift: 2 * g.res)
            return Polyline.simplify(loop: exact, tolerance: 0.01)
        }
    }

    /// Tab centres (XY) on the finished outlines, so roughing and finishing loops leave the same tabs.
    func tabAnchors(_ op: Operation, finishLoops: [Loop]) -> [V2] {
        let tabs = op.tabs
        guard tabs.enabled else { return [] }
        let R = op.tool.radius
        var out: [V2] = []
        for loop in finishLoops {
            let path = ClosedPath(loop)
            let P = path.perimeter
            guard P >= tabs.minLoopLength else { continue }
            if !tabs.manualPositions.isEmpty {
                let maxDist = max(10, R * 4)
                for m in tabs.manualPositions {
                    let q = path.point(at: path.param(nearest: m))
                    if q.dist(m) < maxDist { out.append(q) }
                }
            } else {
                let count = max(1, tabs.countPerLoop)
                let spacing = P / Double(count)
                for i in 0..<count {
                    let nominal = (Double(i) + 0.5) * spacing
                    // Prefer straight stretches within ±25% of the spacing.
                    var best = nominal, bestScore = Double.infinity
                    let search = spacing * 0.25
                    var s = nominal - search
                    while s <= nominal + search {
                        let score = path.turning(at: s, window: tabs.width / 2 + R) + abs(s - nominal) / max(1, spacing) * 0.05
                        if score < bestScore { bestScore = score; best = s }
                        s += max(0.5, search / 10)
                    }
                    out.append(path.point(at: (best + P).truncatingRemainder(dividingBy: P)))
                }
            }
        }
        return out
    }

    func cutout(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        var b = builder(op)
        let holesFirst: (Loop, Loop) -> Bool = { ($0.signedArea > 0 ? 0 : 1) < ($1.signedArea > 0 ? 0 : 1) }
        let finishLoops = cutoutLoops(op).sorted(by: holesFirst)
        guard !finishLoops.isEmpty else { throw CAMError.nothingToCut("No outline found for the cutout.") }
        let fin = op.cutoutFinishSettings
        let allowance = max(0, fin.allowance)
        let finishing = fin.enabled && allowance > 1e-6
        let zTop = stockTop
        let zBot = max(-op.throughDepth, depthFloor(op) ?? -.infinity)
        let roughZ = op.tool.passLevels(top: zTop, bottom: zBot, stepdown: op.cutting.stepdown)
        let finishZ = op.tool.passLevels(top: zTop, bottom: zBot, stepdown: op.finishStepdown)
        let anchors = tabAnchors(op, finishLoops: finishLoops)

        // Holes before outer profiles (parts stay held longest); within each, roughing before finishing.
        var jobs: [(loop: Loop, levels: [Double], snap: Double)] = []
        let roughLoops = finishing ? cutoutLoops(op, extra: allowance).sorted(by: holesFirst) : finishLoops
        for hole in [true, false] {
            for l in roughLoops where (l.signedArea > 0) == hole { jobs.append((l, roughZ, finishing ? allowance + 1 : max(10, op.tool.radius * 4))) }
            if finishing {
                for l in finishLoops where (l.signedArea > 0) == hole { jobs.append((l, finishZ, 1)) }
            }
        }

        let ramp = max(0.5, op.cutting.rampAngle) * .pi / 180
        let R = op.tool.radius
        let tabs = op.tabs
        let tabTop = tabs.height
        var warned = false
        for (li, job) in jobs.enumerated() {
            try Task.checkCancellation()
            var loop = job.loop
            if op.direction == .conventional { loop = loop.reversed() }
            loop = loop.starting(near: b.pos.xy)
            let path = ClosedPath(loop)
            let P = path.perimeter
            var centres: [Double] = []
            for a in anchors {
                let s = path.param(nearest: a)
                if path.point(at: s).dist(a) < job.snap + 1e-6 { centres.append(s) }
            }
            let half = tabs.width / 2 + R
            let flank = tabs.shape == .triangular ? tabs.height : 0
            func tabZ(_ s: Double) -> Double {
                var z = -Double.infinity
                let u = s.truncatingRemainder(dividingBy: P)
                for c in centres {
                    var d = abs(u - c)
                    d = min(d, P - d)
                    if d <= half { z = max(z, tabTop) } else if d < half + flank { z = max(z, tabTop - (d - half)) }
                }
                return z
            }
            var breaks: [Double] = []
            for c in centres {
                for o in [-half - flank, -half, half, half + flank] {
                    var s = (c + o).truncatingRemainder(dividingBy: P)
                    if s < 0 { s += P }
                    breaks.append(s)
                }
            }
            if !regions(for: op).isEmpty && !warned && loop.points.contains(where: { isForbiddenXY($0, z: zBot, op: op, inflate: R) }) {
                warned = true
            }
            var cursor = 0.0
            var zPrev = zTop
            b.travel(to: V3(loop.points[0], zTop), approachZ: zTop + 1)
            for z in job.levels {
                let dz = zPrev - z
                let rampLen = min(P, dz / tan(ramp))
                for (s, p) in path.samples(from: cursor, to: cursor + rampLen, breaks: breaks).dropFirst() {
                    let zr = zPrev - dz * min(1, (s - cursor) / max(rampLen, 1e-9))
                    b.cut(V3(p, max(zr, tabZ(s))))
                }
                for (s, p) in path.samples(from: cursor + rampLen, to: cursor + rampLen + P, breaks: breaks).dropFirst() {
                    b.cut(V3(p, max(z, tabZ(s))))
                }
                cursor += rampLen + P
                zPrev = z
            }
            b.retract()
            progress?(Double(li + 1) / Double(jobs.count))
        }
        var tp = makeToolpath(op, b)
        tp.moves = simplifyLinear(tp.moves)
        if warned { tp.warnings.append("Cutout passes through a keep-out region; keep-outs are not applied to cutouts.") }
        return tp
    }

    /// Merge collinear consecutive feed moves.
    func simplifyLinear(_ moves: [Move]) -> [Move] {
        var out: [Move] = []
        var i = 0
        while i < moves.count {
            let m = moves[i]
            guard m.kind == .feed else { out.append(m); i += 1; continue }
            var run = [out.last?.to ?? m.to, m.to]
            var j = i + 1
            while j < moves.count, moves[j].kind == .feed, moves[j].feed == m.feed { run.append(moves[j].to); j += 1 }
            let s = Polyline.simplify(run, tolerance: 0.002)
            for p in s.dropFirst() { out.append(Move(.feed, p, feed: m.feed)) }
            i = j
        }
        return out
    }
}
