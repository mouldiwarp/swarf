import Foundation

public enum JobTemplates {
    /// Characterise a placed model to choose sensible strategies.
    public struct ModelTraits: Sendable {
        public var hasCurvedTop: Bool
        public var hasCavities: Bool
        public var topBelowStock: Bool
        public var touchesBottom: Bool
    }

    public static func traits(_ ctx: CAMContext) -> ModelTraits {
        let m = ctx.placed
        var curved = 0.0, total = 0.0
        for t in m.mesh.triangles where t.normal.z > 0.05 {
            let a = Double(t.area)
            total += a
            if t.normal.z < 0.999 { curved += a }
        }
        let top = m.modelBounds.max.z
        let flats = ctx.flatLevels.filter { $0 < top - 0.05 && $0 > m.modelBounds.min.z + 0.05 }
        return ModelTraits(hasCurvedTop: total > 0 && curved / total > 0.05, hasCavities: !flats.isEmpty,
                           topBelowStock: m.stockTop - top > 0.05, touchesBottom: m.modelBounds.min.z < 0.01)
    }

    /// "Full processing": facing → roughing → finishing → cutout with tabs. On a two-sided job: dowel holes, then
    /// side A as above, then side B's pockets or 3D carving chosen from the underside.
    public static func fullProcessing(_ ctx: CAMContext, library: ToolLibrary, material: Material) -> [Operation] {
        let side = singleSide(ctx, library: library, material: material)
        guard ctx.job.activeFlip != nil else { return side }
        let flat6 = library.closest(kind: .flat, diameter: 6) ?? ToolLibrary.starter.tools[0]
        var dowels = Operation(kind: .dowelHoles, tool: flat6, material: material)
        dowels.name = "Dowel holes"
        let b = ctx.makeSideB()
        var back = singleSide(b, library: library, material: material).filter { $0.kind.allowedOnSideB }
        for i in back.indices {
            back[i].machiningSide = .b
            back[i].name += " (side B)"
        }
        return [dowels] + side + back
    }

    static func singleSide(_ ctx: CAMContext, library: ToolLibrary, material: Material) -> [Operation] {
        let t = traits(ctx)
        var ops: [Operation] = []
        let flat6 = library.closest(kind: .flat, diameter: 6) ?? ToolLibrary.starter.tools[0]
        let ball = library.closest(kind: .ball, diameter: 6) ?? flat6
        if t.topBelowStock {
            var f = Operation(kind: .facing, tool: flat6, material: material)
            f.facingDepth = min(ctx.stockTop - ctx.placed.modelBounds.max.z, 2)
            f.name = "Face stock"
            ops.append(f)
        }
        if t.hasCurvedTop {
            var r = Operation(kind: .roughing, tool: flat6, material: material)
            r.name = "Rough"
            ops.append(r)
            var p = Operation(kind: .parallelFinish, tool: ball, material: material)
            p.name = "Finish (parallel)"
            p.rasterAngle = 45
            p.slopeLimit = 50
            ops.append(p)
            var w = Operation(kind: .waterlineFinish, tool: ball, material: material)
            w.name = "Finish (steep walls)"
            w.slopeLimit = 50
            w.cutting.stepdown = 0.3
            ops.append(w)
        } else if t.hasCavities || t.topBelowStock {
            var p = Operation(kind: .pocket, tool: flat6, material: material)
            p.name = "Pockets"
            ops.append(p)
        }
        var c = Operation(kind: .cutout, tool: flat6, material: material)
        c.name = "Cutout"
        c.tabs.enabled = true
        ops.append(c)
        return ops
    }
}

public struct GenerationOutput: Sendable {
    public var toolpaths: [Toolpath]
    public var errors: [UUID: String]
}

extension CAMContext {
    public func generateAll(progress: (@Sendable (Int, Double) -> Void)? = nil) async -> GenerationOutput {
        var tps: [Toolpath] = []
        var errs: [UUID: String] = [:]
        for (i, op) in job.operations.enumerated() where op.enabled {
            if Task.isCancelled { break }
            do {
                let tp = try generate(op) { p in progress?(i, p) }
                tps.append(tp)
            } catch is CancellationError {
                break
            } catch {
                errs[op.id] = error.localizedDescription
            }
        }
        return GenerationOutput(toolpaths: tps, errors: errs)
    }
}
