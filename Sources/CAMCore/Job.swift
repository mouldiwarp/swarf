import Foundation

public enum OperationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case facing, pocket, roughing, parallelFinish, waterlineFinish, vcarve, drill, cutout
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .facing: return "Facing"
        case .pocket: return "Pocket / Cavity"
        case .roughing: return "3D Roughing"
        case .parallelFinish: return "3D Finish – Parallel"
        case .waterlineFinish: return "3D Finish – Waterline"
        case .vcarve: return "V-Carve"
        case .drill: return "Drill (Peck)"
        case .cutout: return "Cutout (Profile)"
        }
    }

    public var symbol: String {
        switch self {
        case .facing: return "square.3.layers.3d.top.filled"
        case .pocket: return "square.dashed.inset.filled"
        case .roughing: return "mountain.2"
        case .parallelFinish: return "line.3.horizontal"
        case .waterlineFinish: return "water.waves"
        case .vcarve: return "textformat"
        case .drill: return "smallcircle.filled.circle"
        case .cutout: return "scissors"
        }
    }
}

public enum CutDirection: String, Codable, Sendable, CaseIterable { case climb, conventional }

public enum BoundaryMode: String, Codable, Sendable, CaseIterable {
    case stock, silhouette, insideSilhouette
    public var displayName: String {
        switch self {
        case .stock: return "Whole stock"
        case .silhouette: return "Model silhouette + margin"
        case .insideSilhouette: return "Inside model only"
        }
    }
}

public enum TabShape: String, Codable, Sendable, CaseIterable { case rectangular, triangular }

/// Cutout roughing + finishing: roughing passes stay `allowance` mm off the part, then a finishing pass
/// takes the last skin at a larger depth of cut.
public struct CutoutFinish: Codable, Sendable, Equatable, Hashable {
    public var enabled = true
    /// Radial stock left by the roughing passes (mm).
    public var allowance = 0.5
    /// Finishing depth of cut (mm). nil = 4× the roughing stepdown.
    public var stepdown: Double? = nil
    public init() {}
}

public struct TabSettings: Codable, Sendable, Equatable, Hashable {
    public var enabled = true
    public var countPerLoop = 4
    public var width = 8.0
    public var height = 3.0
    public var shape: TabShape = .triangular
    /// Optional explicit tab centres in stock XY; the nearest point on each loop is used.
    public var manualPositions: [V2] = []
    /// Loops shorter than this get no tabs (e.g. small hole slugs).
    public var minLoopLength = 40.0
    public init() {}
}

public struct Operation: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var kind: OperationKind
    public var enabled = true
    public var tool: Tool
    public var cutting: CuttingData
    public var stockToLeaveXY = 0.0
    public var stockToLeaveZ = 0.0
    public var direction: CutDirection = .climb
    public var boundary: BoundaryMode = .silhouette
    public var boundaryMargin = 3.0
    /// Explicit lowest Z (stock space). nil = automatic.
    public var floorZ: Double? = nil
    /// When the model touches the stock bottom, automatic floors stop this far above it.
    public var bottomSkin = 1.0
    // Facing
    public var facingDepth = 1.0
    // Finishing
    public var rasterAngle = 0.0
    /// For combined steep/shallow strategies (degrees). 0 = machine everything.
    public var slopeLimit = 0.0
    public var zigzag = true
    // Cutout
    public var throughDepth = 0.3
    public var cutHoles = true
    public var tabs = TabSettings()
    public var cutoutFinish: CutoutFinish? = nil
    public var cutoutFinishSettings: CutoutFinish {
        get { cutoutFinish ?? CutoutFinish() }
        set { cutoutFinish = newValue }
    }
    /// Finishing depth of cut for cutouts: explicit, or 4× the roughing stepdown.
    public var finishStepdown: Double {
        get { max(0.05, cutoutFinishSettings.stepdown ?? cutting.stepdown * 4) }
        set { cutoutFinishSettings.stepdown = newValue }
    }
    // V-carve (optional so projects saved before V-carving existed still decode)
    public var vcarve: VCarveSettings? = nil
    public var vcarveSettings: VCarveSettings {
        get { vcarve ?? VCarveSettings() }
        set { vcarve = newValue }
    }
    // Drilling (optional for older projects)
    public var drilling: DrillSettings? = nil
    public var drillSettings: DrillSettings {
        get { drilling ?? DrillSettings() }
        set { drilling = newValue }
    }
    /// nil = every enabled region applies.
    public var regionIDs: [UUID]? = nil

    public init(kind: OperationKind, tool: Tool, material: Material = .named("mdf")) {
        self.kind = kind
        self.name = kind.displayName
        self.tool = tool
        self.cutting = material.apply(tool.defaults)
        switch kind {
        case .facing:
            cutting.stepoverPercent = 70
            boundary = .stock
        case .roughing:
            stockToLeaveXY = 0.5; stockToLeaveZ = 0.3
            boundary = .silhouette; boundaryMargin = tool.radius
        case .pocket:
            boundary = .insideSilhouette
        case .parallelFinish:
            cutting.stepoverPercent = tool.kind == .ball ? 10 : 25
            boundary = .silhouette; boundaryMargin = tool.radius
        case .waterlineFinish:
            cutting.stepdown = min(cutting.stepdown, 0.5)
            boundary = .silhouette; boundaryMargin = tool.radius
        case .vcarve:
            cutting.stepoverPercent = 5
            boundary = .stock
            vcarve = VCarveSettings()
        case .drill:
            boundary = .stock
            drilling = DrillSettings()
            // Peck depth: about half the diameter clears chips well in wood with an end mill or drill.
            cutting.stepdown = max(0.5, min(cutting.stepdown, tool.diameter * 0.5))
        case .cutout:
            boundary = .stock
        }
    }

    public var stepover: Double { max(0.01, tool.diameter * cutting.stepoverPercent / 100) }
}

public struct Region: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case keepOut, machineOnly
        public var displayName: String { self == .keepOut ? "Keep-out" : "Machine only within" }
    }
    public var id = UUID()
    public var name: String
    public var kind: Kind = .keepOut
    public var enabled = true
    public var min: V2
    public var max: V2
    /// Keep-out only: the tool tip may not go below this Z (stock space) inside the region. nil = never enter.
    public var protectBelowZ: Double? = nil

    public init(name: String, kind: Kind = .keepOut, min: V2, max: V2) {
        self.name = name; self.kind = kind
        self.min = simd_min(min, max); self.max = simd_max(min, max)
    }

    public func contains(_ p: V2, inflate r: Double = 0) -> Bool {
        p.x >= min.x - r && p.x <= max.x + r && p.y >= min.y - r && p.y <= max.y + r
    }

    /// Euclidean distance from p to the rectangle (0 inside).
    public func distance(to p: V2) -> Double {
        let dx = Swift.max(min.x - p.x, 0, p.x - max.x)
        let dy = Swift.max(min.y - p.y, 0, p.y - max.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

import simd

public enum ResolutionQuality: String, Codable, Sendable, CaseIterable {
    case draft, normal, fine
    public var divisions: Double {
        switch self { case .draft: return 700; case .normal: return 1400; case .fine: return 2600 }
    }
}

public struct Job: Codable, Sendable, Equatable {
    public var version = 1
    public var orientation = Orientation()
    public var stock = StockSetup()
    public var origin = WorkOrigin.workbeeDefault
    public var machineID = MachineProfile.workbeeRRF.id
    public var safeHeight = 5.0
    public var quality: ResolutionQuality = .normal
    public var operations: [Operation] = []
    public var regions: [Region] = []
    /// Test-cut depth limits. Optional so projects saved before it existed still open.
    public var testCut: TestCut? = nil
    public var testCutSettings: TestCut {
        get { testCut ?? TestCut() }
        set { testCut = newValue }
    }
    /// The limits in force, or nil when test-cut mode is off.
    public var activeTestCut: TestCut? { testCut?.enabled == true ? testCut : nil }

    public init() {}
}

/// Test-cut mode: try a job on thin scrap (9 mm MDF by default) with every depth capped below the stock top.
public struct TestCut: Codable, Sendable, Equatable, Hashable {
    public var enabled = false
    /// Cutouts stop this far below the stock top, leaving a skin that holds the part.
    public var cutoutDepth = 8.0
    /// Pockets, 3D roughing and finishing, and V-carving go no deeper than this.
    public var pocketDepth = 4.0
    /// Drilled and pecked holes go no deeper than this.
    public var drillDepth = 4.0
    public init() {}

    public func depth(for kind: OperationKind) -> Double? {
        switch kind {
        case .cutout: return cutoutDepth
        case .drill: return drillDepth
        case .pocket, .roughing, .parallelFinish, .waterlineFinish, .vcarve: return pocketDepth
        case .facing: return nil
        }
    }

    public var summary: String {
        String(format: "cutouts %g mm, pockets and carving %g mm, holes %g mm", cutoutDepth, pocketDepth, drillDepth)
    }
}
