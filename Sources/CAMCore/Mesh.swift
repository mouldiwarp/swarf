import Foundation
import simd

public struct Triangle: Sendable, Equatable {
    public var a: SIMD3<Float>
    public var b: SIMD3<Float>
    public var c: SIMD3<Float>

    public init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        self.a = a; self.b = b; self.c = c
    }

    public var normal: SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        let l = simd_length(n)
        return l > 0 ? n / l : SIMD3<Float>(0, 0, 1)
    }

    public var area: Float { simd_length(simd_cross(b - a, c - a)) * 0.5 }
}

/// Triangle soup mesh. Units are millimetres.
public struct Mesh: Sendable {
    public var triangles: [Triangle]

    public init(triangles: [Triangle]) { self.triangles = triangles }

    public var bounds: AABB3 {
        var bb = AABB3.empty
        for t in triangles {
            for v in [t.a, t.b, t.c] { bb.include(V3(Double(v.x), Double(v.y), Double(v.z))) }
        }
        return bb
    }

    public func transformed(rotation: Rotation, translation: V3 = .zero) -> Mesh {
        let m = simd_float3x3(
            rows: [
                SIMD3<Float>(Float(rotation.m[0]), Float(rotation.m[1]), Float(rotation.m[2])),
                SIMD3<Float>(Float(rotation.m[3]), Float(rotation.m[4]), Float(rotation.m[5])),
                SIMD3<Float>(Float(rotation.m[6]), Float(rotation.m[7]), Float(rotation.m[8])),
            ])
        let t = SIMD3<Float>(Float(translation.x), Float(translation.y), Float(translation.z))
        return Mesh(triangles: triangles.map { Triangle(m * $0.a + t, m * $0.b + t, m * $0.c + t) })
    }

    public func translated(_ d: V3) -> Mesh {
        let t = SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z))
        return Mesh(triangles: triangles.map { Triangle($0.a + t, $0.b + t, $0.c + t) })
    }

    public func scaled(_ s: Double) -> Mesh {
        let f = Float(s)
        return Mesh(triangles: triangles.map { Triangle($0.a * f, $0.b * f, $0.c * f) })
    }

    /// Topology report: counts boundary / non-manifold edges after welding vertices.
    public struct Diagnostics: Sendable {
        public var triangleCount: Int
        public var vertexCount: Int
        public var openEdges: Int
        public var nonManifoldEdges: Int
        public var degenerateTriangles: Int
        public var isWatertight: Bool { openEdges == 0 && nonManifoldEdges == 0 }
    }

    public func diagnostics(weldTolerance: Float = 1e-4) -> Diagnostics {
        var index: [SIMD3<Int32>: Int32] = [:]
        index.reserveCapacity(triangles.count)
        func key(_ v: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((v.x / weldTolerance).rounded()), Int32((v.y / weldTolerance).rounded()),
                         Int32((v.z / weldTolerance).rounded()))
        }
        func vid(_ v: SIMD3<Float>) -> Int32 {
            let k = key(v)
            if let i = index[k] { return i }
            let i = Int32(index.count)
            index[k] = i
            return i
        }
        var edges: [UInt64: Int32] = [:]
        edges.reserveCapacity(triangles.count * 3 / 2)
        var degenerate = 0
        for t in triangles {
            let ids = [vid(t.a), vid(t.b), vid(t.c)]
            if ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2] { degenerate += 1; continue }
            for k in 0..<3 {
                let i = ids[k], j = ids[(k + 1) % 3]
                let e = UInt64(UInt32(min(i, j))) << 32 | UInt64(UInt32(max(i, j)))
                edges[e, default: 0] += 1
            }
        }
        var open = 0, nonManifold = 0
        for (_, c) in edges {
            if c == 1 { open += 1 } else if c > 2 { nonManifold += 1 }
        }
        return Diagnostics(triangleCount: triangles.count, vertexCount: index.count, openEdges: open,
                           nonManifoldEdges: nonManifold, degenerateTriangles: degenerate)
    }

    /// Sharp and open edges (after welding) for outline rendering: edges whose two faces meet at more than `angle`
    /// degrees, plus edges with only one face. Each edge comes with the average normal of its faces.
    public func featureEdges(angle: Float = 25, weldTolerance: Float = 1e-3) -> [(a: SIMD3<Float>, b: SIMD3<Float>, n: SIMD3<Float>)] {
        var index: [SIMD3<Int32>: Int32] = [:]
        var verts: [SIMD3<Float>] = []
        index.reserveCapacity(triangles.count)
        func vid(_ v: SIMD3<Float>) -> Int32 {
            let k = SIMD3<Int32>(Int32((v.x / weldTolerance).rounded()), Int32((v.y / weldTolerance).rounded()),
                                 Int32((v.z / weldTolerance).rounded()))
            if let i = index[k] { return i }
            let i = Int32(verts.count)
            index[k] = i; verts.append(v)
            return i
        }
        struct E { var n0: SIMD3<Float>; var n1: SIMD3<Float>?; var count: Int }
        var edges: [UInt64: E] = [:]
        edges.reserveCapacity(triangles.count * 3 / 2)
        for t in triangles {
            let ids = [vid(t.a), vid(t.b), vid(t.c)]
            if ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2] { continue }
            let n = t.normal
            for k in 0..<3 {
                let i = ids[k], j = ids[(k + 1) % 3]
                let key = UInt64(UInt32(min(i, j))) << 32 | UInt64(UInt32(max(i, j)))
                if var e = edges[key] {
                    if e.n1 == nil { e.n1 = n }
                    e.count += 1
                    edges[key] = e
                } else {
                    edges[key] = E(n0: n, n1: nil, count: 1)
                }
            }
        }
        let cosLimit = cos(angle * .pi / 180)
        var out: [(a: SIMD3<Float>, b: SIMD3<Float>, n: SIMD3<Float>)] = []
        for (key, e) in edges {
            let a = verts[Int(key >> 32)], b = verts[Int(key & 0xffff_ffff)]
            if let n1 = e.n1, e.count == 2 {
                if simd_dot(e.n0, n1) >= cosLimit { continue }
                let s = e.n0 + n1
                let l = simd_length(s)
                out.append((a, b, l > 1e-6 ? s / l : e.n0))
            } else {
                out.append((a, b, e.n0))
            }
        }
        return out
    }

    /// Distinct horizontal upward-facing plane heights (useful as extra roughing levels).
    public func flatUpwardFaceHeights(minArea: Float = 1, tolerance: Float = 0.01) -> [Double] {
        var buckets: [Int: (z: Double, area: Float)] = [:]
        for t in triangles {
            let n = t.normal
            guard n.z > 0.9995 else { continue }
            let z = Double(t.a.z + t.b.z + t.c.z) / 3
            let k = Int((z / Double(tolerance)).rounded())
            let prev = buckets[k] ?? (z, 0)
            buckets[k] = (prev.z, prev.area + t.area)
        }
        return buckets.values.filter { $0.area >= minArea }.map(\.z).sorted()
    }

    /// Ray cast (Möller–Trumbore). Returns triangle index and distance.
    public func raycast(origin: V3, direction: V3) -> (index: Int, t: Double)? {
        let o = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))
        let d = SIMD3<Float>(Float(direction.x), Float(direction.y), Float(direction.z))
        var best: (Int, Float)? = nil
        for (i, tri) in triangles.enumerated() {
            let e1 = tri.b - tri.a, e2 = tri.c - tri.a
            let p = simd_cross(d, e2)
            let det = simd_dot(e1, p)
            if abs(det) < 1e-12 { continue }
            let inv = 1 / det
            let s = o - tri.a
            let u = simd_dot(s, p) * inv
            if u < 0 || u > 1 { continue }
            let q = simd_cross(s, e1)
            let v = simd_dot(d, q) * inv
            if v < 0 || u + v > 1 { continue }
            let t = simd_dot(e2, q) * inv
            if t > 1e-6, t < (best?.1 ?? .infinity) { best = (i, t) }
        }
        return best.map { ($0.0, Double($0.1)) }
    }

    /// All triangles coplanar with (and connected-by-normal to) the picked triangle, for face highlighting.
    public func coplanarGroup(of index: Int, angleTolerance: Float = 0.5) -> [Int] {
        let ref = triangles[index]
        let n = ref.normal
        let d = simd_dot(n, ref.a)
        let cosTol = cos(angleTolerance * .pi / 180)
        var out: [Int] = []
        for (i, t) in triangles.enumerated() {
            if simd_dot(t.normal, n) >= cosTol && abs(simd_dot(n, t.a) - d) < 0.05 { out.append(i) }
        }
        return out
    }
}
