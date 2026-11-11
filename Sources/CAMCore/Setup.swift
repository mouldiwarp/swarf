import Foundation
import simd

/// Where the work coordinate zero (G54 origin) sits on the stock.
public struct WorkOrigin: Codable, Sendable, Equatable, Hashable {
    public enum XAnchor: String, Codable, Sendable, CaseIterable { case left, center, right }
    public enum YAnchor: String, Codable, Sendable, CaseIterable { case front, center, back }
    public enum ZAnchor: String, Codable, Sendable, CaseIterable { case stockTop, stockBottom }

    public var x: XAnchor = .left
    public var y: YAnchor = .front
    public var z: ZAnchor = .stockTop

    public init(x: XAnchor = .left, y: YAnchor = .front, z: ZAnchor = .stockTop) {
        self.x = x; self.y = y; self.z = z
    }

    /// WorkBee convention: front-left corner of the stock top surface.
    public static let workbeeDefault = WorkOrigin()
}

public enum ModelZPlacement: String, Codable, Sendable, CaseIterable {
    case top, center, bottom
}

/// Rectangular stock in "stock space": X right, Y away from operator, Z up; (0,0,0) = front-left-bottom corner.
public struct StockSetup: Codable, Sendable, Equatable {
    public var autoSize: Bool = true
    public var marginXY: Double = 5
    public var extraTop: Double = 0
    public var extraBottom: Double = 0
    public var size: V3 = V3(100, 100, 20)
    public var modelZ: ModelZPlacement = .top
    public var modelOffset: V2 = .zero  // shift of model centre from stock centre
    public var materialID: String = "mdf"

    public init() {}
}

public struct Orientation: Codable, Sendable, Equatable {
    public var rotation: Rotation = .identity
    public var scale: Double = 1

    public init() {}

    public mutating func rotate(axis: V3, degrees: Double) {
        rotation = rotation.then(.about(axis: axis, degrees: degrees)).snapped()
    }

    /// Make the face with (current, oriented) normal `n` point straight up.
    public mutating func faceUp(normal n: V3) {
        rotation = rotation.then(.aligning(n, to: V3(0, 0, 1))).snapped()
    }

    /// Lay the face with (current, oriented) normal `n` flat on the bed.
    public mutating func faceDown(normal n: V3) {
        rotation = rotation.then(.aligning(n, to: V3(0, 0, -1))).snapped()
    }
}

public enum Placement {
    /// Choose the rotation that lays the largest coplanar area flat on the bed.
    public static func layFlatRotation(_ mesh: Mesh) -> Rotation {
        var buckets: [SIMD3<Int32>: (n: SIMD3<Float>, area: Float)] = [:]
        for t in mesh.triangles {
            let n = t.normal
            let k = SIMD3<Int32>(Int32((n.x * 50).rounded()), Int32((n.y * 50).rounded()), Int32((n.z * 50).rounded()))
            let prev = buckets[k] ?? (n, 0)
            buckets[k] = (prev.n, prev.area + t.area)
        }
        guard let best = buckets.values.max(by: { $0.area < $1.area }) else { return .identity }
        return Rotation.aligning(V3(Double(best.n.x), Double(best.n.y), Double(best.n.z)), to: V3(0, 0, -1)).snapped()
    }

    /// Fraction of downward-facing, non-vertical surface area that a 3-axis tool cannot reach from above.
    public static func undercutArea(_ mesh: Mesh) -> (undercut: Double, total: Double) {
        var u = 0.0, tot = 0.0
        for t in mesh.triangles {
            let a = Double(t.area)
            tot += a
            if t.normal.z < -0.02 { u += a }
        }
        return (u, tot)
    }
}

/// Fully resolved geometry for a job: the oriented model placed in stock space.
public struct PlacedModel: Sendable {
    public var mesh: Mesh
    public var stockSize: V3
    public var modelBounds: AABB3

    public var stockTop: Double { stockSize.z }

    public init(raw: Mesh, orientation: Orientation, stock: StockSetup) {
        var m = raw.scaled(orientation.scale).transformed(rotation: orientation.rotation)
        let b = m.bounds
        let size: V3
        if stock.autoSize {
            size = V3(b.size.x + 2 * stock.marginXY, b.size.y + 2 * stock.marginXY,
                      b.size.z + stock.extraTop + stock.extraBottom)
        } else {
            size = stock.size
        }
        let targetCenterXY = V2(size.x / 2, size.y / 2) + stock.modelOffset
        let dz: Double
        switch stock.modelZ {
        case .top: dz = size.z - (stock.autoSize ? stock.extraTop : 0) - b.max.z
        case .bottom: dz = (stock.autoSize ? stock.extraBottom : 0) - b.min.z
        case .center: dz = size.z / 2 - b.center.z
        }
        let shift = V3(targetCenterXY.x - b.center.x, targetCenterXY.y - b.center.y, dz)
        m = m.translated(shift)
        mesh = m
        stockSize = size
        modelBounds = m.bounds
    }

    /// Work origin position in stock space.
    public func originPoint(_ o: WorkOrigin) -> V3 {
        let x: Double = { switch o.x { case .left: 0; case .center: stockSize.x / 2; case .right: stockSize.x } }()
        let y: Double = { switch o.y { case .front: 0; case .center: stockSize.y / 2; case .back: stockSize.y } }()
        let z: Double = o.z == .stockTop ? stockSize.z : 0
        return V3(x, y, z)
    }
}
