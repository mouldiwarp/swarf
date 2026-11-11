import Foundation

public enum STLError: Error, LocalizedError {
    case empty
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "The STL file contains no triangles."
        case .malformed(let s): return "Malformed STL: \(s)"
        }
    }
}

public enum STL {
    public static func read(url: URL) throws -> Mesh {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Mesh {
        guard data.count >= 15 else { throw STLError.empty }
        if data.count >= 84 {
            let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            if 84 + Int(count) * 50 == data.count {
                return try parseBinary(data, count: Int(count))
            }
        }
        // Not an exact binary size: try ASCII if it looks like text.
        let head = data.prefix(512)
        if let s = String(data: head, encoding: .ascii), s.lowercased().contains("solid"), s.lowercased().contains("facet") || data.count < 512 {
            return try parseASCII(data)
        }
        if data.count >= 84 {
            let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            if 84 + Int(count) * 50 <= data.count { return try parseBinary(data, count: Int(count)) }
        }
        return try parseASCII(data)
    }

    static func parseBinary(_ data: Data, count: Int) throws -> Mesh {
        guard count > 0 else { throw STLError.empty }
        var tris = [Triangle]()
        tris.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            var off = 84
            for _ in 0..<count {
                func v(_ o: Int) -> SIMD3<Float> {
                    SIMD3<Float>(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                 raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                }
                let t = Triangle(v(off + 12), v(off + 24), v(off + 36))
                if t.a.x.isFinite && t.b.x.isFinite && t.c.x.isFinite { tris.append(t) }
                off += 50
            }
        }
        guard !tris.isEmpty else { throw STLError.empty }
        return Mesh(triangles: tris)
    }

    static func parseASCII(_ data: Data) throws -> Mesh {
        var verts: [SIMD3<Float>] = []
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            @inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
            func token() -> (Int, Int)? {
                while i < n && isSpace(p[i]) { i += 1 }
                if i >= n { return nil }
                let s = i
                while i < n && !isSpace(p[i]) { i += 1 }
                return (s, i)
            }
            func float() throws -> Float {
                guard let (s, e) = token() else { throw STLError.malformed("unexpected end of file") }
                var buf = [CChar](repeating: 0, count: e - s + 1)
                for k in s..<e { buf[k - s] = CChar(bitPattern: p[k]) }
                return Float(strtod(buf, nil))
            }
            while let (s, e) = token() {
                // match "vertex"
                if e - s == 6 && p[s] == 118 && p[s + 1] == 101 && p[s + 2] == 114 {
                    verts.append(SIMD3<Float>(try float(), try float(), try float()))
                }
            }
        }
        guard verts.count >= 3 else { throw STLError.empty }
        var tris = [Triangle]()
        tris.reserveCapacity(verts.count / 3)
        var k = 0
        while k + 2 < verts.count {
            tris.append(Triangle(verts[k], verts[k + 1], verts[k + 2]))
            k += 3
        }
        return Mesh(triangles: tris)
    }

    public static func binaryData(_ mesh: Mesh, header: String = "Swarf STL") -> Data {
        var d = Data(count: 84 + mesh.triangles.count * 50)
        d.withUnsafeMutableBytes { raw in
            let h = Array(header.utf8.prefix(80))
            for (i, b) in h.enumerated() { raw[i] = b }
            raw.storeBytes(of: UInt32(mesh.triangles.count), toByteOffset: 80, as: UInt32.self)
            var off = 84
            for t in mesh.triangles {
                let vs = [t.normal, t.a, t.b, t.c]
                for (j, v) in vs.enumerated() {
                    raw.storeBytes(of: v.x, toByteOffset: off + j * 12, as: Float.self)
                    raw.storeBytes(of: v.y, toByteOffset: off + j * 12 + 4, as: Float.self)
                    raw.storeBytes(of: v.z, toByteOffset: off + j * 12 + 8, as: Float.self)
                }
                off += 50
            }
        }
        return d
    }

    // MARK: Primitive generators (used by tests and the sample project)

    public static func box(_ size: V3, at origin: V3 = .zero) -> Mesh {
        let o = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))
        let s = SIMD3<Float>(Float(size.x), Float(size.y), Float(size.z))
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { o + SIMD3(x, y, z) * s }
        let c = [p(0, 0, 0), p(1, 0, 0), p(1, 1, 0), p(0, 1, 0), p(0, 0, 1), p(1, 0, 1), p(1, 1, 1), p(0, 1, 1)]
        let f: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
        ]
        return Mesh(triangles: f.map { Triangle(c[$0.0], c[$0.1], c[$0.2]) })
    }

    /// Upper hemisphere (dome) of radius r sitting on z=0, closed with a bottom disc.
    public static func dome(radius r: Double, segments: Int = 48, rings: Int = 24, center: V2 = .zero) -> Mesh {
        var tris: [Triangle] = []
        func pt(_ ring: Int, _ seg: Int) -> SIMD3<Float> {
            let phi = Double(ring) / Double(rings) * .pi / 2  // 0 = top
            let th = Double(seg) / Double(segments) * 2 * .pi
            return SIMD3<Float>(Float(center.x + r * sin(phi) * cos(th)), Float(center.y + r * sin(phi) * sin(th)),
                                Float(r * cos(phi)))
        }
        for i in 0..<rings {
            for j in 0..<segments {
                let a = pt(i, j), b = pt(i + 1, j), c = pt(i + 1, j + 1), d = pt(i, j + 1)
                if i > 0 { tris.append(Triangle(a, b, d)) }
                tris.append(Triangle(d, b, c))
            }
        }
        let cc = SIMD3<Float>(Float(center.x), Float(center.y), 0)
        for j in 0..<segments { tris.append(Triangle(cc, pt(rings, j + 1), pt(rings, j))) }
        return Mesh(triangles: tris)
    }

    public static func merge(_ meshes: [Mesh]) -> Mesh {
        Mesh(triangles: meshes.flatMap(\.triangles))
    }
}
