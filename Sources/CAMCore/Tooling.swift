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
    /// Z levels (descending) for cutting from `top` down to `bottom`: the depth split into equal passes no deeper than `stepdown`.
    public func passLevels(top: Double, bottom: Double, stepdown: Double) -> [Double] {
        let total = top - bottom
        guard total > 1e-9 else { return [bottom] }
        let n = max(1, Int(ceil(total / max(0.05, stepdown) - 1e-9)))
        return (1...n).map { top - total * Double($0) / Double(n) }
    }

    public init(number: Int = 1, name: String, kind: ToolKind, diameter: Double, cornerRadius: Double = 0,
                vAngle: Double = 90, flutes: Int = 2, fluteLength: Double = 20, stickout: Double = 30,
                shankDiameter: Double? = nil,
                defaults: CuttingData) {
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

    /// True when the shank is wider than the cutter (a 1 mm bit on a 1/8" shank). Above the flutes such a shank would
    /// rub a wall the cutter itself clears, so the engine keeps it off the model (see `CAMContext.toolField`).
    public var hasWideShank: Bool {
        (kind == .flat || kind == .ball || kind == .bullNose) && shankDiameter > diameter + 0.01 && fluteLength > 0
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

    /// How this material changes a tool's MDF-baseline cutting data, e.g. "feed and plunge ×0.8, stepdown ×0.75",
    /// or nil when it uses the tool's values as they are.
    public var adjustmentSummary: String? {
        func f(_ v: Double) -> String { "×" + String(format: "%g", v) }
        var parts: [String] = []
        if rpmFactor != 1 { parts.append("spindle " + f(rpmFactor)) }
        if feedFactor != 1 { parts.append("feed and plunge " + f(feedFactor)) }
        if stepdownFactor != 1 { parts.append("stepdown " + f(stepdownFactor)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

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
                 defaults: wood(18000, 1500, 400, 2.0, 45)),
            Tool(number: 2, name: "3.175 mm (1/8\") Flat 2F", kind: .flat, diameter: 3.175, flutes: 2, fluteLength: 17, stickout: 25,
                 shankDiameter: 3.175, defaults: wood(18000, 1000, 300, 1.5, 40)),
            Tool(number: 3, name: "6.35 mm (1/4\") Flat 2F", kind: .flat, diameter: 6.35, flutes: 2, fluteLength: 25, stickout: 32,
                 defaults: wood(18000, 1600, 400, 2.5, 45)),
            Tool(number: 4, name: "3 mm Flat 1F (plastics)", kind: .flat, diameter: 3, flutes: 1, fluteLength: 12, stickout: 20,
                 shankDiameter: 3.175, defaults: wood(16000, 900, 250, 1.0, 40)),
            Tool(number: 5, name: "3 mm Ball Nose 2F", kind: .ball, diameter: 3, flutes: 2, fluteLength: 12, stickout: 25,
                 shankDiameter: 3.175, defaults: wood(18000, 1200, 300, 1.0, 10)),
            Tool(number: 6, name: "6 mm Ball Nose Compression", kind: .ball, diameter: 6, flutes: 2, fluteLength: 50, stickout: 55,
                 defaults: wood(18000, 1500, 400, 1.5, 12)),
            Tool(number: 7, name: "1/8\" Ball Nose 2F", kind: .ball, diameter: 3.175, flutes: 2, fluteLength: 12, stickout: 25,
                 shankDiameter: 3.175, defaults: wood(18000, 1200, 300, 1.0, 10)),
            Tool(number: 8, name: "6 mm Bull Nose R1", kind: .bullNose, diameter: 6, cornerRadius: 1, flutes: 2,
                 fluteLength: 20, stickout: 30, defaults: wood(18000, 1500, 400, 1.5, 30)),
            Tool(number: 9, name: "60° V-Bit 6 mm", kind: .vBit, diameter: 6, vAngle: 60, flutes: 2, fluteLength: 5.2,
                 stickout: 25, defaults: wood(18000, 1000, 300, 1.0, 20)),
            Tool(number: 10, name: "45° V-Bit 6 mm", kind: .vBit, diameter: 6, vAngle: 45, flutes: 2, fluteLength: 7.24,
                 stickout: 25, defaults: wood(18000, 1000, 300, 1.0, 20)),
        ] + smallFlats)
    }()

    /// Small flat end mills for rest machining, on 1/8" and 4 mm shanks. Their flutes are short and the shank is wider
    /// than the cutter, which limits how deep they can reach beside a wall. Typical values: measure your own bits.
    public static let smallFlats: [Tool] = {
        let sizes: [(d: Double, flute: Double, cd: CuttingData)] = [
            (2, 6, CuttingData(rpm: 18000, feed: 720, plunge: 200, stepdown: 0.5, stepoverPercent: 40)),
            (1, 3, CuttingData(rpm: 18000, feed: 430, plunge: 120, stepdown: 0.25, stepoverPercent: 40)),
            (0.9, 3, CuttingData(rpm: 18000, feed: 400, plunge: 100, stepdown: 0.2, stepoverPercent: 40)),
        ]
        var out: [Tool] = []
        var n = 11
        for s in sizes {
            for (shank, label) in [(3.175, "1/8\" shank"), (4.0, "4 mm shank")] {
                var t = Tool(number: n, name: String(format: "%g mm Flat 2F (%@)", s.d, label), kind: .flat, diameter: s.d, flutes: 2,
                             fluteLength: s.flute, stickout: 20, shankDiameter: shank, defaults: s.cd)
                t.notes = "Typical values: measure the flute length and shank of your own bit."
                out.append(t)
                n += 1
            }
        }
        return out
    }()

    public func closest(kind: ToolKind, diameter: Double) -> Tool? {
        tools.filter { $0.kind == kind }.min { abs($0.diameter - diameter) < abs($1.diameter - diameter) }
    }

    // MARK: Fusion 360 tool library import (.json)

    public static func importFusion(_ data: Data) throws -> [Tool] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else {
            throw ToolImportError.notAToolLibrary
        }
        var out: [Tool] = []
        for (i, t) in list.enumerated() {
            guard let geo = t["geometry"] as? [String: Any], let dc = geo["DC"] as? Double, dc.isFinite, dc > 0 else { continue }
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
            // Imported values are not trusted: keep every number finite and in a usable range.
            func sane(_ v: Double, _ fallback: Double, min lo: Double = 0) -> Double { v.isFinite && v > lo ? v : fallback }
            tool.cornerRadius = min(Swift.max(0, tool.cornerRadius.isFinite ? tool.cornerRadius : 0), tool.diameter / 2)
            tool.vAngle = tool.vAngle.isFinite && tool.vAngle >= 10 && tool.vAngle <= 170 ? tool.vAngle : 90
            tool.flutes = Swift.max(1, tool.flutes)
            tool.fluteLength = sane(tool.fluteLength, 20)
            tool.stickout = sane(tool.stickout, 30)
            tool.defaults.rpm = sane(tool.defaults.rpm, 18000)
            tool.defaults.feed = sane(tool.defaults.feed, 1200)
            tool.defaults.plunge = sane(tool.defaults.plunge, 300)
            tool.defaults.stepdown = sane(tool.defaults.stepdown, tool.diameter * 0.3)
            tool.defaults.stepoverPercent = Swift.min(100, sane(tool.defaults.stepoverPercent, 40))
            out.append(tool)
        }
        if out.isEmpty { throw ToolImportError.noUsableTools }
        return out
    }
}

public enum ToolImportError: Error, LocalizedError {
    case notAToolLibrary
    case noUsableTools

    public var errorDescription: String? {
        switch self {
        case .notAToolLibrary: return "This is not a Swarf or Fusion 360 tool library (.json)."
        case .noUsableTools: return "The library has no tools that Swarf can use (flat, ball, bull nose, V-bit or drill)."
        }
    }
}
