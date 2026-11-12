import Foundation
import simd

public enum MoveKind: UInt8, Codable, Sendable {
    case rapid, feed, plunge, arcCW, arcCCW
}

public struct Move: Codable, Sendable, Equatable {
    public var kind: MoveKind
    public var to: V3
    /// Arc centre (XY) for arc moves.
    public var center: V2? = nil
    public var feed: Double = 0

    public init(_ kind: MoveKind, _ to: V3, feed: Double = 0, center: V2? = nil) {
        self.kind = kind; self.to = to; self.feed = feed; self.center = center
    }

    public var isArc: Bool { kind == .arcCW || kind == .arcCCW }
}

public struct Toolpath: Sendable, Identifiable {
    public var id: UUID  // operation id
    public var name: String
    public var kind: OperationKind
    public var tool: Tool
    public var rpm: Double
    public var start: V3
    public var moves: [Move]
    public var warnings: [String] = []
    /// Engraving operations (V-carve): cells (1 = inside) where cutting below the model surface is intentional.
    public var engraveMask: Grid2D? = nil
    /// The face this toolpath machines. Side-B moves are in side-B stock space (the machine's view after the flip).
    public var side: MachiningSide = .a

    public init(id: UUID, name: String, kind: OperationKind, tool: Tool, rpm: Double, start: V3, moves: [Move]) {
        self.id = id; self.name = name; self.kind = kind; self.tool = tool; self.rpm = rpm; self.start = start; self.moves = moves
    }

    /// Expanded polyline points (arcs tessellated) with move kinds, for rendering and simulation.
    public func tessellated(maxSegment: Double = 0.5) -> [(V3, MoveKind)] {
        var out: [(V3, MoveKind)] = [(start, .rapid)]
        var p = start
        for m in moves {
            if m.isArc, let c = m.center {
                let pts = Toolpath.arcPoints(from: p, to: m.to, center: c, cw: m.kind == .arcCW, maxSegment: maxSegment)
                for q in pts { out.append((q, m.kind)) }
            } else {
                out.append((m.to, m.kind))
            }
            p = m.to
        }
        return out
    }

    public static func arcPoints(from a: V3, to b: V3, center c: V2, cw: Bool, maxSegment: Double) -> [V3] {
        let r = simd_distance(a.xy, c)
        let a0 = atan2(a.y - c.y, a.x - c.x)
        var a1 = atan2(b.y - c.y, b.x - c.x)
        if cw {
            while a1 >= a0 { a1 -= 2 * .pi }
        } else {
            while a1 <= a0 { a1 += 2 * .pi }
        }
        let sweep = a1 - a0
        let n = max(1, Int(ceil(abs(sweep) * r / maxSegment)))
        return (1...n).map { i in
            let t = Double(i) / Double(n)
            let ang = a0 + sweep * t
            return V3(c.x + r * cos(ang), c.y + r * sin(ang), a.z + (b.z - a.z) * t)
        }
    }

    public struct Stats: Sendable {
        public var cutLength: Double = 0
        public var rapidLength: Double = 0
        public var seconds: Double = 0
        public var bounds = AABB3.empty
    }

    public func stats(rapidRate: Double = 5000, acceleration: Double = 500) -> Stats {
        var s = Stats()
        var p = start
        var prevDir: V3? = nil
        for m in moves {
            var len: Double
            if m.isArc, let c = m.center {
                let pts = Toolpath.arcPoints(from: p, to: m.to, center: c, cw: m.kind == .arcCW, maxSegment: 1)
                len = 0
                var q = p
                for x in pts { len += simd_distance(q, x); q = x }
            } else {
                len = simd_distance(p, m.to)
            }
            let v = (m.kind == .rapid ? rapidRate : max(1, m.feed)) / 60  // mm/s
            var t = len / v
            // Acceleration penalty at direction changes (trapezoidal approx).
            if len > 1e-9 {
                let dir = (m.to - p) / max(len, 1e-9)
                if let pd = prevDir {
                    let cosA = simd_dot(pd, dir)
                    let slow = (1 - max(0, cosA)) * 0.5 + (cosA < 0 ? 0.5 : 0)
                    t += slow * v / max(1, acceleration)
                } else {
                    t += v / max(1, acceleration)
                }
                prevDir = dir
            }
            s.seconds += t
            if m.kind == .rapid { s.rapidLength += len } else { s.cutLength += len }
            s.bounds.include(m.to)
            p = m.to
        }
        return s
    }
}

/// Helper that accumulates moves with sensible linking.
struct PathBuilder {
    var moves: [Move] = []
    var pos: V3
    let safeZ: Double
    let feed: Double
    let plunge: Double

    init(start: V3, safeZ: Double, feed: Double, plunge: Double) {
        pos = start; self.safeZ = safeZ; self.feed = feed; self.plunge = plunge
    }

    mutating func rapid(_ p: V3) {
        if simd_distance(p, pos) < 1e-6 { return }
        moves.append(Move(.rapid, p)); pos = p
    }

    mutating func cut(_ p: V3, feed f: Double? = nil) {
        if simd_distance(p, pos) < 1e-6 { return }
        let isPlunge = abs(p.x - pos.x) < 1e-9 && abs(p.y - pos.y) < 1e-9 && p.z < pos.z
        moves.append(Move(isPlunge ? .plunge : .feed, p, feed: isPlunge ? plunge : (f ?? feed))); pos = p
    }

    mutating func retract() { rapid(V3(pos.x, pos.y, safeZ)) }

    /// Retract, traverse, rapid down to `approachZ`, then plunge to `p.z`.
    mutating func travel(to p: V3, approachZ: Double) {
        if pos.z < safeZ - 1e-9 { retract() }
        rapid(V3(p.x, p.y, safeZ))
        let az = min(safeZ, max(p.z, approachZ))
        rapid(V3(p.x, p.y, az))
        cut(p)
    }

    mutating func polyline(_ pts: [V3], feed f: Double? = nil) {
        for p in pts { cut(p, feed: f) }
    }

    var length: Double {
        var l = 0.0, p = moves.first?.to ?? pos
        for m in moves { l += simd_distance(p, m.to); p = m.to }
        return l
    }
}
