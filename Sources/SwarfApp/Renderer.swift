import CAMCore
import MetalKit
import simd

// MARK: Matrix helpers

extension float4x4 {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect, z = far / (near - far)
        return float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    static func orthographic(width: Float, height: Float, near: Float, far: Float) -> float4x4 {
        let z = 1 / (near - far)
        return float4x4(columns: (SIMD4(2 / width, 0, 0, 0), SIMD4(0, 2 / height, 0, 0), SIMD4(0, 0, z, 0), SIMD4(0, 0, z * near, 1)))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }
}

struct Camera {
    var target = SIMD3<Float>(50, 50, 0)
    var yaw: Float = -0.6
    var pitch: Float = 0.6
    var distance: Float = 250
    var ortho = false
    var fovY: Float = 0.6

    var eye: SIMD3<Float> {
        target + distance * SIMD3(sin(yaw) * cos(pitch), -cos(yaw) * cos(pitch), sin(pitch))
    }

    func view() -> float4x4 {
        let up: SIMD3<Float> = abs(pitch) > 1.5699 ? SIMD3(-sin(yaw), cos(yaw), 0) : SIMD3(0, 0, 1)
        return .lookAt(eye: eye, target: target, up: up)
    }

    func projection(aspect: Float) -> float4x4 {
        if ortho {
            let h = 2 * distance * tan(fovY / 2)
            return .orthographic(width: h * aspect, height: h, near: -distance * 50, far: distance * 50)
        }
        return .perspective(fovY: fovY, aspect: aspect, near: max(0.1, distance * 0.01), far: distance * 50)
    }

    /// World-space ray through a point given in normalised device coordinates.
    func ray(ndc: SIMD2<Float>, aspect: Float) -> (origin: SIMD3<Float>, dir: SIMD3<Float>) {
        let inv = (projection(aspect: aspect) * view()).inverse
        var a = inv * SIMD4(ndc.x, ndc.y, 0, 1)
        var b = inv * SIMD4(ndc.x, ndc.y, 1, 1)
        a /= a.w; b /= b.w
        let o = SIMD3(a.x, a.y, a.z)
        return (o, simd_normalize(SIMD3(b.x, b.y, b.z) - o))
    }

    mutating func frame(_ bb: AABB3, aspect: Float = 1.5) {
        let c = bb.center, s = bb.size
        target = SIMD3(Float(c.x), Float(c.y), Float(c.z))
        let r = Float(max(10, simd_length(s) * 0.5))
        distance = r / tan(fovY / 2) * 1.15
    }
}

// MARK: Vertex formats (must match the MSL structs)

struct MeshVertex {
    var pos: SIMD3<Float>
    var nrm: SIMD3<Float>
    var color: SIMD4<Float>
}

struct LineVertex {
    var pos: SIMD3<Float>
    var color: SIMD4<Float>
}

struct Uniforms {
    var viewProj: float4x4
    var lightDir: SIMD4<Float>
    var eye: SIMD4<Float>
    var grid: SIMD4<Float>  // heightfield: originX, originY, res, stockTop
    var gridSize: SIMD4<UInt32>  // W, H
    var shade: SIMD4<Float>  // depth tint: model top Z, depth range, enabled
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var camera = Camera()
    var dark = true

    private var meshPipe: MTLRenderPipelineState!
    private var meshBlendPipe: MTLRenderPipelineState!
    private var linePipe: MTLRenderPipelineState!
    private var lineBlendPipe: MTLRenderPipelineState!
    private var heightPipe: MTLRenderPipelineState!
    private var bgPipe: MTLRenderPipelineState!
    private var depthOn: MTLDepthStencilState!
    private var depthReadOnly: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!

    // Scene buffers
    private var modelBuf: MTLBuffer?, modelCount = 0
    private var highlightBuf: MTLBuffer?, highlightCount = 0
    private var edgeBuf: MTLBuffer?, edgeCount = 0
    private var shade = SIMD4<Float>(0, 1, 0, 0)
    private var stockFaceBuf: MTLBuffer?, stockFaceCount = 0
    private var staticLineBuf: MTLBuffer?, staticLineCount = 0  // grid, stock edges, axes
    private var regionFaceBuf: MTLBuffer?, regionFaceCount = 0
    private var regionLineBuf: MTLBuffer?, regionLineCount = 0
    private var pathBuf: MTLBuffer?, pathCount = 0
    var pathDrawLimit: Int? = nil  // number of vertices to draw (simulation playback)
    private var pathSegmentToVertex: [Int] = []
    private var overlayLineBuf: MTLBuffer?, overlayLineCount = 0  // rubber band, tool marker
    private var dowelLineBuf: MTLBuffer?, dowelLineCount = 0  // dowel holes: green = usable, red = not
    private var heightTex: MTLTexture?, devTex: MTLTexture?
    /// Underside of the simulated stock after side-B cuts (nil for one-sided jobs).
    private var bottomTex: MTLTexture?, bottomDevTex: MTLTexture?
    private var heightGrid = SIMD4<Float>(0, 0, 1, 0)
    private var heightSize = SIMD4<UInt32>(0, 0, 0, 0)
    var showModel = true, showStock = true, showPaths = true, showSim = false

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        super.init()
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColorMake(0.1, 0.1, 0.12, 1)
        do { try buildPipelines(view) } catch { NSLog("Swarf: pipeline error \(error)"); return nil }
    }

    private func buildPipelines(_ view: MTKView) throws {
        let lib = try device.makeLibrary(source: Shaders.source, options: nil)
        func pipe(_ v: String, _ f: String, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        meshPipe = try pipe("mesh_vs", "mesh_fs", blend: false)
        meshBlendPipe = try pipe("mesh_vs", "mesh_fs", blend: true)
        linePipe = try pipe("line_vs", "line_fs", blend: false)
        lineBlendPipe = try pipe("line_vs", "line_fs", blend: true)
        heightPipe = try pipe("height_vs", "mesh_fs", blend: false)
        bgPipe = try pipe("bg_vs", "bg_fs", blend: false)
        func ds(_ write: Bool, _ cmp: MTLCompareFunction) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.isDepthWriteEnabled = write
            d.depthCompareFunction = cmp
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthOn = ds(true, .lessEqual)
        depthReadOnly = ds(false, .lessEqual)
        depthOff = ds(false, .always)
    }

    private func buffer<T>(_ a: [T]) -> MTLBuffer? {
        guard !a.isEmpty else { return nil }
        return a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    // MARK: Scene updates

    func setModel(_ placed: PlacedModel?, undercuts: Bool) {
        guard let p = placed else { modelBuf = nil; modelCount = 0; edgeBuf = nil; edgeCount = 0; shade.z = 0; return }
        var v: [MeshVertex] = []
        v.reserveCapacity(p.mesh.triangles.count * 3)
        let base = SIMD4<Float>(0.62, 0.68, 0.78, 1)
        let under = SIMD4<Float>(0.95, 0.55, 0.2, 1)
        for t in p.mesh.triangles {
            let n = t.normal
            let c = undercuts && n.z < -0.02 ? under : base
            v.append(MeshVertex(pos: t.a, nrm: n, color: c))
            v.append(MeshVertex(pos: t.b, nrm: n, color: c))
            v.append(MeshVertex(pos: t.c, nrm: n, color: c))
        }
        modelBuf = buffer(v); modelCount = v.count
        // Outline sharp edges so pockets and steps read clearly even from straight above.
        let bb = p.modelBounds
        let diag = Float(simd_length(bb.max - bb.min))
        let lift = max(0.02, diag * 2e-4)
        let ec = dark ? SIMD4<Float>(0.05, 0.06, 0.09, 0.85) : SIMD4<Float>(0.1, 0.12, 0.18, 0.75)
        var l: [LineVertex] = []
        for e in p.mesh.featureEdges() {
            l.append(LineVertex(pos: e.a + e.n * lift, color: ec)); l.append(LineVertex(pos: e.b + e.n * lift, color: ec))
        }
        edgeBuf = buffer(l); edgeCount = l.count
        // Tint the surface darker the further it sits below the model top.
        let h = Float(bb.max.z - bb.min.z)
        shade = SIMD4(Float(bb.max.z), max(3, min(25, h * 0.6)), 1, 0)
    }

    func setHighlight(_ placed: PlacedModel?, triangles: [Int]) {
        guard let p = placed, !triangles.isEmpty else { highlightBuf = nil; highlightCount = 0; return }
        var v: [MeshVertex] = []
        let c = SIMD4<Float>(0.2, 0.75, 1.0, 1)
        for i in triangles where i < p.mesh.triangles.count {
            let t = p.mesh.triangles[i]
            let n = t.normal
            let off = n * 0.02
            v.append(MeshVertex(pos: t.a + off, nrm: n, color: c))
            v.append(MeshVertex(pos: t.b + off, nrm: n, color: c))
            v.append(MeshVertex(pos: t.c + off, nrm: n, color: c))
        }
        highlightBuf = buffer(v); highlightCount = v.count
    }

    func setStock(size s: V3?, origin: V3?) {
        guard let s else { stockFaceBuf = nil; staticLineBuf = nil; return }
        let x = Float(s.x), y = Float(s.y), z = Float(s.z)
        let c = [SIMD3<Float>(0, 0, 0), SIMD3(x, 0, 0), SIMD3(x, y, 0), SIMD3(0, y, 0),
                 SIMD3(0, 0, z), SIMD3(x, 0, z), SIMD3(x, y, z), SIMD3(0, y, z)]
        stockFaceBuf = buffer(Self.boxFaces(c, color: SIMD4(0.85, 0.7, 0.45, 0.10)))
        stockFaceCount = 36
        var l: [LineVertex] = []
        let edge = SIMD4<Float>(0.85, 0.7, 0.45, 0.9)
        for (a, b) in [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)] {
            l.append(LineVertex(pos: c[a], color: edge)); l.append(LineVertex(pos: c[b], color: edge))
        }
        // Bed grid (10 mm) around the stock
        let gc = dark ? SIMD4<Float>(1, 1, 1, 0.07) : SIMD4<Float>(0, 0, 0, 0.08)
        let pad: Float = 30
        var gx = (-pad / 10).rounded(.down) * 10
        while gx <= x + pad { l.append(LineVertex(pos: SIMD3(gx, -pad, -0.01), color: gc)); l.append(LineVertex(pos: SIMD3(gx, y + pad, -0.01), color: gc)); gx += 10 }
        var gy = (-pad / 10).rounded(.down) * 10
        while gy <= y + pad { l.append(LineVertex(pos: SIMD3(-pad, gy, -0.01), color: gc)); l.append(LineVertex(pos: SIMD3(x + pad, gy, -0.01), color: gc)); gy += 10 }
        // Work origin triad
        if let o = origin {
            let p = SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z))
            let L = max(8, min(x, y) * 0.15)
            for (d, col) in [(SIMD3<Float>(1, 0, 0), SIMD4<Float>(1, 0.25, 0.25, 1)), (SIMD3(0, 1, 0), SIMD4(0.3, 1, 0.3, 1)), (SIMD3(0, 0, 1), SIMD4(0.35, 0.55, 1, 1))] {
                l.append(LineVertex(pos: p, color: col)); l.append(LineVertex(pos: p + d * L, color: col))
            }
        }
        staticLineBuf = buffer(l); staticLineCount = l.count
    }

    func setRegions(_ regions: [Region], stockTop: Double, selected: UUID?) {
        var f: [MeshVertex] = [], l: [LineVertex] = []
        for r in regions where r.enabled {
            let keep = r.kind == .keepOut
            let top = Float(keep ? (r.protectBelowZ ?? stockTop + 2) : stockTop + 2)
            let base: Float = keep && r.protectBelowZ != nil ? 0 : -0.5
            let col: SIMD4<Float> = keep ? (r.id == selected ? SIMD4(1, 0.6, 0.25, 0.35) : SIMD4(1, 0.25, 0.3, 0.2)) : SIMD4(0.3, 1, 0.5, 0.12)
            let a = SIMD2<Float>(Float(r.min.x), Float(r.min.y)), b = SIMD2<Float>(Float(r.max.x), Float(r.max.y))
            let c = [SIMD3(a.x, a.y, base), SIMD3(b.x, a.y, base), SIMD3(b.x, b.y, base), SIMD3(a.x, b.y, base),
                     SIMD3(a.x, a.y, top), SIMD3(b.x, a.y, top), SIMD3(b.x, b.y, top), SIMD3(a.x, b.y, top)]
            f += Self.boxFaces(c, color: col)
            var ec = col
            ec.w = 1
            if r.id == selected { ec = SIMD4(1, 0.85, 0.3, 1) }
            for (i, j) in [(4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7), (0, 1), (1, 2), (2, 3), (3, 0)] {
                l.append(LineVertex(pos: c[i], color: ec)); l.append(LineVertex(pos: c[j], color: ec))
            }
        }
        regionFaceBuf = buffer(f); regionFaceCount = f.count
        regionLineBuf = buffer(l); regionLineCount = l.count
    }

    static let palette: [SIMD4<Float>] = [
        SIMD4(0.2, 0.85, 1, 1), SIMD4(1, 0.8, 0.2, 1), SIMD4(0.45, 1, 0.45, 1), SIMD4(1, 0.45, 0.85, 1),
        SIMD4(1, 0.6, 0.25, 1), SIMD4(0.65, 0.55, 1, 1),
    ]

    func setToolpaths(_ tps: [Toolpath], selected: UUID?, showRapids: Bool) {
        var v: [LineVertex] = []
        pathSegmentToVertex = [0]
        for (k, tp) in tps.enumerated() {
            var col = Self.palette[k % Self.palette.count]
            let dim = selected != nil && selected != tp.id
            if dim { col = SIMD4(col.x, col.y, col.z, 0.18) }
            let rapid = SIMD4<Float>(1, 0.3, 0.3, dim ? 0.08 : 0.45)
            let plunge = SIMD4<Float>(1, 0.55, 0.1, dim ? 0.18 : 1)
            let pts = tp.tessellated(maxSegment: 1)
            for i in 1..<max(1, pts.count) {
                let (p, kind) = pts[i]
                let a = pts[i - 1].0
                defer { pathSegmentToVertex.append(v.count) }
                if kind == .rapid && !showRapids { continue }
                let c: SIMD4<Float> = kind == .rapid ? rapid : (kind == .plunge || p.z < a.z - 1e-6 ? plunge : col)
                v.append(LineVertex(pos: SIMD3(Float(a.x), Float(a.y), Float(a.z)), color: c))
                v.append(LineVertex(pos: SIMD3(Float(p.x), Float(p.y), Float(p.z)), color: c))
            }
        }
        pathBuf = buffer(v); pathCount = v.count
    }

    /// Limit drawn toolpath to the first `segments` simulation segments (nil = all).
    func setPathLimit(segments: Int?) {
        guard let s = segments else { pathDrawLimit = nil; return }
        pathDrawLimit = pathSegmentToVertex[min(max(0, s), pathSegmentToVertex.count - 1)]
    }

    func setDowels(_ holes: [(V2, Bool)], radius: Double, stockTop: Double) {
        var l: [LineVertex] = []
        let n = 32
        for (p, ok) in holes {
            let c: SIMD4<Float> = ok ? SIMD4(0.3, 1, 0.45, 1) : SIMD4(1, 0.25, 0.25, 1)
            let ctr = SIMD3<Float>(Float(p.x), Float(p.y), Float(stockTop) + 0.1)
            for r in [Float(radius), Float(radius) + 2] {
                for i in 0..<n {
                    let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                    l.append(LineVertex(pos: ctr + SIMD3(r * cos(a0), r * sin(a0), 0), color: c))
                    l.append(LineVertex(pos: ctr + SIMD3(r * cos(a1), r * sin(a1), 0), color: c))
                }
            }
            let k = Float(radius) + 4
            l.append(LineVertex(pos: ctr + SIMD3(-k, 0, 0), color: c)); l.append(LineVertex(pos: ctr + SIMD3(k, 0, 0), color: c))
            l.append(LineVertex(pos: ctr + SIMD3(0, -k, 0), color: c)); l.append(LineVertex(pos: ctr + SIMD3(0, k, 0), color: c))
            l.append(LineVertex(pos: ctr, color: c)); l.append(LineVertex(pos: SIMD3(ctr.x, ctr.y, 0), color: c))
        }
        dowelLineBuf = l.isEmpty ? nil : buffer(l); dowelLineCount = l.count
    }

    func setOverlay(rect: (V2, V2)?, z: Double, tool: (V3, Tool)?) {
        var l: [LineVertex] = []
        if let (a, b) = rect {
            let c = SIMD4<Float>(1, 0.35, 0.35, 1)
            let zf = Float(z) + 0.05
            let p = [SIMD3<Float>(Float(a.x), Float(a.y), zf), SIMD3(Float(b.x), Float(a.y), zf), SIMD3(Float(b.x), Float(b.y), zf), SIMD3(Float(a.x), Float(b.y), zf)]
            for i in 0..<4 { l.append(LineVertex(pos: p[i], color: c)); l.append(LineVertex(pos: p[(i + 1) % 4], color: c)) }
        }
        if let (p, t) = tool {
            let c = SIMD4<Float>(0.95, 0.95, 1, 1)
            let r = Float(t.radius), base = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
            let h = Float(max(t.fluteLength, 10))
            let n = 24
            for i in 0..<n {
                let a0 = Float(i) / Float(n) * 2 * .pi, a1 = Float(i + 1) / Float(n) * 2 * .pi
                for z in [Float(t.kind == .ball ? r : 0), h] {
                    l.append(LineVertex(pos: base + SIMD3(r * cos(a0), r * sin(a0), z), color: c))
                    l.append(LineVertex(pos: base + SIMD3(r * cos(a1), r * sin(a1), z), color: c))
                }
                if i % 6 == 0 {
                    l.append(LineVertex(pos: base + SIMD3(r * cos(a0), r * sin(a0), t.kind == .ball ? r : 0), color: c))
                    l.append(LineVertex(pos: base + SIMD3(r * cos(a0), r * sin(a0), h), color: c))
                }
            }
        }
        overlayLineBuf = buffer(l); overlayLineCount = l.count
    }

    func setSimulation(_ stock: Grid2D?, bottom: Grid2D? = nil, analysis: StockSimulator.Analysis?, stockTop: Double) {
        guard let g = stock else { heightTex = nil; devTex = nil; bottomTex = nil; bottomDevTex = nil; return }
        let W = g.width, H = g.height
        func texture(_ t: inout MTLTexture?) {
            if t == nil || t!.width != W || t!.height != H {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: W, height: H, mipmapped: false)
                d.usage = .shaderRead
                t = device.makeTexture(descriptor: d)
            }
        }
        func upload(_ data: [Float], _ t: MTLTexture) {
            var v = data
            if v.count != W * H { v = [Float](repeating: .nan, count: W * H) }
            v.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: W * 4) }
        }
        texture(&heightTex); texture(&devTex)
        upload(g.data, heightTex!)
        upload(analysis?.deviation ?? [], devTex!)
        if let b = bottom, b.width == W, b.height == H {
            texture(&bottomTex); texture(&bottomDevTex)
            // Where the stock is cut right through, keep the underside from showing above the top.
            upload(zip(b.data, g.data).map { min($0, $1 - 0.02) }, bottomTex!)
            upload(analysis?.undersideDeviation ?? [], bottomDevTex!)
        } else {
            bottomTex = nil; bottomDevTex = nil
        }
        heightGrid = SIMD4(Float(g.origin.x), Float(g.origin.y), Float(g.res), Float(stockTop))
        heightSize = SIMD4(UInt32(W), UInt32(H), analysis == nil ? 0 : 1, 0)
    }

    static func boxFaces(_ c: [SIMD3<Float>], color: SIMD4<Float>) -> [MeshVertex] {
        let faces: [(Int, Int, Int, Int, SIMD3<Float>)] = [
            (0, 3, 2, 1, SIMD3(0, 0, -1)), (4, 5, 6, 7, SIMD3(0, 0, 1)), (0, 1, 5, 4, SIMD3(0, -1, 0)),
            (1, 2, 6, 5, SIMD3(1, 0, 0)), (2, 3, 7, 6, SIMD3(0, 1, 0)), (3, 0, 4, 7, SIMD3(-1, 0, 0)),
        ]
        var v: [MeshVertex] = []
        for (a, b, cc, d, n) in faces {
            for i in [a, b, cc, a, cc, d] { v.append(MeshVertex(pos: c[i], nrm: n, color: color)) }
        }
        return v
    }

    // MARK: Draw

    var drawableSize = CGSize(width: 1, height: 1)
    var aspect: Float { Float(drawableSize.width / max(1, drawableSize.height)) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { drawableSize = size }

    func draw(in view: MTKView) {
        drawableSize = view.drawableSize
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let eye = camera.eye
        // Light from the viewer's side of the stock, so the underside is lit when looking up at it (side B).
        let below: Float = eye.z < camera.target.z ? -1 : 1
        let light = simd_normalize(SIMD3<Float>(0.3, -0.5 * below, below) + simd_normalize(eye - camera.target) * 0.6)
        var u = Uniforms(viewProj: camera.projection(aspect: aspect) * camera.view(), lightDir: SIMD4(light, 0),
                         eye: SIMD4(eye, dark ? 1 : 0), grid: heightGrid, gridSize: heightSize, shade: shade)
        // Background gradient
        enc.setRenderPipelineState(bgPipe)
        enc.setDepthStencilState(depthOff)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setDepthStencilState(depthOn)
        // Opaque: model or simulated stock
        if showSim, let ht = heightTex, ht.width > 1, ht.height > 1 {
            enc.setRenderPipelineState(heightPipe)
            enc.setVertexTexture(ht, index: 0)
            enc.setVertexTexture(devTex, index: 1)
            // Six vertices per grid cell; the vertex shader picks each cell's triangulation.
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6 * (ht.width - 1) * (ht.height - 1))
            if let bt = bottomTex, bt.width == ht.width, bt.height == ht.height {
                enc.setVertexTexture(bt, index: 0)
                enc.setVertexTexture(bottomDevTex, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6 * (bt.width - 1) * (bt.height - 1))
            }
        } else if showModel, let mb = modelBuf {
            enc.setRenderPipelineState(meshPipe)
            enc.setVertexBuffer(mb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: modelCount)
            if let hb = highlightBuf {
                enc.setVertexBuffer(hb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: highlightCount)
            }
        }
        // Lines (opaque-ish, blended)
        enc.setRenderPipelineState(lineBlendPipe)
        enc.setDepthStencilState(depthReadOnly)
        if let b = staticLineBuf { enc.setVertexBuffer(b, offset: 0, index: 0); enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: staticLineCount) }
        if showModel && !showSim, let b = edgeBuf { enc.setVertexBuffer(b, offset: 0, index: 0); enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeCount) }
        if showPaths, let b = pathBuf {
            enc.setVertexBuffer(b, offset: 0, index: 0)
            let n = min(pathCount, pathDrawLimit ?? pathCount)
            // In simulation show only a trail of recent moves so the machined stock stays visible.
            let start = showSim ? max(0, n - 6000) / 2 * 2 : 0
            if n - start > 0 { enc.drawPrimitives(type: .line, vertexStart: start, vertexCount: n - start) }
        }
        if let b = regionLineBuf { enc.setVertexBuffer(b, offset: 0, index: 0); enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: regionLineCount) }
        // Transparent faces
        enc.setRenderPipelineState(meshBlendPipe)
        if showStock && !showSim, let b = stockFaceBuf {
            // Push the translucent stock faces back so they never fight with model faces lying in the same plane.
            enc.setDepthBias(200, slopeScale: 4, clamp: 0.01)
            enc.setVertexBuffer(b, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stockFaceCount)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if let b = regionFaceBuf { enc.setVertexBuffer(b, offset: 0, index: 0); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: regionFaceCount) }
        // Overlay (always on top)
        if let b = overlayLineBuf {
            enc.setRenderPipelineState(lineBlendPipe)
            enc.setDepthStencilState(depthOff)
            enc.setVertexBuffer(b, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: overlayLineCount)
        }
        if let b = dowelLineBuf, dowelLineCount > 0 {
            enc.setRenderPipelineState(lineBlendPipe)
            enc.setDepthStencilState(depthOff)
            enc.setVertexBuffer(b, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: dowelLineCount)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4x4 viewProj; float4 lightDir; float4 eye; float4 grid; uint4 gridSize; float4 shade; };
    struct MeshV { float3 pos; float3 nrm; float4 color; };
    struct LineV { float3 pos; float4 color; };
    struct VOut { float4 pos [[position]]; float3 nrm; float3 world; float4 color; };

    vertex VOut mesh_vs(const device MeshV* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]], uint vid [[vertex_id]]) {
        VOut o; MeshV m = v[vid];
        o.pos = u.viewProj * float4(m.pos, 1); o.nrm = m.nrm; o.world = m.pos; o.color = m.color; return o;
    }

    fragment float4 mesh_fs(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]], bool front [[front_facing]]) {
        float3 n = normalize(in.nrm);
        float3 v = normalize(u.eye.xyz - in.world);
        if (dot(n, v) < 0) n = -n;
        float3 l = normalize(u.lightDir.xyz);
        float diff = max(dot(n, l), 0.0);
        float hemi = 0.5 + 0.5 * n.z * (l.z >= 0 ? 1.0 : -1.0);
        float3 h = normalize(l + v);
        float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.25;
        float3 base = in.color.rgb;
        if (u.shade.z > 0.5 && in.color.a > 0.99) {
            // depth cue: deeper surfaces get darker and cooler
            float t = clamp((u.shade.x - in.world.z) / u.shade.y, 0.0, 1.0);
            base = mix(base, base * float3(0.42, 0.52, 0.72), t);
        }
        float3 c = base * (0.28 + 0.22 * hemi + 0.6 * diff) + spec;
        return float4(c, in.color.a);
    }

    vertex VOut line_vs(const device LineV* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]], uint vid [[vertex_id]]) {
        VOut o; LineV m = v[vid];
        o.pos = u.viewProj * float4(m.pos, 1); o.pos.z -= 0.0004 * o.pos.w; o.nrm = float3(0, 0, 1); o.world = m.pos; o.color = m.color; return o;
    }
    fragment float4 line_fs(VOut in [[stage_in]]) { return in.color; }

    vertex VOut height_vs(texture2d<float> ht [[texture(0)]], texture2d<float> dev [[texture(1)]],
                          constant Uniforms& u [[buffer(1)]], uint vid [[vertex_id]]) {
        uint W = u.gridSize.x, H = u.gridSize.y;
        // Cell (qx, qy) is two triangles. Split it along the diagonal whose corners are closest in height, so a wall
        // that crosses the grid at an angle is drawn as a sloping face rather than a row of saw teeth.
        uint q = vid / 6, c = vid % 6;
        uint qx = q % (W - 1), qy = q / (W - 1);
        float h00 = ht.read(uint2(qx, qy)).r, h10 = ht.read(uint2(qx + 1, qy)).r;
        float h01 = ht.read(uint2(qx, qy + 1)).r, h11 = ht.read(uint2(qx + 1, qy + 1)).r;
        // Corner codes: bit 0 = +x, bit 1 = +y. Both splits keep counter-clockwise winding.
        const uint mainDiag[6] = {0, 1, 3, 0, 3, 2};   // 00-11 diagonal
        const uint otherDiag[6] = {0, 1, 2, 1, 3, 2};  // 10-01 diagonal
        uint corner = abs(h00 - h11) <= abs(h10 - h01) ? mainDiag[c] : otherDiag[c];
        uint x = qx + (corner & 1), y = qy + (corner >> 1);
        float h = ht.read(uint2(x, y)).r;
        float hl = ht.read(uint2(max(int(x) - 1, 0), y)).r, hr = ht.read(uint2(min(x + 1, W - 1), y)).r;
        float hd = ht.read(uint2(x, max(int(y) - 1, 0))).r, hu = ht.read(uint2(x, min(y + 1, H - 1))).r;
        float res = u.grid.z;
        float3 n = normalize(float3(hl - hr, hd - hu, 2.0 * res));
        float3 p = float3(u.grid.x + float(x) * res, u.grid.y + float(y) * res, h);
        VOut o; o.pos = u.viewProj * float4(p, 1); o.nrm = n; o.world = p;
        float t = clamp(h / max(u.grid.w, 1.0), 0.0, 1.0);
        float3 wood = mix(float3(0.55, 0.42, 0.28), float3(0.86, 0.72, 0.52), t);
        if (u.gridSize.z == 1) {
            float d = dev.read(uint2(x, y)).r;
            if (!isnan(d)) {
                if (d < -0.05) wood = float3(0.95, 0.15, 0.15);
                else if (d > 0.1) wood = mix(wood, float3(0.25, 0.45, 0.95), clamp(d / 1.0, 0.25, 0.85));
                else wood = mix(wood, float3(0.35, 0.8, 0.4), 0.35);
            }
        }
        o.color = float4(wood, 1);
        return o;
    }

    struct BgOut { float4 pos [[position]]; float2 uv; };
    vertex BgOut bg_vs(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        BgOut o; o.pos = float4(p * 2 - 1, 0.9999, 1); o.uv = p; return o;
    }
    fragment float4 bg_fs(BgOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
        float t = clamp(in.uv.y, 0.0, 1.0);
        float3 top = u.eye.w > 0.5 ? float3(0.16, 0.17, 0.2) : float3(0.93, 0.94, 0.96);
        float3 bot = u.eye.w > 0.5 ? float3(0.07, 0.07, 0.09) : float3(0.78, 0.8, 0.84);
        return float4(mix(bot, top, t), 1);
    }
    """
}
