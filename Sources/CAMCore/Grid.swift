import Foundation
import simd

/// Regular 2D scalar grid. Cell (i, j) centre is at `origin + (i, j) * res`.
public struct Grid2D: Sendable {
    public static let none: Float = -1e9  // no surface
    public static let forbid: Float = 1e9  // tool may never be here
    public static let forbidThreshold: Float = 1e8

    public let origin: V2
    public let res: Double
    public let width: Int
    public let height: Int
    public var data: [Float]

    public init(origin: V2, res: Double, width: Int, height: Int, fill: Float) {
        self.origin = origin; self.res = res; self.width = width; self.height = height
        data = [Float](repeating: fill, count: width * height)
    }

    public init(like g: Grid2D, data: [Float]) {
        origin = g.origin; res = g.res; width = g.width; height = g.height; self.data = data
    }

    /// Grid covering `[min, max]` with the given resolution.
    public init(covering min: V2, _ max: V2, res: Double, fill: Float) {
        let w = Int(((max.x - min.x) / res).rounded(.up)) + 1
        let h = Int(((max.y - min.y) / res).rounded(.up)) + 1
        self.init(origin: min, res: res, width: w, height: h, fill: fill)
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Float {
        get { data[y * width + x] }
        set { data[y * width + x] = newValue }
    }

    @inline(__always) public func world(_ x: Int, _ y: Int) -> V2 {
        V2(origin.x + Double(x) * res, origin.y + Double(y) * res)
    }

    @inline(__always) public func cellCoord(_ p: V2) -> V2 {
        (p - origin) / res
    }

    public func nearest(_ p: V2) -> Float {
        let c = cellCoord(p)
        let x = Int(c.x.rounded()), y = Int(c.y.rounded())
        guard x >= 0, y >= 0, x < width, y < height else { return Grid2D.forbid }
        return self[x, y]
    }

    /// Bilinear sample. Returns `forbid` if any contributing cell is forbidden or out of range.
    public func sample(_ p: V2) -> Float {
        let c = cellCoord(p)
        let fx = floor(c.x), fy = floor(c.y)
        let x0 = Int(fx), y0 = Int(fy)
        guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return nearest(p) }
        let a = self[x0, y0], b = self[x0 + 1, y0], cc = self[x0, y0 + 1], d = self[x0 + 1, y0 + 1]
        if a > Grid2D.forbidThreshold || b > Grid2D.forbidThreshold || cc > Grid2D.forbidThreshold
            || d > Grid2D.forbidThreshold { return Grid2D.forbid }
        let tx = Float(c.x - fx), ty = Float(c.y - fy)
        return (a * (1 - tx) + b * tx) * (1 - ty) + (cc * (1 - tx) + d * tx) * ty
    }

    /// Conservative sample: max of the four surrounding cells (never under-estimates a tool height).
    public func sampleMax(_ p: V2) -> Float {
        let c = cellCoord(p)
        let x0 = Int(floor(c.x)), y0 = Int(floor(c.y))
        var m: Float = -.infinity
        for dy in 0...1 {
            for dx in 0...1 {
                let x = x0 + dx, y = y0 + dy
                guard x >= 0, y >= 0, x < width, y < height else { return Grid2D.forbid }
                m = max(m, self[x, y])
            }
        }
        // Blend: bilinear when smooth, max near discontinuities.
        let bl = sample(p)
        return (m - bl) > Float(res) ? m : bl
    }

    public func map(_ f: (Float) -> Float) -> Grid2D { Grid2D(like: self, data: data.map(f)) }
}

/// Wrapper for values shared across a data-parallel loop where each worker touches a disjoint range.
struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

enum Parallel {
    /// Splits `0..<n` into contiguous ranges processed concurrently. Bodies must only write
    /// to memory owned by their own range.
    static func forEach(_ n: Int, chunk: Int = 1, _ body: (Range<Int>) -> Void) {
        guard n > 0 else { return }
        let workers = Swift.min(ProcessInfo.processInfo.activeProcessorCount * 2, Swift.max(1, n / Swift.max(1, chunk)))
        let per = (n + workers - 1) / workers
        withoutActuallyEscaping(body) { body in
            let box = UncheckedSendable(value: body)
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                let lo = w * per, hi = Swift.min(n, lo + per)
                if lo < hi { box.value(lo..<hi) }
            }
        }
    }
}

public enum Heightmap {
    /// Rasterise the top surface of a mesh (max Z per cell). Empty cells are `Grid2D.none`.
    /// Triangle edges are also stamped so thin walls and sharp ridges are never missed.
    public static func rasterizeTop(_ mesh: Mesh, into grid: Grid2D) -> Grid2D {
        var g = grid
        let W = g.width, H = g.height
        let bands = Swift.max(1, Swift.min(256, H / 8))
        let rowsPerBand = (H + bands - 1) / bands
        // Bucket triangles per band.
        var buckets = [[Int32]](repeating: [], count: bands)
        let ox = g.origin.x, oy = g.origin.y, res = g.res
        for (i, t) in mesh.triangles.enumerated() {
            let ymin = Double(Swift.min(t.a.y, t.b.y, t.c.y)), ymax = Double(Swift.max(t.a.y, t.b.y, t.c.y))
            let r0 = Swift.max(0, Int(floor((ymin - oy) / res)) - 1), r1 = Swift.min(H - 1, Int(ceil((ymax - oy) / res)) + 1)
            if r1 < 0 || r0 >= H { continue }
            for b in (r0 / rowsPerBand)...(Swift.min(bands - 1, r1 / rowsPerBand)) { buckets[b].append(Int32(i)) }
        }
        let tris = mesh.triangles
        g.data.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            Parallel.forEach(bands) { range in
                for b in range {
                    let rowLo = b * rowsPerBand, rowHi = Swift.min(H, rowLo + rowsPerBand)
                    if rowLo >= rowHi { continue }
                    @inline(__always) func stamp(_ x: Int, _ y: Int, _ z: Float) {
                        if x >= 0 && x < W && y >= rowLo && y < rowHi {
                            let k = y * W + x
                            if z > p[k] { p[k] = z }
                        }
                    }
                    for ti in buckets[b] {
                        let t = tris[Int(ti)]
                        let ax = (Double(t.a.x) - ox) / res, ay = (Double(t.a.y) - oy) / res
                        let bx = (Double(t.b.x) - ox) / res, by = (Double(t.b.y) - oy) / res
                        let cx = (Double(t.c.x) - ox) / res, cy = (Double(t.c.y) - oy) / res
                        let area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
                        if abs(area) > 1e-12 {
                            let x0 = Swift.max(0, Int(ceil(Swift.min(ax, bx, cx)))), x1 = Swift.min(W - 1, Int(floor(Swift.max(ax, bx, cx))))
                            let y0 = Swift.max(rowLo, Int(ceil(Swift.min(ay, by, cy)))), y1 = Swift.min(rowHi - 1, Int(floor(Swift.max(ay, by, cy))))
                            if x0 <= x1 && y0 <= y1 {
                                let inv = 1 / area
                                let za = Double(t.a.z), zb = Double(t.b.z), zc = Double(t.c.z)
                                for y in y0...y1 {
                                    let py = Double(y)
                                    for x in x0...x1 {
                                        let px = Double(x)
                                        let w0 = ((bx - px) * (cy - py) - (cx - px) * (by - py)) * inv
                                        let w1 = ((cx - px) * (ay - py) - (ax - px) * (cy - py)) * inv
                                        let w2 = 1 - w0 - w1
                                        if w0 >= -1e-7 && w1 >= -1e-7 && w2 >= -1e-7 {
                                            stamp(x, y, Float(w0 * za + w1 * zb + w2 * zc))
                                        }
                                    }
                                }
                            }
                        }
                        // Conservative edge stamping.
                        let pts = [(ax, ay, t.a.z), (bx, by, t.b.z), (cx, cy, t.c.z)]
                        for e in 0..<3 {
                            let (x0, y0, z0) = pts[e], (x1, y1, z1) = pts[(e + 1) % 3]
                            let len = Swift.max(abs(x1 - x0), abs(y1 - y0))
                            let n = Swift.max(1, Int(ceil(len * 2)))
                            for s in 0...n {
                                let u = Double(s) / Double(n)
                                stamp(Int((x0 + (x1 - x0) * u).rounded()), Int((y0 + (y1 - y0) * u).rounded()),
                                      z0 + (z1 - z0) * Float(u))
                            }
                        }
                    }
                }
            }
        }
        return g
    }
}

public enum DistanceTransform {
    /// Exact Euclidean distance (in world units) from every cell to the nearest `feature` cell.
    /// Cells beyond the grid are treated as non-features.
    public static func distance(width W: Int, height H: Int, res: Double, isFeature: (Int) -> Bool) -> [Float] {
        let INF: Float = 1e20
        var f = [Float](repeating: INF, count: W * H)
        for i in 0..<(W * H) where isFeature(i) { f[i] = 0 }
        f.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            // Columns
            Parallel.forEach(W) { r in
                var tmp = [Double](repeating: 0, count: H), out = [Double](repeating: 0, count: H)
                var v = [Int](repeating: 0, count: H), z = [Double](repeating: 0, count: H + 1)
                for x in r {
                    for y in 0..<H { tmp[y] = Double(p[y * W + x]) }
                    dt1d(tmp, &out, H, &v, &z)
                    for y in 0..<H { p[y * W + x] = Float(Swift.min(out[y], 1e20)) }
                }
            }
            Parallel.forEach(H) { r in
                var tmp = [Double](repeating: 0, count: W), out = [Double](repeating: 0, count: W)
                var v = [Int](repeating: 0, count: W), z = [Double](repeating: 0, count: W + 1)
                for y in r {
                    for x in 0..<W { tmp[x] = Double(p[y * W + x]) }
                    dt1d(tmp, &out, W, &v, &z)
                    for x in 0..<W { p[y * W + x] = out[x] >= 1e19 ? INF : Float(out[x].squareRoot() * res) }
                }
            }
        }
        return f
    }

    /// Felzenszwalb & Huttenlocher 1D squared distance transform (Double internally for precision).
    @inline(__always)
    static func dt1d(_ f: [Double], _ d: inout [Double], _ n: Int, _ v: inout [Int], _ z: inout [Double]) {
        let INF = 1e20
        var first = -1
        for q in 0..<n where f[q] < INF * 0.5 { first = q; break }
        if first < 0 {
            for q in 0..<n { d[q] = INF }
            return
        }
        var k = 0
        v[0] = first
        z[0] = -.infinity
        z[1] = .infinity
        if first + 1 < n {
            for q in (first + 1)..<n {
                if f[q] >= INF * 0.5 { continue }
                let fq = f[q] + Double(q * q)
                var s: Double
                while true {
                    let vk = v[k]
                    s = (fq - (f[vk] + Double(vk * vk))) / Double(2 * q - 2 * vk)
                    if s <= z[k] && k > 0 { k -= 1 } else { break }
                }
                k += 1
                v[k] = q
                z[k] = s
                z[k + 1] = .infinity
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let dq = Double(q - v[k])
            d[q] = dq * dq + f[v[k]]
        }
    }
}
