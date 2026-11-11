import Foundation

public enum ToolKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case flat, ball, bullNose, vBit, drill
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .flat: return "Flat End Mill"
        case .ball: return "Ball Nose"
        case .bullNose: return "Bull Nose"
        case .vBit: return "V-Bit"
        case .drill: return "Drill"
        }
    }
}

/// Helix / flute geometry of an end mill. It changes how chips leave the cut and which face of sheet stock is clean.
public enum FluteStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case upcut, downcut, compression, straight
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .upcut: return "Upcut"
        case .downcut: return "Downcut"
        case .compression: return "Compression"
        case .straight: return "Straight (0° helix)"
        }
    }
    public var explanation: String {
        switch self {
        case .upcut: return "Lifts chips out: best chip clearing and deepest passes. Fuzzes the top edge of sheet goods and lifts thin parts, so use enough tabs."
        case .downcut: return "Pushes chips down: clean top edge and holds parts down, but chips pack in deep slots. Keep stepdown ≤ 1× diameter and ramp in."
        case .compression: return "Upcut tip, downcut above: clean top and bottom faces. The first pass goes deeper than the upcut length so the downcut flutes cut the top edge."
        case .straight: return "Neutral: no lift or push, poor chip clearing. Use shallow passes and moderate feeds."
        }
    }
}

/// Cutting parameters. Feeds are mm/min, depths mm.
public struct CuttingData: Codable, Sendable, Equatable, Hashable {
    public var rpm: Double
    public var feed: Double
    public var plunge: Double
    public var stepdown: Double
    public var stepoverPercent: Double
    public var rampAngle: Double = 3

    public init(rpm: Double, feed: Double, plunge: Double, stepdown: Double, stepoverPercent: Double, rampAngle: Double = 3) {
        self.rpm = rpm; self.feed = feed; self.plunge = plunge
        self.stepdown = stepdown; self.stepoverPercent = stepoverPercent; self.rampAngle = rampAngle
    }
}

public struct Tool: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID = UUID()
    public var number: Int = 1
    public var name: String
    public var kind: ToolKind
    public var diameter: Double
    public var cornerRadius: Double = 0  // bull nose
    public var vAngle: Double = 90  // included angle, V-bit / drill point
    public var tipDiameter: Double = 0  // V-bit flat tip
    public var flutes: Int = 2
    public var fluteLength: Double = 20
    public var stickout: Double = 30
    public var shankDiameter: Double = 6
    public var defaults: CuttingData
    public var notes: String = ""
    // Optional storage so libraries and projects saved before these fields existed still load.
    private var flute: FluteStyle? = nil
    private var upcutLen: Double? = nil

    public var fluteStyle: FluteStyle {
        get { flute ?? .upcut }
        set { flute = newValue }
    }
    /// Compression bits: length of the upcut section at the tip (mm).
    public var upcutLength: Double {
        get { upcutLen ?? 6 }
        set { upcutLen = newValue }
    }
    /// End mills (flat, ball, bull nose) have a flute style; V-bits and drills don't.
    public var hasFluteStyle: Bool { kind == .flat || kind == .ball || kind == .bullNose }

    /// Z levels (descending) for cutting from `top` down to `bottom`. Compression bits take a first pass deeper than
    /// their upcut section so the downcut flutes shear the top face. The remaining depth is split evenly.
    public func passLevels(top: Double, bottom: Double, stepdown: Double) -> [Double] {
        let total = top - bottom
        guard total > 1e-9 else { return [bottom] }
        let sd = max(0.05, stepdown)
        var first = sd
        if hasFluteStyle && fluteStyle == .compression { first = max(sd, upcutLength + 1) }
        if first >= total - 1e-9 { return [bottom] }
        var levels = [top - first]
        let rest = total - first
        let n = max(1, Int(ceil(rest / sd - 1e-9)))
        for k in 1...n { levels.append(top - first - rest * Double(k) / Double(n)) }
        return levels
    }

    public init(number: Int = 1, name: String, kind: ToolKind, diameter: Double, cornerRadius: Double = 0,
                vAngle: Double = 90, flutes: Int = 2, fluteLength: Double = 20, stickout: Double = 30,
                shankDiameter: Double? = nil, fluteStyle: FluteStyle? = nil, upcutLength: Double? = nil,
                defaults: CuttingData) {
        self.flute = fluteStyle; self.upcutLen = upcutLength
        self.number = number; self.name = name; self.kind = kind; self.diameter = diameter
        self.cornerRadius = cornerRadius; self.vAngle = vAngle; self.flutes = flutes
        self.fluteLength = fluteLength; self.stickout = stickout
        self.shankDiameter = shankDiameter ?? diameter; self.defaults = defaults
    }

    public var radius: Double { diameter / 2 }

    public var summary: String {
        switch kind {
        case .vBit: return String(format: "%@ %.0f° V-bit", name, vAngle)
        default: return name
        }
    }

    /// Height of the cutter surface above the tip at radial distance `d` (nil when outside the cutter).
    public func profileOffset(at d: Double, extraRadius: Double = 0) -> Double? {
        let r = radius + extraRadius
        guard d <= r + 1e-9 else { return nil }
        switch kind {
        case .flat:
            return 0
        case .ball:
            return r - (max(0, r * r - d * d)).squareRoot()
        case .bullNose:
            let cr = min(cornerRadius + extraRadius, r)
            let flat = r - cr
            if d <= flat { return 0 }
            let q = d - flat
            return cr - (max(0, cr * cr - q * q)).squareRoot()
        case .vBit, .drill:
            let tip = tipDiameter / 2
            if d <= tip { return 0 }
            let half = max(1, vAngle / 2) * .pi / 180
            return (d - tip) / tan(half)
        }
    }

    /// Radius of the cut made at the stock surface when the tip is `depth` below it.
    public func cuttingRadius(depth: Double) -> Double {
        guard depth > 0 else { return 0 }
        switch kind {
        case .vBit, .drill:
            let half = max(1, vAngle / 2) * .pi / 180
            return min(radius, tipDiameter / 2 + depth * tan(half))
        case .ball:
            return depth >= radius ? radius : (max(0, depth * (2 * radius - depth))).squareRoot()
        default:
            return radius
        }
    }

    /// Chip load (mm/tooth) at the default feed.
    public var chipLoad: Double { defaults.feed / max(1, defaults.rpm) / Double(max(1, flutes)) }
}

public struct Material: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    /// Multipliers applied to a tool's default cutting data.
    public var feedFactor: Double
    public var rpmFactor: Double
    public var stepdownFactor: Double
    /// Typical chip-load window (mm/tooth) for sanity warnings, for a ~6 mm cutter.
    public var chipLoadRange: ClosedRange<Double>

    public static let library: [Material] = [
        Material(id: "mdf", name: "MDF", feedFactor: 1.0, rpmFactor: 1.0, stepdownFactor: 1.0, chipLoadRange: 0.03...0.20),
        Material(id: "plywood", name: "Plywood", feedFactor: 0.9, rpmFactor: 1.0, stepdownFactor: 0.9, chipLoadRange: 0.03...0.18),
        Material(id: "softwood", name: "Softwood (Pine)", feedFactor: 1.1, rpmFactor: 1.0, stepdownFactor: 1.0, chipLoadRange: 0.03...0.22),
        Material(id: "hardwood", name: "Hardwood (Oak/Walnut)", feedFactor: 0.8, rpmFactor: 1.0, stepdownFactor: 0.75, chipLoadRange: 0.025...0.16),
        Material(id: "acrylic", name: "Acrylic (cast)", feedFactor: 0.7, rpmFactor: 0.8, stepdownFactor: 0.6, chipLoadRange: 0.03...0.12),
        Material(id: "hdpe", name: "HDPE / Delrin", feedFactor: 1.0, rpmFactor: 0.85, stepdownFactor: 0.8, chipLoadRange: 0.04...0.20),
        Material(id: "foam", name: "Tooling Foam / Wax", feedFactor: 1.5, rpmFactor: 0.8, stepdownFactor: 2.0, chipLoadRange: 0.03...0.40),
        Material(id: "aluminium", name: "Aluminium 6061", feedFactor: 0.35, rpmFactor: 0.9, stepdownFactor: 0.2, chipLoadRange: 0.01...0.06),
    ]

    public static func named(_ id: String) -> Material { library.first { $0.id == id } ?? library[0] }

    public func apply(_ d: CuttingData) -> CuttingData {
        var o = d
        o.rpm = (d.rpm * rpmFactor).rounded()
        o.feed = (d.feed * feedFactor).rounded()
        o.plunge = (d.plunge * feedFactor).rounded()
        o.stepdown = (d.stepdown * stepdownFactor * 100).rounded() / 100
        return o
    }
}

public enum FeedsAndSpeeds {
    public struct Advice: Sendable {
        public var chipLoad: Double
        public var warnings: [String]
    }

    public static func check(tool: Tool, data: CuttingData, material: Material) -> Advice {
        let cl = data.feed / max(1, data.rpm) / Double(max(1, tool.flutes))
        // Scale the window with cutter diameter relative to 6 mm.
        let s = max(0.3, min(2, tool.diameter / 6))
        let lo = material.chipLoadRange.lowerBound * s, hi = material.chipLoadRange.upperBound * s
        var w: [String] = []
        if cl < lo { w.append(String(format: "Chip load %.3f mm is low (rubbing / heat). Increase feed or reduce RPM.", cl)) }
        if cl > hi { w.append(String(format: "Chip load %.3f mm is high (tool stress). Reduce feed or increase RPM.", cl)) }
        if data.stepdown > tool.diameter * 1.5 { w.append("Stepdown exceeds 1.5× tool diameter.") }
        if data.stepdown > tool.fluteLength { w.append("Stepdown exceeds flute length.") }
        if data.plunge > data.feed { w.append("Plunge rate is higher than cutting feed.") }
        if tool.hasFluteStyle && tool.fluteStyle == .downcut && data.stepdown > tool.diameter {
            w.append("Downcut bits pack chips into the slot. Keep stepdown at or below 1× diameter.")
        }
        if tool.hasFluteStyle && tool.fluteStyle == .straight && data.stepdown > tool.diameter * 0.5 {
            w.append("Straight-flute bits clear chips poorly. Keep stepdown at or below 0.5× diameter.")
        }
        return Advice(chipLoad: cl, warnings: w)
    }

    /// Feed for a target chip load.
    public static func feed(rpm: Double, flutes: Int, chipLoad: Double) -> Double {
        rpm * Double(flutes) * chipLoad
    }
}

public struct ToolLibrary: Codable, Sendable, Equatable {
    public var tools: [Tool]

    public init(tools: [Tool]) { self.tools = tools }

    public static let starter: ToolLibrary = {
        let wood = { (rpm: Double, feed: Double, plunge: Double, sd: Double, so: Double) in
            CuttingData(rpm: rpm, feed: feed, plunge: plunge, stepdown: sd, stepoverPercent: so)
        }
        return ToolLibrary(tools: [
            Tool(number: 1, name: "6 mm Flat Compression", kind: .flat, diameter: 6, flutes: 2, fluteLength: 50, stickout: 55,
                 fluteStyle: .compression, upcutLength: 6, defaults: wood(18000, 1500, 400, 2.0, 45)),
            Tool(number: 2, name: "3.175 mm (1/8\") Flat 2F", kind: .flat, diameter: 3.175, flutes: 2, fluteLength: 17, stickout: 25,
                 shankDiameter: 3.175, defaults: wood(18000, 1000, 300, 1.5, 40)),
            Tool(number: 3, name: "6.35 mm (1/4\") Flat 2F", kind: .flat, diameter: 6.35, flutes: 2, fluteLength: 25, stickout: 32,
                 defaults: wood(18000, 1600, 400, 2.5, 45)),
            Tool(number: 4, name: "3 mm Flat 1F (plastics)", kind: .flat, diameter: 3, flutes: 1, fluteLength: 12, stickout: 20,
                 shankDiameter: 3.175, defaults: wood(16000, 900, 250, 1.0, 40)),
            Tool(number: 5, name: "3 mm Ball Nose 2F", kind: .ball, diameter: 3, flutes: 2, fluteLength: 12, stickout: 25,
                 shankDiameter: 3.175, defaults: wood(18000, 1200, 300, 1.0, 10)),
            Tool(number: 6, name: "6 mm Ball Nose Compression", kind: .ball, diameter: 6, flutes: 2, fluteLength: 50, stickout: 55,
                 fluteStyle: .compression, upcutLength: 6, defaults: wood(18000, 1500, 400, 1.5, 12)),
            Tool(number: 7, name: "1/8\" Ball Nose 2F", kind: .ball, diameter: 3.175, flutes: 2, fluteLength: 12, stickout: 25,
                 shankDiameter: 3.175, defaults: wood(18000, 1200, 300, 1.0, 10)),
            Tool(number: 8, name: "6 mm Bull Nose R1", kind: .bullNose, diameter: 6, cornerRadius: 1, flutes: 2,
                 fluteLength: 20, stickout: 30, defaults: wood(18000, 1500, 400, 1.5, 30)),
            Tool(number: 9, name: "60° V-Bit 1/4\"", kind: .vBit, diameter: 6.35, vAngle: 60, flutes: 2, fluteLength: 8,
                 stickout: 25, defaults: wood(18000, 1000, 300, 1.0, 20)),
            Tool(number: 10, name: "90° V-Bit 1/4\"", kind: .vBit, diameter: 6.35, vAngle: 90, flutes: 2, fluteLength: 6,
                 stickout: 25, defaults: wood(18000, 1000, 300, 1.0, 20)),
        ])
    }()

    public func closest(kind: ToolKind, diameter: Double) -> Tool? {
        tools.filter { $0.kind == kind }.min { abs($0.diameter - diameter) < abs($1.diameter - diameter) }
    }

    // MARK: Fusion 360 tool library import (.json)

    public static func importFusion(_ data: Data) throws -> [Tool] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw STLError.malformed("Not a Fusion 360 tool library")
        }
        var out: [Tool] = []
        for (i, t) in list.enumerated() {
            guard let geo = t["geometry"] as? [String: Any], let dc = geo["DC"] as? Double else { continue }
            let type = (t["type"] as? String ?? "").lowercased()
            let kind: ToolKind
            if type.contains("ball") { kind = .ball }
            else if type.contains("bull") { kind = .bullNose }
            else if type.contains("chamfer") || type.contains("engrave") || type.contains("dovetail") == false && type.contains("v") && type.contains("bit") { kind = .vBit }
            else if type.contains("drill") { kind = .drill }
            else if type.contains("flat") || type.contains("end mill") { kind = .flat }
            else { continue }
            let unitScale = (t["unit"] as? String ?? "millimeters").lowercased().hasPrefix("inch") ? 25.4 : 1
            var cd = CuttingData(rpm: 18000, feed: 1200, plunge: 300, stepdown: dc * unitScale * 0.3, stepoverPercent: 40)
            if let presets = (t["start-values"] as? [String: Any])?["presets"] as? [[String: Any]], let p = presets.first {
                if let n = p["n"] as? Double { cd.rpm = n }
                if let f = p["v_f"] as? Double { cd.feed = f * unitScale }
                if let f = p["v_f_plunge"] as? Double { cd.plunge = f * unitScale }
                if let s = p["stepdown"] as? Double { cd.stepdown = s * unitScale }
                if let s = p["stepover"] as? Double { cd.stepoverPercent = min(100, s * unitScale / (dc * unitScale) * 100) }
            }
            var tool = Tool(number: (t["post-process"] as? [String: Any])?["number"] as? Int ?? i + 1,
                            name: t["description"] as? String ?? "Imported \(i + 1)", kind: kind, diameter: dc * unitScale,
                            cornerRadius: (geo["RE"] as? Double ?? 0) * unitScale, vAngle: geo["SFDM"] as? Double ?? 90,
                            flutes: geo["NOF"] as? Int ?? 2, fluteLength: (geo["LCF"] as? Double ?? 20) * unitScale,
                            stickout: (geo["LB"] as? Double ?? 30) * unitScale, defaults: cd)
            if kind == .vBit, let ta = geo["TA"] as? Double { tool.vAngle = ta * 2 }
            out.append(tool)
        }
        return out
    }
}
