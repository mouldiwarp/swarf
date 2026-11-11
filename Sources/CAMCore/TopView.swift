import Foundation
import simd

/// Simple software top-view raster (used for CLI previews, setup sheets and thumbnails).
public enum TopView {
    public struct Image: Sendable {
        public var width: Int
        public var height: Int
        public var rgb: [UInt8]

        public var ppm: Data {
            var d = Data("P6\n\(width) \(height)\n255\n".utf8)
            d.append(contentsOf: rgb)
            return d
        }
    }

    public static func render(stock: Grid2D, stockSize: V3, analysis: StockSimulator.Analysis?, toolpaths: [Toolpath],
                              regions: [Region] = [], pixelsPerMM: Double = 6) -> Image {
        // Keep the image a sensible size whatever the stock size.
        let longest = max(1, stockSize.x, stockSize.y)
        let pixelsPerMM = max(0.001, min(pixelsPerMM, 6000 / longest))
        let W = Int(stockSize.x * pixelsPerMM) + 1, H = Int(stockSize.y * pixelsPerMM) + 1
        var img = Image(width: W, height: H, rgb: [UInt8](repeating: 0, count: W * H * 3))
        func put(_ x: Int, _ y: Int, _ c: SIMD3<Double>) {
            guard x >= 0, y >= 0, x < W, y < H else { return }
            let i = ((H - 1 - y) * W + x) * 3
            img.rgb[i] = UInt8(max(0, min(255, c.x * 255)))
            img.rgb[i + 1] = UInt8(max(0, min(255, c.y * 255)))
            img.rgb[i + 2] = UInt8(max(0, min(255, c.z * 255)))
        }
        for y in 0..<H {
            for x in 0..<W {
                let p = V2(Double(x), Double(y)) / pixelsPerMM
                let h = Double(stock.nearest(p))
                let t = max(0, min(1, h / max(1, stockSize.z)))
                var c = SIMD3<Double>(0.25, 0.22, 0.18) + SIMD3<Double>(0.6, 0.55, 0.45) * t
                if let a = analysis {
                    let cc = stock.cellCoord(p)
                    let gx = Int(cc.x.rounded()), gy = Int(cc.y.rounded())
                    if gx >= 0, gy >= 0, gx < stock.width, gy < stock.height {
                        let dev = a.deviation[gy * stock.width + gx]
                        if !dev.isNaN {
                            if dev < -0.05 { c = SIMD3(0.9, 0.1, 0.1) } else if dev > 0.1 { c = c * 0.5 + SIMD3(0.1, 0.3, 0.8) * 0.5 }
                        }
                    }
                }
                put(x, y, c)
            }
        }
        let palette: [SIMD3<Double>] = [SIMD3(0.1, 0.9, 0.9), SIMD3(1, 0.85, 0.1), SIMD3(0.4, 1, 0.3), SIMD3(1, 0.4, 0.9), SIMD3(1, 0.6, 0.2)]
        for (k, tp) in toolpaths.enumerated() {
            let col = palette[k % palette.count]
            let pts = tp.tessellated(maxSegment: 1 / pixelsPerMM)
            for i in 1..<max(1, pts.count) where pts[i].1 != .rapid {
                let a = pts[i - 1].0.xy * pixelsPerMM, b = pts[i].0.xy * pixelsPerMM
                let n = max(1, Int(ceil(simd_distance(a, b))))
                for s in 0...n {
                    let q = a + (b - a) * (Double(s) / Double(n))
                    put(Int(q.x.rounded()), Int(q.y.rounded()), col)
                }
            }
        }
        for r in regions {
            // Regions can be edited so min > max, or lie far outside the stock: order and clip them first.
            func px(_ v: Double, _ limit: Int) -> Int { v.isFinite ? Int(max(-1, min(Double(limit), v * pixelsPerMM))) : -1 }
            let x0 = px(min(r.min.x, r.max.x), W), x1 = px(max(r.min.x, r.max.x), W)
            let y0 = px(min(r.min.y, r.max.y), H), y1 = px(max(r.min.y, r.max.y), H)
            for x in x0...x1 { put(x, y0, SIMD3(1, 0.2, 0.2)); put(x, y1, SIMD3(1, 0.2, 0.2)) }
            for y in y0...y1 { put(x0, y, SIMD3(1, 0.2, 0.2)); put(x1, y, SIMD3(1, 0.2, 0.2)) }
        }
        return img
    }
}
