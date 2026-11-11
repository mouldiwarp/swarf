import Foundation
import simd

/// Height-field stock simulation (3-axis material removal).
public struct StockSimulator: Sendable {
    public private(set) var stock: Grid2D
    public let stockSize: V3

    public init(stockSize: V3, resolution: Double) {
        self.stockSize = stockSize
        stock = Grid2D(covering: V2(0, 0), V2(stockSize.x, stockSize.y), res: resolution, fill: Float(stockSize.z))
    }

    public static func defaultResolution(for stockSize: V3) -> Double {
        max(0.1, min(1.0, max(stockSize.x, stockSize.y) / 500))
    }

    /// Radial profile lookup (offset vs. squared distance) for sub-cell exact stamping.
    struct Profile { var r2: Double; var table: [Float] }
    private var profiles: [UUID: Profile] = [:]

    mutating func profile(_ tool: Tool) -> Profile {
        if let p = profiles[tool.id] { return p }
        let r2 = tool.radius * tool.radius
        let n = 4096
        let table = (0...n).map { i -> Float in
            Float(tool.profileOffset(at: (Double(i) / Double(n) * r2).squareRoot()) ?? 0)
        }
        let p = Profile(r2: r2, table: table)
        profiles[tool.id] = p
        return p
    }

    /// Remove material along the segment from `a` to `b` (tool tip positions).
    public mutating func cut(from a: V3, to b: V3, tool: Tool) {
        if a.z > stockSize.z + 0.01 && b.z > stockSize.z + 0.01 { return }
        let prof = profile(tool)
        let len = simd_distance(a.xy, b.xy)
        let n = max(1, Int(ceil(len / (stock.res * 0.5))))
        let W = stock.width, H = stock.height
        let res = stock.res, ox = stock.origin.x, oy = stock.origin.y
        let R = tool.radius
        let tableScale = Double(prof.table.count - 1) / prof.r2
        stock.data.withUnsafeMutableBufferPointer { buf in
            let d = buf.baseAddress!
            prof.table.withUnsafeBufferPointer { tb in
                for s in 0...n {
                    let p = a + (b - a) * (Double(s) / Double(n))
                    let x0 = max(0, Int(ceil((p.x - R - ox) / res))), x1 = min(W - 1, Int(floor((p.x + R - ox) / res)))
                    let y0 = max(0, Int(ceil((p.y - R - oy) / res))), y1 = min(H - 1, Int(floor((p.y + R - oy) / res)))
                    if x0 > x1 || y0 > y1 { continue }
                    for y in y0...y1 {
                        let dy = oy + Double(y) * res - p.y
                        let dy2 = dy * dy
                        for x in x0...x1 {
                            let dx = ox + Double(x) * res - p.x
                            let r2 = dx * dx + dy2
                            if r2 > prof.r2 { continue }
                            let h = Float(p.z) + tb[Int(r2 * tableScale)]
                            let idx = y * W + x
                            if h < d[idx] { d[idx] = h }
                        }
                    }
                }
            }
        }
    }

    /// Simulate the given toolpaths, optionally stopping after `limit` tessellated segments in total.
    public mutating func run(_ toolpaths: [Toolpath], limit: Int? = nil) {
        var count = 0
        for tp in toolpaths {
            let pts = tp.tessellated(maxSegment: max(0.2, stock.res))
            for i in 1..<max(1, pts.count) {
                if let l = limit, count >= l { return }
                let (p, kind) = pts[i]
                if kind != .rapid { cut(from: pts[i - 1].0, to: p, tool: tp.tool) }
                count += 1
            }
        }
    }

    public struct Analysis: Sendable {
        public var gougeCells = 0
        public var maxGouge = 0.0
        public var leftoverCells = 0
        public var maxLeftover = 0.0
        public var removedVolume = 0.0  // mm³
        /// Per-cell deviation (stock − model); negative = gouge. NaN where no model.
        public var deviation: [Float] = []
    }

    /// Compare the simulated stock with the model's top surface.
    public func analyze(model: PlacedModel, tolerance: Double = 0.05) -> Analysis {
        let target = Heightmap.rasterizeTop(model.mesh, into: Grid2D(like: stock, data: [Float](repeating: Grid2D.none, count: stock.data.count)))
        var a = Analysis()
        a.deviation = [Float](repeating: .nan, count: stock.data.count)
        let cellArea = stock.res * stock.res
        let W = stock.width, H = stock.height
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                a.removedVolume += Double(Float(stockSize.z) - stock.data[i]) * cellArea
                let t = target.data[i]
                guard t > Grid2D.none / 2 else { continue }
                // Ignore cells on steep walls where pixelisation dominates.
                var steep = false
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= W || ny >= H { continue }
                    let tn = target.data[ny * W + nx]
                    if tn < Grid2D.none / 2 || abs(tn - t) > Float(stock.res * 2) { steep = true }
                }
                let dev = stock.data[i] - t
                a.deviation[i] = steep ? max(0, dev) : dev
                if steep { continue }
                if Double(dev) < -tolerance {
                    a.gougeCells += 1
                    a.maxGouge = max(a.maxGouge, Double(-dev))
                } else if Double(dev) > tolerance {
                    a.leftoverCells += 1
                    a.maxLeftover = max(a.maxLeftover, Double(dev))
                }
            }
        }
        return a
    }

    /// Checks whether any cutting move entered a keep-out region.
    public static func keepOutViolations(_ toolpaths: [Toolpath], regions: [Region]) -> [String] {
        var out: [String] = []
        for tp in toolpaths {
            let r = tp.tool.radius
            for reg in regions where reg.enabled && reg.kind == .keepOut {
                var worst: (V3, Double)? = nil
                let pts = tp.tessellated(maxSegment: 0.5)
                for i in 1..<max(1, pts.count) where pts[i].1 != .rapid {
                    // check densely along the segment
                    let a = pts[i - 1].0, b = pts[i].0
                    let n = max(1, Int(ceil(simd_distance(a.xy, b.xy) / 0.25)))
                    for k in 0...n {
                        let p = a + (b - a) * (Double(k) / Double(n))
                        guard p.z < (reg.protectBelowZ ?? .infinity) - 0.01 else { continue }
                        let d = reg.distance(to: p.xy)
                        if d < r - 0.05 && d < (worst?.1 ?? .infinity) { worst = (p, d) }
                    }
                }
                if let (p, d) = worst {
                    out.append(String(format: "%@ enters keep-out region “%@” (tool edge %.2f mm inside, at X%.1f Y%.1f Z%.1f).",
                                      tp.name, reg.name, r - d, p.x, p.y, p.z))
                }
            }
        }
        return out
    }
}
