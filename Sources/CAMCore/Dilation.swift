import Foundation
import Metal

/// Computes the tool-tip height field ("inverse tool offset" / drop-cutter on a heightmap):
/// T(p) = max over cutter footprint of  H(p + d) - profile(|d|).
public enum ToolDilation {
    public struct Kernel: Sendable {
        public var dx: [Int32] = []
        public var dy: [Int32] = []
        public var off: [Float] = []
        public var count: Int { dx.count }
    }

    public static func kernel(for tool: Tool, res: Double, extraRadius: Double = 0) -> Kernel {
        let r = tool.radius + extraRadius
        let n = Int(ceil(r / res))
        var k = Kernel()
        for j in -n...n {
            for i in -n...n {
                let d = (Double(i * i + j * j)).squareRoot() * res
                if let o = tool.profileOffset(at: d, extraRadius: extraRadius) {
                    k.dx.append(Int32(i)); k.dy.append(Int32(j)); k.off.append(Float(o))
                }
            }
        }
        if k.count == 0 { k.dx = [0]; k.dy = [0]; k.off = [0] }
        return k
    }

    /// A flat disc of `radius` mm: dilating with it gives the highest value within that distance.
    public static func disc(radius: Double, res: Double) -> Kernel {
        let n = Int(ceil(radius / res))
        var k = Kernel()
        for j in -n...n {
            for i in -n...n where Double(i * i + j * j).squareRoot() * res <= radius + 1e-9 {
                k.dx.append(Int32(i)); k.dy.append(Int32(j)); k.off.append(0)
            }
        }
        if k.count == 0 { k.dx = [0]; k.dy = [0]; k.off = [0] }
        return k
    }

    public static func dilate(_ h: Grid2D, tool: Tool, extraRadius: Double = 0, useGPU: Bool = true) -> Grid2D {
        dilate(h, kernel: kernel(for: tool, res: h.res, extraRadius: extraRadius), useGPU: useGPU)
    }

    public static func dilate(_ h: Grid2D, kernel k: Kernel, useGPU: Bool = true) -> Grid2D {
        if useGPU, let gpu = MetalDilator.shared, let out = gpu.dilate(h, kernel: k) { return out }
        return dilateCPU(h, kernel: k)
    }

    public static func dilateCPU(_ h: Grid2D, kernel k: Kernel) -> Grid2D {
        var out = Grid2D(like: h, data: [Float](repeating: Grid2D.none, count: h.data.count))
        let W = h.width, H = h.height
        h.data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                let s = src.baseAddress!, d = dst.baseAddress!
                k.dx.withUnsafeBufferPointer { kdx in
                    k.dy.withUnsafeBufferPointer { kdy in
                        k.off.withUnsafeBufferPointer { koff in
                            let n = k.count
                            Parallel.forEach(H) { rows in
                                for y in rows {
                                    for x in 0..<W {
                                        var m: Float = Grid2D.none
                                        for i in 0..<n {
                                            let xx = x + Int(kdx[i]), yy = y + Int(kdy[i])
                                            if xx < 0 || yy < 0 || xx >= W || yy >= H { continue }
                                            let v = s[yy * W + xx] - koff[i]
                                            if v > m { m = v }
                                        }
                                        d[y * W + x] = m
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}

final class MetalDilator: @unchecked Sendable {
    static let shared: MetalDilator? = MetalDilator()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let lock = NSLock()

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void dilate(device const float* src [[buffer(0)]],
                       device float* dst [[buffer(1)]],
                       device const int2* offs [[buffer(2)]],
                       device const float* koff [[buffer(3)]],
                       constant uint3& dims [[buffer(4)]],
                       uint2 gid [[thread_position_in_grid]]) {
        uint W = dims.x, H = dims.y, n = dims.z;
        if (gid.x >= W || gid.y >= H) return;
        float m = -1e9;
        int2 p0 = int2(gid);
        for (uint i = 0; i < n; i++) {
            int2 p = p0 + offs[i];
            if (p.x < 0 || p.y < 0 || p.x >= int(W) || p.y >= int(H)) continue;
            m = max(m, src[p.y * int(W) + p.x] - koff[i]);
        }
        dst[gid.y * W + gid.x] = m;
    }
    """

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(),
              let lib = try? dev.makeLibrary(source: MetalDilator.source, options: nil),
              let fn = lib.makeFunction(name: "dilate"),
              let ps = try? dev.makeComputePipelineState(function: fn) else { return nil }
        device = dev; queue = q; pipeline = ps
    }

    func dilate(_ h: Grid2D, kernel k: ToolDilation.Kernel) -> Grid2D? {
        lock.lock(); defer { lock.unlock() }
        let n = h.data.count
        var offs = [SIMD2<Int32>](repeating: .zero, count: k.count)
        for i in 0..<k.count { offs[i] = SIMD2(k.dx[i], k.dy[i]) }
        guard let src = device.makeBuffer(bytes: h.data, length: n * 4, options: .storageModeShared),
              let dst = device.makeBuffer(length: n * 4, options: .storageModeShared),
              let ob = device.makeBuffer(bytes: offs, length: max(8, offs.count * 8), options: .storageModeShared),
              let kb = device.makeBuffer(bytes: k.off, length: max(4, k.count * 4), options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        var dims = SIMD3<UInt32>(UInt32(h.width), UInt32(h.height), UInt32(k.count))
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(src, offset: 0, index: 0)
        enc.setBuffer(dst, offset: 0, index: 1)
        enc.setBuffer(ob, offset: 0, index: 2)
        enc.setBuffer(kb, offset: 0, index: 3)
        enc.setBytes(&dims, length: MemoryLayout<SIMD3<UInt32>>.stride, index: 4)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreads(MTLSize(width: h.width, height: h.height, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        let p = dst.contents().bindMemory(to: Float.self, capacity: n)
        return Grid2D(like: h, data: Array(UnsafeBufferPointer(start: p, count: n)))
    }
}
