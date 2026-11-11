import Foundation
import simd

/// A closed polygon (implicitly closed; last point != first point).
public struct Loop: Sendable {
    public var points: [V2]
    public init(_ p: [V2]) { points = p }

    public var signedArea: Double {
        var a = 0.0
        let n = points.count
        for i in 0..<n {
            let p = points[i], q = points[(i + 1) % n]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    public var perimeter: Double {
        var l = 0.0
        for i in 0..<points.count { l += points[i].dist(points[(i + 1) % points.count]) }
        return l
    }

    public var bounds: (min: V2, max: V2) {
        var lo = V2(repeating: .infinity), hi = V2(repeating: -.infinity)
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    public func reversed() -> Loop { Loop(points.reversed()) }

    /// Rotate so that the point closest to `p` comes first.
    public func starting(near p: V2) -> Loop {
        guard let i = points.indices.min(by: { simd_distance_squared(points[$0], p) < simd_distance_squared(points[$1], p) })
        else { return self }
        return Loop(Array(points[i...] + points[..<i]))
    }

    public func contains(_ p: V2) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}

public enum Contours {
    /// Marching squares iso-contours for several iso levels in a single pass.
    /// "Inside" means value > iso. Loops are oriented with the inside region on the LEFT
    /// (counter-clockwise around inside regions). Out-of-grid samples count as outside,
    /// so every contour is closed.
    public static func isolines(_ g: Grid2D, levels: [Float]) -> [[Loop]] {
        let W = g.width, H = g.height
        let sortedLevels = levels.enumerated().sorted { $0.element < $1.element }
        let lv = sortedLevels.map(\.element)
        let OUT: Float = -1e30
        let stride = W + 2
        struct Seg { var from: Int; var to: Int }
        var segsPerLevel = [[Int: Int]](repeating: [:], count: levels.count)
        var ptsPerLevel = [[Int: V2]](repeating: [:], count: levels.count)

        // Process in row bands in parallel, then merge.
        let bandCount = max(1, min(64, (H + 1) / 16))
        let rowsPer = (H + 1 + bandCount - 1) / bandCount
        var bandResults = [[(Int, Int, Int, V2, V2)]](repeating: [], count: bandCount)  // level, from, to, pf, pt
        g.data.withUnsafeBufferPointer { buf in
            let d = buf.baseAddress!
            @inline(__always) func val(_ x: Int, _ y: Int) -> Float {
                (x < 0 || y < 0 || x >= W || y >= H) ? OUT : max(-1e29, min(1e29, d[y * W + x]))
            }
            let ox = g.origin.x, oy = g.origin.y, res = g.res
            bandResults.withUnsafeMutableBufferPointer { outBuf in
                let outs = outBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: bandCount) { b in
                    var local: [(Int, Int, Int, V2, V2)] = []
                    let y0 = -1 + b * rowsPer, y1 = min(H - 1, y0 + rowsPer - 1)
                    if y0 > y1 { return }
                    for y in y0...y1 {
                        for x in -1..<W {
                            let v0 = val(x, y), v1 = val(x + 1, y), v2 = val(x + 1, y + 1), v3 = val(x, y + 1)
                            let lo = min(v0, v1, v2, v3), hi = max(v0, v1, v2, v3)
                            if lo == hi { continue }
                            // levels with lo <= iso < hi produce crossings
                            var li = lowerBound(lv, lo)
                            while li < lv.count && lv[li] < hi {
                                let iso = lv[li]
                                let ins = [v0 > iso, v1 > iso, v2 > iso, v3 > iso]
                                let vals = [v0, v1, v2, v3]
                                // edge ids (vertex coords shifted by +1)
                                let base = (y + 1) * stride + (x + 1)
                                let eid = [base * 2, (base + 1) * 2 + 1, (base + stride) * 2, base * 2 + 1]
                                let corners = [V2(Double(x), Double(y)), V2(Double(x + 1), Double(y)),
                                               V2(Double(x + 1), Double(y + 1)), V2(Double(x), Double(y + 1))]
                                var cross: [(Int, Bool)] = []  // edge index, isExit
                                for e in 0..<4 {
                                    let a = e, bb = (e + 1) % 4
                                    if ins[a] != ins[bb] { cross.append((e, ins[a])) }
                                }
                                func point(_ e: Int) -> V2 {
                                    let a = e, bb = (e + 1) % 4
                                    let t = Double((iso - vals[a]) / (vals[bb] - vals[a]))
                                    let c = corners[a] + (corners[bb] - corners[a]) * t
                                    return V2(ox + c.x * res, oy + c.y * res)
                                }
                                let level = sortedLevels[li].offset
                                if cross.count == 2 {
                                    let (ea, aExit) = cross[0], (eb, _) = cross[1]
                                    let (f, t) = aExit ? (ea, eb) : (eb, ea)
                                    local.append((level, eid[f], eid[t], point(f), point(t)))
                                } else if cross.count == 4 {
                                    let center = (v0 + v1 + v2 + v3) / 4
                                    let centerInside = center > iso
                                    // exits at index 0 and 2 in `cross` order are the ones with isExit
                                    for k in 0..<4 where cross[k].1 {
                                        let j = centerInside ? (k + 1) % 4 : (k + 3) % 4
                                        let f = cross[k].0, t = cross[j].0
                                        local.append((level, eid[f], eid[t], point(f), point(t)))
                                    }
                                }
                                li += 1
                            }
                        }
                    }
                    outs[b] = local
                }
            }
        }
        for band in bandResults {
            for (level, f, t, pf, pt) in band {
                segsPerLevel[level][f] = t
                ptsPerLevel[level][f] = pf
                ptsPerLevel[level][t] = pt
            }
        }
        var result = [[Loop]](repeating: [], count: levels.count)
        for l in 0..<levels.count {
            var next = segsPerLevel[l]
            let pts = ptsPerLevel[l]
            var loops: [Loop] = []
            while let (start, _) = next.first {
                var poly: [V2] = []
                var cur = start
                var guardCount = 0
                while let n = next.removeValue(forKey: cur) {
                    poly.append(pts[cur]!)
                    cur = n
                    guardCount += 1
                    if cur == start || guardCount > 50_000_000 { break }
                }
                if poly.count >= 3 { loops.append(Loop(poly)) }
            }
            result[l] = loops
        }
        return result
    }

    @inline(__always) static func lowerBound(_ a: [Float], _ v: Float) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let m = (lo + hi) / 2
            if a[m] < v { lo = m + 1 } else { hi = m }
        }
        return lo
    }
}

public enum Polyline {
    /// Douglas–Peucker simplification of an open 3D polyline.
    public static func simplify(_ pts: [V3], tolerance: Double) -> [V3] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        let tol2 = tolerance * tolerance
        while let (a, b) = stack.popLast() {
            if b <= a + 1 { continue }
            let pa = pts[a], pb = pts[b]
            let ab = pb - pa
            let len2 = simd_length_squared(ab)
            var best = -1.0, bi = -1
            for i in (a + 1)..<b {
                let ap = pts[i] - pa
                let d2: Double
                if len2 < 1e-18 { d2 = simd_length_squared(ap) } else {
                    let t = max(0, min(1, simd_dot(ap, ab) / len2))
                    d2 = simd_length_squared(ap - ab * t)
                }
                if d2 > best { best = d2; bi = i }
            }
            if best > tol2 {
                keep[bi] = true
                stack.append((a, bi)); stack.append((bi, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    public static func simplify(loop: Loop, tolerance: Double) -> Loop {
        guard loop.points.count > 4 else { return loop }
        // Split at the farthest point from the first so DP works on an open chain.
        let p0 = loop.points[0]
        let far = loop.points.indices.max { simd_distance_squared(loop.points[$0], p0) < simd_distance_squared(loop.points[$1], p0) }!
        let a = Array(loop.points[0...far]).map { V3($0, 0) }
        let b = (Array(loop.points[far...]) + [p0]).map { V3($0, 0) }
        let sa = simplify(a, tolerance: tolerance), sb = simplify(b, tolerance: tolerance)
        let pts = (sa + sb.dropFirst().dropLast()).map(\.xy)
        return Loop(pts)
    }

    public static func length(_ pts: [V3]) -> Double {
        var l = 0.0
        for i in 1..<max(1, pts.count) { l += simd_distance(pts[i - 1], pts[i]) }
        return l
    }
}
