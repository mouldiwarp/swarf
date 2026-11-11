import CAMCore
import MetalKit
import SwiftUI

/// MTKView subclass that turns mouse / trackpad input into camera moves and picking.
final class ViewportMTKView: MTKView {
    var renderer: Renderer!
    weak var model: ProjectModel?
    private var dragStart: NSPoint?
    private var rectStart: V2?
    private var rectEnd: V2?
    private var lastHoverTri: Int?
    private var didDrag = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func ndc(_ e: NSEvent) -> SIMD2<Float> {
        let p = convert(e.locationInWindow, from: nil)
        return SIMD2(Float(p.x / bounds.width) * 2 - 1, Float(p.y / bounds.height) * 2 - 1)
    }

    private func ray(_ e: NSEvent) -> (SIMD3<Float>, SIMD3<Float>) {
        renderer.camera.ray(ndc: ndc(e), aspect: Float(bounds.width / max(1, bounds.height)))
    }

    private func planeHit(_ e: NSEvent, z: Double) -> V2? {
        let (o, d) = ray(e)
        guard abs(d.z) > 1e-6 else { return nil }
        let t = (Float(z) - o.z) / d.z
        guard t > 0 || renderer.camera.ortho else { return nil }
        let p = o + d * t
        return V2(Double(p.x), Double(p.y))
    }

    private func pickTriangle(_ e: NSEvent) -> Int? {
        guard let placed = model?.placed else { return nil }
        let (o, d) = ray(e)
        return placed.mesh.raycast(origin: V3(Double(o.x), Double(o.y), Double(o.z)), direction: V3(Double(d.x), Double(d.y), Double(d.z)))?.index
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(e.locationInWindow, from: nil)
        didDrag = false
        guard let model else { return }
        if model.mode == .drawKeepOut, let top = model.placed?.stockTop, let p = planeHit(e, z: top) {
            rectStart = p; rectEnd = p
        }
    }

    override func mouseDragged(with e: NSEvent) {
        didDrag = true
        guard let model else { return }
        if model.mode == .drawKeepOut, rectStart != nil, let top = model.placed?.stockTop {
            if let p = planeHit(e, z: top) { rectEnd = p }
            renderer.setOverlay(rect: (rectStart!, rectEnd!), z: top, tool: nil)
            needsDisplay = true
            return
        }
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.shift) {
            pan(dx: e.deltaX, dy: e.deltaY)
        } else {
            orbit(dx: e.deltaX, dy: e.deltaY)
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { dragStart = nil }
        guard let model else { return }
        switch model.mode {
        case .drawKeepOut:
            if let a = rectStart, let b = rectEnd, abs(a.x - b.x) > 0.5, abs(a.y - b.y) > 0.5 {
                model.addRegion(min: simd_min(a, b), max: simd_max(a, b))
            }
            rectStart = nil; rectEnd = nil
            renderer.setOverlay(rect: nil, z: 0, tool: nil)
            needsDisplay = true
        case .faceUp, .faceDown:
            if !didDrag, let t = pickTriangle(e) { model.pickFace(triangle: t, up: model.mode == .faceUp) }
        case .placeTab:
            if !didDrag, let p = planeHit(e, z: (model.selectedOperation?.tabs.height ?? 0) / 2) { model.addTab(at: p) }
        case .orbit:
            break
        }
    }

    override func mouseMoved(with e: NSEvent) {
        guard let model, model.mode == .faceUp || model.mode == .faceDown, let placed = model.placed else {
            if lastHoverTri != nil { lastHoverTri = nil; self.model?.highlightTriangles = [] }
            return
        }
        let t = pickTriangle(e)
        if t != lastHoverTri {
            lastHoverTri = t
            model.highlightTriangles = t.map { placed.mesh.coplanarGroup(of: $0) } ?? []
        }
    }

    override func rightMouseDragged(with e: NSEvent) { pan(dx: e.deltaX, dy: e.deltaY) }
    override func otherMouseDragged(with e: NSEvent) { pan(dx: e.deltaX, dy: e.deltaY) }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas {
            // Trackpad: two-finger drag orbits, ⇧ or ⌥ pans, ⌘ zooms.
            if e.modifierFlags.contains(.command) {
                zoom(Float(1 - e.scrollingDeltaY * 0.01))
            } else if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) {
                pan(dx: e.scrollingDeltaX, dy: -e.scrollingDeltaY)
            } else {
                orbit(dx: -e.scrollingDeltaX * 0.6, dy: -e.scrollingDeltaY * 0.6)
            }
        } else {
            zoom(Float(1 - e.scrollingDeltaY * 0.08))
        }
    }

    override func magnify(with e: NSEvent) { zoom(Float(1 - e.magnification)) }
    override func rotate(with e: NSEvent) {
        renderer.camera.yaw -= e.rotation * .pi / 180
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { model?.mode = .orbit; return }  // Esc
        super.keyDown(with: e)
    }

    func orbit(dx: CGFloat, dy: CGFloat) {
        renderer.camera.yaw -= Float(dx) * 0.008
        renderer.camera.pitch = max(-1.5, min(1.5707, renderer.camera.pitch + Float(dy) * 0.008))
        needsDisplay = true
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        let c = renderer.camera
        let v = c.view()
        let right = SIMD3<Float>(v[0][0], v[1][0], v[2][0])
        let up = SIMD3<Float>(v[0][1], v[1][1], v[2][1])
        let scale = c.distance * 2 * tan(c.fovY / 2) / Float(max(1, bounds.height))
        renderer.camera.target += (-right * Float(dx) + up * Float(dy)) * scale
        needsDisplay = true
    }

    func zoom(_ f: Float) {
        renderer.camera.distance = max(5, min(20000, renderer.camera.distance * max(0.5, min(1.5, f))))
        needsDisplay = true
    }
}

struct ViewportView: NSViewRepresentable {
    @ObservedObject var model: ProjectModel
    @Environment(\.colorScheme) var scheme

    final class Coordinator {
        var renderer: Renderer?
        var meshVersion = -1, pathVersion = -1, simVersion = -1
        var pathKey = ""
        var regionKey = ""
        var stockKey = ""
        var highlight: [Int] = []
        var undercuts = false
        var framedOnce = false
        var lastView: ViewPreset?
        var lastLimit: Int? = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ViewportMTKView {
        let v = ViewportMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        guard let r = Renderer(view: v) else { return v }
        v.renderer = r
        v.delegate = r
        v.model = model
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.allowedTouchTypes = [.indirect]
        context.coordinator.renderer = r
        return v
    }

    func updateNSView(_ v: ViewportMTKView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        let c = context.coordinator
        v.model = model
        r.dark = scheme == .dark
        if c.meshVersion != model.meshVersion || c.undercuts != model.showUndercuts {
            c.meshVersion = model.meshVersion
            c.undercuts = model.showUndercuts
            r.setModel(model.placed, undercuts: model.showUndercuts)
            if !c.framedOnce, let p = model.placed {
                r.camera.frame(AABB3(min: .zero, max: p.stockSize))
                c.framedOnce = true
            }
        }
        let stockKey = "\(String(describing: model.placed?.stockSize))|\(model.job.origin)|\(r.dark)"
        if stockKey != c.stockKey {
            c.stockKey = stockKey
            r.setStock(size: model.placed?.stockSize, origin: model.placed.map { $0.originPoint(model.job.origin) })
        }
        if c.highlight != model.highlightTriangles {
            c.highlight = model.highlightTriangles
            r.setHighlight(model.placed, triangles: model.highlightTriangles)
        }
        var selectedRegion: UUID? = nil
        var selectedOp: UUID? = nil
        if case .region(let id) = model.selection { selectedRegion = id }
        if case .operation(let id) = model.selection { selectedOp = id }
        let rk = "\(model.job.regions)|\(String(describing: selectedRegion))|\(model.placed?.stockTop ?? 0)"
        if rk != c.regionKey {
            c.regionKey = rk
            r.setRegions(model.job.regions, stockTop: model.placed?.stockTop ?? 0, selected: selectedRegion)
        }
        let pk = "\(model.toolpathVersion)|\(String(describing: selectedOp))|\(model.showRapids)"
        if pk != c.pathKey {
            c.pathKey = pk
            r.setToolpaths(model.toolpaths, selected: model.simMode ? nil : selectedOp, showRapids: model.showRapids)
            c.lastLimit = -1
        }
        if c.simVersion != model.simVersion {
            c.simVersion = model.simVersion
            r.setSimulation(model.simStock, analysis: model.simAnalysis, stockTop: model.placed?.stockTop ?? 0)
            r.setOverlay(rect: nil, z: 0, tool: model.simMode && model.simPosition < 1 ? model.simToolPosition : nil)
        }
        let limit = model.simSegmentLimit
        if limit != c.lastLimit {
            c.lastLimit = limit
            r.setPathLimit(segments: limit)
        }
        r.showModel = model.showModel
        r.showStock = model.showStock
        r.showPaths = model.showToolpaths
        r.showSim = model.simMode && model.simStock != nil
        if let vr = model.viewRequest {
            applyView(vr, r)
            DispatchQueue.main.async { model.viewRequest = nil }
        }
        if model.mode == .drawKeepOut || model.mode == .placeTab {
            if !r.camera.ortho || r.camera.pitch < 1.57 { applyView(.top, r) }
        }
        v.needsDisplay = true
    }

    func applyView(_ p: ViewPreset, _ r: Renderer) {
        if let placed = model.placed { r.camera.frame(AABB3(min: .zero, max: placed.stockSize)) }
        switch p {
        case .iso: r.camera.yaw = -0.6; r.camera.pitch = 0.6; r.camera.ortho = false
        case .top: r.camera.yaw = 0; r.camera.pitch = 1.5707; r.camera.ortho = true
        case .front: r.camera.yaw = 0; r.camera.pitch = 0.0; r.camera.ortho = true
        case .right: r.camera.yaw = .pi / 2; r.camera.pitch = 0.0; r.camera.ortho = true
        }
    }
}
