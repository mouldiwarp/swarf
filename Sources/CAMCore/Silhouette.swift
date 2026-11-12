import Foundation
import simd

/// Exact XY distance from a point to the model's footprint: the union of every triangle projected onto the XY plane.
///
/// Contours traced from the height-field grid follow its cell staircase, so they wobble by up to half a cell. That
/// wobble turns smooth curves into thousands of tiny segments that change direction at random, which makes the
/// machine brake and accelerate constantly. `refine` moves contour points onto the true offset curve instead.
struct Footprint: Sendable {
    private let tris: [(V2, V2, V2)]
    private let bins: [[Int32]]
    private let origin: V2
    private let cell: Double
    private let nx: Int, ny: Int

    /// With `minZ`, only triangles reaching at least that height count: the footprint of the material at that level.
    init(mesh: Mesh, minZ: Double = -.infinity, cell: Double = 4) {
        var t: [(V2, V2, V2)] = []
        t.reserveCapacity(mesh.triangles.count)
        var lo = V2(repeating: .infinity), hi = V2(repeating: -.infinity)
        for tri in mesh.triangles {
            if minZ > -.infinity, Double(max(tri.a.z, tri.b.z, tri.c.z)) < minZ { continue }
            let a = V2(Double(tri.a.x), Double(tri.a.y)), b = V2(Double(tri.b.x), Double(tri.b.y))
            let c = V2(Double(tri.c.x), Double(tri.c.y))
            guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, c.x.isFinite, c.y.isFinite else { continue }
            t.append((a, b, c))
            lo = simd_min(lo, simd_min(a, simd_min(b, c)))
            hi = simd_max(hi, simd_max(a, simd_max(b, c)))
        }
        tris = t
        if t.isEmpty { lo = .zero; hi = .zero }
        // Keep the bin count bounded for very large stock.
        let size = hi - lo
        let c = max(cell, max(size.x, size.y) / 2000)
        self.cell = c
        origin = lo
        nx = max(1, Int(size.x / c) + 1)
        ny = max(1, Int(size.y / c) + 1)
        var b = [[Int32]](repeating: [], count: nx * ny)
        for (i, (p, q, r)) in t.enumerated() {
            let mn = simd_min(p, simd_min(q, r)), mx = simd_max(p, simd_max(q, r))
            let x0 = Int((mn.x - lo.x) / c), x1 = Int((mx.x - lo.x) / c)
            let y0 = Int((mn.y - lo.y) / c), y1 = Int((mx.y - lo.y) / c)
            for y in max(0, y0)...min(ny - 1, y1) {
                for x in max(0, x0)...min(nx - 1, x1) { b[y * nx + x].append(Int32(i)) }
            }
        }
        bins = b
    }

    /// Nearest footprint point to `p` among triangles within `radius`, or nil if none is that close.
    /// Returns distance 0 (and `p` itself) when `p` lies inside the footprint.
    func nearest(_ p: V2, within radius: Double) -> (dist: Double, point: V2)? {
        let x0 = max(0, Int((p.x - radius - origin.x) / cell)), x1 = min(nx - 1, Int((p.x + radius - origin.x) / cell))
        let y0 = max(0, Int((p.y - radius - origin.y) / cell)), y1 = min(ny - 1, Int((p.y + radius - origin.y) / cell))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var best = radius * radius
        var bestPoint: V2? = nil
        for y in y0...y1 {
            for x in x0...x1 {
                for i in bins[y * nx + x] {
                    let (a, b, c) = tris[Int(i)]
                    if Footprint.inside(p, a, b, c) { return (0, p) }
                    for (u, v) in [(a, b), (b, c), (c, a)] {
                        let q = Footprint.closest(p, u, v)
                        let d2 = simd_distance_squared(p, q)
                        if d2 < best { best = d2; bestPoint = q }
                    }
                }
            }
        }
        return bestPoint.map { (best.squareRoot(), $0) }
    }

    /// Moves each point of a contour traced at `level` mm from the footprint onto the exact offset curve.
    /// Points that would move further than `maxShift` (the grid's own error bound), or to a place `accept` rejects,
    /// are left where they are.
    func refine(_ loop: Loop, level r: Double, maxShift: Double, accept: (V2) -> Bool = { _ in true }) -> Loop {
        var out: [V2] = []
        out.reserveCapacity(loop.points.count)
        for p0 in loop.points {
            var p = p0
            var ok = false
            for _ in 0..<6 {
                guard let (d, q) = nearest(p, within: r + 2 * maxShift), d > 1e-9 else { break }
                if abs(d - r) < 1e-5 { ok = true; break }
                p = q + (p - q) * (r / d)
            }
            if !ok, let (d, _) = nearest(p, within: r + 2 * maxShift) { ok = d >= r - 1e-4 }
            if !ok || simd_distance(p, p0) > maxShift || (p != p0 && !accept(p)) { p = p0 }
            if let last = out.last, simd_distance(last, p) < 1e-4 { continue }
            out.append(p)
        }
        // Points near a sharp inside corner can land on either side of it and fold back; drop any that reverse direction.
        var changed = true
        while changed && out.count > 4 {
            changed = false
            var kept: [V2] = []
            kept.reserveCapacity(out.count)
            let n = out.count
            for i in 0..<n {
                let prev = kept.last ?? out[(i + n - 1) % n], next = out[(i + 1) % n], p = out[i]
                if simd_dot(p - prev, next - p) < 0 { changed = true; continue }
                kept.append(p)
            }
            out = kept
        }
        return out.count >= 3 ? Loop(out) : loop
    }

    static func inside(_ p: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool {
        func cross(_ u: V2, _ v: V2) -> Double { u.x * v.y - u.y * v.x }
        let area = cross(b - a, c - a)
        if abs(area) < 1e-12 { return false }  // a vertical wall projects to a line: its edges cover it
        let s = area > 0 ? 1.0 : -1.0
        return s * cross(b - a, p - a) > 0 && s * cross(c - b, p - b) > 0 && s * cross(a - c, p - c) > 0
    }

    static func closest(_ p: V2, _ a: V2, _ b: V2) -> V2 {
        let ab = b - a
        let l2 = simd_length_squared(ab)
        if l2 < 1e-18 { return a }
        return a + ab * max(0, min(1, simd_dot(p - a, ab) / l2))
    }
}
