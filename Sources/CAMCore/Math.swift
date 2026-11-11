import Foundation
import simd

public typealias V2 = SIMD2<Double>
public typealias V3 = SIMD3<Double>

public struct AABB3: Codable, Sendable, Equatable {
    public var min: V3
    public var max: V3

    public init(min: V3, max: V3) { self.min = min; self.max = max }

    public static let empty = AABB3(min: V3(repeating: .infinity), max: V3(repeating: -.infinity))

    public var isEmpty: Bool { min.x > max.x }
    public var size: V3 { isEmpty ? .zero : max - min }
    public var center: V3 { (min + max) * 0.5 }

    public mutating func include(_ p: V3) {
        min = simd_min(min, p)
        max = simd_max(max, p)
    }

    public func union(_ o: AABB3) -> AABB3 {
        AABB3(min: simd_min(min, o.min), max: simd_max(max, o.max))
    }
}

/// A 3x3 rotation stored as rows, Codable-friendly.
public struct Rotation: Codable, Sendable, Equatable {
    public var m: [Double]  // row-major 3x3

    public init(_ matrix: simd_double3x3) {
        m = [
            matrix[0][0], matrix[1][0], matrix[2][0],
            matrix[0][1], matrix[1][1], matrix[2][1],
            matrix[0][2], matrix[1][2], matrix[2][2],
        ]
    }

    public static let identity = Rotation(matrix_identity_double3x3)

    public var matrix: simd_double3x3 {
        simd_double3x3(rows: [
            V3(m[0], m[1], m[2]),
            V3(m[3], m[4], m[5]),
            V3(m[6], m[7], m[8]),
        ])
    }

    public func apply(_ v: V3) -> V3 { matrix * v }

    /// Compose: first `self`, then `other`.
    public func then(_ other: Rotation) -> Rotation { Rotation(other.matrix * matrix) }

    /// Rotation that maps unit vector `from` onto unit vector `to`.
    public static func aligning(_ from: V3, to: V3) -> Rotation {
        let f = simd_normalize(from), t = simd_normalize(to)
        let d = simd_dot(f, t)
        if d > 1 - 1e-12 { return .identity }
        if d < -1 + 1e-12 {
            // 180° about any axis perpendicular to f
            var axis = simd_cross(f, V3(1, 0, 0))
            if simd_length(axis) < 1e-6 { axis = simd_cross(f, V3(0, 1, 0)) }
            return Rotation(simd_double3x3(simd_quatd(angle: .pi, axis: simd_normalize(axis))))
        }
        let q = simd_quatd(from: f, to: t)
        return Rotation(simd_double3x3(q))
    }

    public static func about(axis: V3, degrees: Double) -> Rotation {
        Rotation(simd_double3x3(simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis))))
    }

    /// Snap near-axis-aligned entries to exact values to avoid drift from repeated 90° rotations.
    public func snapped() -> Rotation {
        var r = self
        r.m = m.map { v in
            for c in [-1.0, 0.0, 1.0] where abs(v - c) < 1e-9 { return c }
            return v
        }
        return r
    }
}

@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

extension V2 {
    @inline(__always) var perp: V2 { V2(-y, x) }
    @inline(__always) func dist(_ o: V2) -> Double { simd_distance(self, o) }
}

extension V3 {
    @inline(__always) var xy: V2 { V2(x, y) }
    init(_ p: V2, _ z: Double) { self.init(p.x, p.y, z) }
}
