import Foundation
import simd

public struct MachineProfile: Codable, Sendable, Identifiable, Hashable {
    public enum CommentStyle: String, Codable, Sendable, CaseIterable { case semicolon, parentheses }
    public enum ToolChange: String, Codable, Sendable, CaseIterable {
        case none          // emit nothing (split files instead)
        case m6            // "M6 Tn"
        case pause         // M0 / M1 style program pause
        case rrfPrompt     // RepRapFirmware M291 blocking message box
    }
    public enum DwellSyntax: String, Codable, Sendable { case pSeconds, pMillis, sSeconds }

    public var id: String
    public var name: String
    public var controller: String
    public var fileExtension: String
    public var commentStyle: CommentStyle
    public var decimals: Int = 3
    public var lineNumbers = false
    public var supportsArcs = true
    public var toolChange: ToolChange
    public var splitFilesPerTool: Bool
    public var spindleDwell: Double = 3
    public var dwellSyntax: DwellSyntax = .pSeconds
    public var header: [String]
    public var footer: [String]
    public var spindleOn = "M3 S{rpm}"
    public var spindleOff = "M5"
    public var envelope: V3
    public var maxFeed: Double
    public var rapidRate: Double
    public var acceleration: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var g0NeedsFeed = false
    public var notes: String = ""
    public var arcTolerance = 0.01

    // MARK: Built-ins

    public static let workbeeRRF = MachineProfile(
        id: "workbee-z1plus-rrf", name: "Ooznest WorkBee Z1+ (Duet / RRF)", controller: "RepRapFirmware 3",
        fileExtension: "gcode", commentStyle: .semicolon, toolChange: .none, splitFilesPerTool: true,
        spindleDwell: 5, dwellSyntax: .sSeconds,
        header: ["G90 ; absolute positioning", "G21 ; millimetres", "G17 ; XY plane for arcs"],
        footer: ["G0 Z{safeZ}", "G0 X0 Y0"],
        // RRF 3.3+ rejects a bare M3 unless a tool with a spindle is selected ("M3: No P parameter and no active
        // tool with spindle"), so name spindle 0 explicitly. That works with or without a selected tool.
        spindleOn: "M3 P0 S{rpm}", spindleOff: "M5 P0",
        envelope: V3(750, 750, 120), maxFeed: 5000, rapidRate: 5000, acceleration: 500, minRPM: 0, maxRPM: 30000,
        notes: "One file per tool. Zero XY on the stock corner and probe Z before each file. Arcs enabled (G2/G3).")

    public static let duetGeneric = MachineProfile(
        id: "duet-rrf", name: "Generic Duet / RepRapFirmware", controller: "RepRapFirmware 3",
        fileExtension: "gcode", commentStyle: .semicolon, toolChange: .rrfPrompt, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .sSeconds,
        header: ["G90", "G21", "G17"], footer: ["G0 Z{safeZ}"],
        spindleOn: "M3 P0 S{rpm}", spindleOff: "M5 P0",
        envelope: V3(1000, 1000, 150), maxFeed: 6000, rapidRate: 6000, acceleration: 500, minRPM: 0, maxRPM: 30000)

    public static let grbl = MachineProfile(
        id: "grbl", name: "Generic GRBL 1.1", controller: "GRBL 1.1",
        fileExtension: "nc", commentStyle: .parentheses, toolChange: .none, splitFilesPerTool: true,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21", "G54"], footer: ["G0 Z{safeZ}", "G0 X0 Y0", "M2"],
        envelope: V3(800, 800, 100), maxFeed: 5000, rapidRate: 5000, acceleration: 400, minRPM: 0, maxRPM: 24000)

    public static let shapeoko = MachineProfile(
        id: "carbide-shapeoko", name: "Carbide 3D Shapeoko / Nomad (Carbide Motion)", controller: "GRBL (Carbide Motion)",
        fileExtension: "nc", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21", "G54"], footer: ["G0 Z{safeZ}", "M5", "M2"],
        envelope: V3(838, 838, 95), maxFeed: 5000, rapidRate: 5000, acceleration: 400, minRPM: 0, maxRPM: 30000,
        notes: "Carbide Motion handles M6 tool changes and BitSetter probing.")

    public static let longmill = MachineProfile(
        id: "sienci-longmill", name: "Sienci LongMill / AltMill (gSender)", controller: "GRBL / grblHAL (gSender)",
        fileExtension: "gcode", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21", "G54"], footer: ["G0 Z{safeZ}", "M5", "M30"],
        envelope: V3(792, 845, 114), maxFeed: 4000, rapidRate: 4000, acceleration: 300, minRPM: 0, maxRPM: 30000,
        notes: "gSender intercepts M6 for guided tool changes.")

    public static let xcarve = MachineProfile(
        id: "inventables-xcarve", name: "Inventables X-Carve", controller: "GRBL",
        fileExtension: "nc", commentStyle: .parentheses, toolChange: .none, splitFilesPerTool: true,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21"], footer: ["G0 Z{safeZ}", "M5", "M2"],
        envelope: V3(750, 750, 65), maxFeed: 3000, rapidRate: 3000, acceleration: 300, minRPM: 0, maxRPM: 30000)

    public static let genmitsu = MachineProfile(
        id: "sainsmart-genmitsu", name: "SainSmart Genmitsu (3018 / 4040 / PROVer)", controller: "GRBL",
        fileExtension: "nc", commentStyle: .parentheses, toolChange: .none, splitFilesPerTool: true,
        spindleDwell: 2, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21"], footer: ["G0 Z{safeZ}", "M5", "M2"],
        envelope: V3(300, 180, 45), maxFeed: 1500, rapidRate: 1500, acceleration: 200, minRPM: 0, maxRPM: 10000)

    public static let onefinity = MachineProfile(
        id: "onefinity-buildbotics", name: "Onefinity (Buildbotics controller)", controller: "Buildbotics",
        fileExtension: "ngc", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21", "G54"], footer: ["G0 Z{safeZ}", "M5", "M2"],
        envelope: V3(816, 816, 133), maxFeed: 10000, rapidRate: 10000, acceleration: 750, minRPM: 0, maxRPM: 30000)

    public static let grblHAL = MachineProfile(
        id: "grblhal", name: "grblHAL / FluidNC (M6 capable)", controller: "grblHAL / FluidNC",
        fileExtension: "nc", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21", "G54"], footer: ["G0 Z{safeZ}", "M5", "M30"],
        envelope: V3(1000, 1000, 120), maxFeed: 8000, rapidRate: 8000, acceleration: 600, minRPM: 0, maxRPM: 24000)

    public static let linuxcnc = MachineProfile(
        id: "linuxcnc", name: "LinuxCNC", controller: "LinuxCNC",
        fileExtension: "ngc", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21 G40 G49 G80", "G54", "G64 P0.01"], footer: ["G0 Z{safeZ}", "M5", "M2"],
        envelope: V3(1000, 1000, 150), maxFeed: 10000, rapidRate: 10000, acceleration: 800, minRPM: 0, maxRPM: 24000)

    public static let mach3 = MachineProfile(
        id: "mach3", name: "Mach3 / Mach4", controller: "Mach3/4",
        fileExtension: "tap", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21 G40 G49 G80", "G54"], footer: ["G0 Z{safeZ}", "M5", "M30"],
        envelope: V3(1000, 1000, 150), maxFeed: 8000, rapidRate: 8000, acceleration: 600, minRPM: 0, maxRPM: 24000)

    public static let uccnc = MachineProfile(
        id: "uccnc", name: "UCCNC", controller: "UCCNC",
        fileExtension: "tap", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21 G40 G49 G80", "G54"], footer: ["G0 Z{safeZ}", "M5", "M30"],
        envelope: V3(1000, 1000, 150), maxFeed: 8000, rapidRate: 8000, acceleration: 600, minRPM: 0, maxRPM: 24000)

    public static let masso = MachineProfile(
        id: "masso", name: "MASSO G3 (incl. Onefinity Elite)", controller: "MASSO",
        fileExtension: "nc", commentStyle: .parentheses, toolChange: .m6, splitFilesPerTool: false,
        spindleDwell: 3, dwellSyntax: .pSeconds,
        header: ["G90 G94 G17 G21 G40 G49 G80", "G54"], footer: ["G0 Z{safeZ}", "M5", "M30"],
        envelope: V3(1220, 1220, 133), maxFeed: 10000, rapidRate: 10000, acceleration: 750, minRPM: 0, maxRPM: 24000)

    public static let marlin = MachineProfile(
        id: "marlin-mpcnc", name: "Marlin (MPCNC / LowRider)", controller: "Marlin 2",
        fileExtension: "gcode", commentStyle: .semicolon, toolChange: .pause, splitFilesPerTool: true,
        spindleDwell: 3, dwellSyntax: .sSeconds,
        header: ["G90", "G21", "G17"], footer: ["G0 Z{safeZ} F{rapid}", "M5"],
        envelope: V3(600, 600, 80), maxFeed: 2500, rapidRate: 2500, acceleration: 300, minRPM: 0, maxRPM: 30000,
        g0NeedsFeed: true, notes: "Marlin G0 moves use the last feed, so rapids carry an explicit F.")

    public static let builtIn: [MachineProfile] = [
        workbeeRRF, duetGeneric, grbl, shapeoko, longmill, xcarve, genmitsu, onefinity, grblHAL, masso, linuxcnc, mach3,
        uccnc, marlin,
    ]

    public static func find(_ id: String, custom: [MachineProfile] = []) -> MachineProfile {
        (custom + builtIn).first { $0.id == id } ?? workbeeRRF
    }
}

public struct PostFile: Sendable {
    public var name: String
    public var content: String
    public var toolpathIDs: [UUID]
}

public struct PostProcessor: Sendable {
    public var profile: MachineProfile
    public var origin: V3  // work zero in stock space
    public var safeZ: Double  // stock space
    public var jobName: String
    public var stockSize: V3
    /// Set when the toolpaths were made in test-cut mode: marks the files so they are not run on good stock.
    public var testCut: TestCut?
    /// Base name for the exported files, without extension. Defaults to `jobName`.
    public var fileName: String?

    public init(profile: MachineProfile, origin: V3, safeZ: Double, jobName: String, stockSize: V3, testCut: TestCut? = nil) {
        self.profile = profile; self.origin = origin; self.safeZ = safeZ; self.jobName = jobName; self.stockSize = stockSize
        self.testCut = testCut
    }

    /// Plain printable ASCII on one line. Controllers and senders differ in how they treat other bytes, and a
    /// line break inside a name would otherwise end the comment and turn the rest of the name into G-code.
    static func ascii(_ s: String) -> String {
        var out = ""
        for ch in s.precomposedStringWithCanonicalMapping {
            switch ch {
            case "\u{2014}", "\u{2013}", "\u{2212}": out += "-"
            case "\u{00D8}", "\u{2300}": out += "dia "
            case "\u{00B0}": out += " deg"
            case "\u{00D7}": out += "x"
            case "\u{00B7}": out += "-"
            case "\u{2018}", "\u{2019}", "\u{2032}": out += "'"
            case "\u{201C}", "\u{201D}", "\u{2033}": out += "\""
            case "\n", "\r", "\r\n", "\t": out += " "
            default:
                let folded = String(ch).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                for u in folded.unicodeScalars {
                    if u.value >= 0x20 && u.value < 0x7F { out.unicodeScalars.append(u) } else if u.value >= 0x7F { out += "?" }
                }
            }
        }
        return out
    }

    /// Drops a trailing ".gcode" / ".nc" etc. that the user typed, so it isn't doubled.
    static func stripExtension(_ s: String, _ ext: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        for e in Set([ext, "gcode", "nc", "ngc", "tap", "txt"]) where t.lowercased().hasSuffix("." + e.lowercased()) {
            return String(t.dropLast(e.count + 1))
        }
        return t
    }

    /// A file-name component: letters, digits, "-", "_" and "." only, never empty and never a dot name.
    static func fileSafe(_ s: String, fallback: String) -> String {
        let cleaned = ascii(s).replacingOccurrences(of: "\"", with: "in").replacingOccurrences(of: "/", with: "-")
        var out = ""
        for u in cleaned.unicodeScalars {
            let ok = (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A)
                || u == "-" || u == "_" || u == "."
            out.unicodeScalars.append(ok ? u : "_")
        }
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > 80 { out = String(out.prefix(80)) }
        return out.contains(where: { $0.isLetter || $0.isNumber }) ? out : fallback
    }

    func comment(_ s: String) -> String {
        let t = Self.ascii(s)
        switch profile.commentStyle {
        case .semicolon: return "; " + t
        case .parentheses: return "(" + t.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]") + ")"
        }
    }

    func num(_ v: Double) -> String {
        var s = String(format: "%.\(profile.decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    func fill(_ t: String, tool: Tool? = nil, rpm: Double = 0) -> String {
        t.replacingOccurrences(of: "{safeZ}", with: num(safeZ - origin.z))
            .replacingOccurrences(of: "{rpm}", with: num(rpm.rounded()))
            .replacingOccurrences(of: "{tool}", with: "\(tool?.number ?? 1)")
            .replacingOccurrences(of: "{toolName}", with: Self.ascii(tool?.name ?? ""))
            .replacingOccurrences(of: "{rapid}", with: num(profile.rapidRate))
    }

    func dwell(_ s: Double) -> String {
        switch profile.dwellSyntax {
        case .pSeconds: return "G4 P\(num(s))"
        case .pMillis: return "G4 P\(Int((s.isFinite ? min(max(s, 0), 3600) : 0) * 1000))"
        case .sSeconds: return "G4 S\(num(s))"
        }
    }

    /// Produce one or more files depending on the profile's tool-change strategy.
    public func process(_ toolpaths: [Toolpath]) -> [PostFile] {
        // Group consecutive toolpaths by tool.
        var groups: [[Toolpath]] = []
        for tp in toolpaths where !tp.moves.isEmpty {
            if let last = groups.last?.last, last.tool.id == tp.tool.id && last.tool.diameter == tp.tool.diameter {
                groups[groups.count - 1].append(tp)
            } else {
                groups.append([tp])
            }
        }
        if groups.isEmpty { return [] }
        let chosen = fileName.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? jobName
        let base = Self.fileSafe(Self.stripExtension(chosen, profile.fileExtension), fallback: "job") + (testCut != nil ? "_TEST" : "")
        if profile.splitFilesPerTool && groups.count > 1 {
            return groups.enumerated().map { i, g in
                let t = g[0].tool
                let safeName = Self.fileSafe(t.name, fallback: "tool")
                return PostFile(name: "\(base)_\(i + 1)_T\(t.number)_\(safeName).\(profile.fileExtension)",
                                content: emit(groups: [g], part: (i + 1, groups.count)), toolpathIDs: g.map(\.id))
            }
        }
        return [PostFile(name: "\(base).\(profile.fileExtension)", content: emit(groups: groups, part: nil),
                         toolpathIDs: groups.flatMap { $0.map(\.id) })]
    }

    func emit(groups: [[Toolpath]], part: (Int, Int)?) -> String {
        var lines: [String] = []
        var n = 10
        func out(_ s: String) {
            if profile.lineNumbers && !s.hasPrefix(";") && !s.hasPrefix("(") { lines.append("N\(n) " + s); n += 10 } else { lines.append(s) }
        }
        out(comment("\(jobName) — generated by Swarf CAM"))
        if let (i, c) = part { out(comment("File \(i) of \(c)")) }
        if let t = testCut {
            out(comment("TEST CUT - depths limited to: \(t.summary)."))
            out(comment("Not the finished part. Zero Z on the top of the test board."))
        }
        out(comment("Machine: \(profile.name)"))
        out(comment(String(format: "Stock: %.2f x %.2f x %.2f mm", stockSize.x, stockSize.y, stockSize.z)))
        out(comment(String(format: "Work zero (stock space): X%.2f Y%.2f Z%.2f", origin.x, origin.y, origin.z)))
        for g in groups {
            let t = g[0].tool
            out(comment("T\(t.number): \(t.name) — Ø\(num(t.diameter)) \(t.kind.displayName)"))
        }
        let all = groups.flatMap { $0 }
        var bb = AABB3.empty
        for tp in all { for m in tp.moves { bb.include(m.to - origin) } }
        if !bb.isEmpty {
            out(comment(String(format: "Extents X%.2f..%.2f Y%.2f..%.2f Z%.2f..%.2f", bb.min.x, bb.max.x, bb.min.y, bb.max.y, bb.min.z, bb.max.z)))
        }
        let secs = all.reduce(0.0) { $0 + $1.stats(rapidRate: profile.rapidRate, acceleration: profile.acceleration).seconds }
        let wholeSecs = secs.isFinite ? Int(min(max(secs, 0), 8.64e6)) : 0
        out(comment(String(format: "Estimated run time: %d min %02d s", wholeSecs / 60, wholeSecs % 60)))
        for h in profile.header { out(fill(h)) }

        var lastFeed: Double = -1
        var cur = V3(.nan, .nan, .nan)
        var firstGroup = true
        for g in groups {
            let tool = g[0].tool
            let rpm = min(max(g[0].rpm, profile.minRPM), profile.maxRPM)
            if !firstGroup || part == nil {
                switch profile.toolChange {
                case .m6:
                    out(fill(profile.spindleOff))
                    out("T\(tool.number) M6")
                case .pause:
                    if !firstGroup { out(fill(profile.spindleOff)); out(comment("Change tool to T\(tool.number): \(tool.name)")); out("M0") }
                case .rrfPrompt:
                    if !firstGroup {
                        out(fill(profile.spindleOff))
                        out("G0 Z\(num(safeZ - origin.z))")
                        // RepRapFirmware reads "" inside a quoted string as one literal quote.
                        let shown = Self.ascii(tool.name).replacingOccurrences(of: "\"", with: "\"\"")
                        out("M291 P\"Insert T\(tool.number): \(shown). Re-zero Z, then press OK.\" R\"Tool change\" S3")
                    }
                case .none:
                    break
                }
            }
            // A tool change may leave the machine anywhere, so the first move of each tool states X, Y, Z and F in full.
            cur = V3(.nan, .nan, .nan)
            lastFeed = -1
            firstGroup = false
            out("G0 Z\(num(safeZ - origin.z))\(profile.g0NeedsFeed ? " F\(num(profile.rapidRate))" : "")")
            cur.z = safeZ
            out(fill(profile.spindleOn, tool: tool, rpm: rpm))
            if profile.spindleDwell > 0 { out(dwell(profile.spindleDwell)) }
            for tp in g {
                out(comment("Operation: \(tp.name) — \(tp.kind.displayName)"))
                let moves = profile.supportsArcs ? ArcFitter.fit(tp.moves, tolerance: profile.arcTolerance) : tp.moves
                var prev = cur.x.isNaN ? V3(origin.x, origin.y, safeZ) : cur
                for m in moves {
                    let p = m.to - origin
                    var words: [String] = []
                    let code: String
                    switch m.kind {
                    case .rapid: code = "G0"
                    case .feed, .plunge: code = "G1"
                    case .arcCW: code = "G2"
                    case .arcCCW: code = "G3"
                    }
                    words.append(code)
                    if m.isArc || cur.x.isNaN || abs(p.x - (cur.x - origin.x)) > 1e-7 { words.append("X" + num(p.x)) }
                    if m.isArc || cur.y.isNaN || abs(p.y - (cur.y - origin.y)) > 1e-7 { words.append("Y" + num(p.y)) }
                    if cur.z.isNaN || abs(p.z - (cur.z - origin.z)) > 1e-7 { words.append("Z" + num(p.z)) }
                    if m.isArc, let c = m.center {
                        words.append("I" + num(c.x - prev.x))
                        words.append("J" + num(c.y - prev.y))
                    }
                    // A move that goes nowhere is dropped before the feed is recorded, so its F word is not lost.
                    if words.count == 1 { continue }
                    if m.kind == .rapid {
                        if profile.g0NeedsFeed { words.append("F" + num(profile.rapidRate)); lastFeed = -1 }
                    } else {
                        let f = min(m.feed, profile.maxFeed)
                        if abs(f - lastFeed) > 1e-6 { words.append("F" + num(f)); lastFeed = f }
                    }
                    out(words.joined(separator: " "))
                    cur = m.to
                    prev = m.to
                }
            }
        }
        out(fill(profile.spindleOff))
        for f in profile.footer { out(fill(f)) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Checks the program against the machine envelope and limits.
    public func validate(_ toolpaths: [Toolpath]) -> [String] {
        var w: [String] = []
        var bb = AABB3.empty
        for tp in toolpaths { for m in tp.moves { bb.include(m.to) } }
        guard !bb.isEmpty else { return w }
        let size = bb.size
        if size.x > profile.envelope.x { w.append(String(format: "Program X travel %.0f mm exceeds machine X %.0f mm.", size.x, profile.envelope.x)) }
        if size.y > profile.envelope.y { w.append(String(format: "Program Y travel %.0f mm exceeds machine Y %.0f mm.", size.y, profile.envelope.y)) }
        if size.z > profile.envelope.z { w.append(String(format: "Program Z travel %.0f mm exceeds machine Z %.0f mm.", size.z, profile.envelope.z)) }
        for tp in toolpaths {
            if tp.rpm > profile.maxRPM { w.append("\(tp.name): \(Int(tp.rpm)) RPM exceeds machine maximum \(Int(profile.maxRPM)).") }
            if let mf = tp.moves.map(\.feed).max(), mf > profile.maxFeed {
                w.append("\(tp.name): feed \(Int(mf)) mm/min will be clamped to \(Int(profile.maxFeed)).")
            }
        }
        return w
    }
}

/// Replaces runs of short planar feed moves with G2/G3 arcs within tolerance.
public enum ArcFitter {
    public static func fit(_ moves: [Move], tolerance: Double) -> [Move] {
        var out: [Move] = []
        var i = 0
        var prevPos: V3? = nil
        while i < moves.count {
            let m = moves[i]
            guard m.kind == .feed, let start = prevPos else {
                out.append(m); prevPos = m.to; i += 1; continue
            }
            // Gather a run of planar feed moves with identical feed.
            var pts = [start, m.to]
            var j = i + 1
            while j < moves.count, moves[j].kind == .feed, moves[j].feed == m.feed, abs(moves[j].to.z - start.z) < 1e-6,
                  abs(m.to.z - start.z) < 1e-6 {
                pts.append(moves[j].to); j += 1
            }
            if pts.count < 4 || abs(m.to.z - start.z) > 1e-6 {
                out.append(m); prevPos = m.to; i += 1; continue
            }
            // Greedy arc fitting along pts.
            var a = 0
            while a < pts.count - 1 {
                var best = -1
                var bestArc: (V2, Bool)? = nil
                var b = a + 3
                while b < pts.count && b - a <= 400 {
                    if let arc = arcFits(Array(pts[a...b]), tolerance) { best = b; bestArc = arc } else if best > 0 { break }
                    b += 1
                }
                if best > 0, let (c, cw) = bestArc {
                    out.append(Move(cw ? .arcCW : .arcCCW, pts[best], feed: m.feed, center: c))
                    a = best
                } else {
                    out.append(Move(.feed, pts[a + 1], feed: m.feed))
                    a += 1
                }
            }
            prevPos = pts.last
            i = j
        }
        return out
    }

    static func circle(_ a: V2, _ b: V2, _ c: V2) -> (V2, Double)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        if abs(d) < 1e-12 { return nil }
        let a2 = simd_length_squared(a), b2 = simd_length_squared(b), c2 = simd_length_squared(c)
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        let center = V2(ux, uy)
        return (center, simd_distance(center, a))
    }

    static func arcFits(_ p3: [V3], _ tol: Double) -> (V2, Bool)? {
        let p = p3.map(\.xy)
        guard let (c, r) = circle(p[0], p[p.count / 2], p[p.count - 1]), r > 0.2, r < 2000 else { return nil }
        // All points on circle, chord sagitta within tolerance, consistent turning.
        var sweep = 0.0
        var sign = 0.0
        for k in 0..<p.count {
            if abs(simd_distance(p[k], c) - r) > tol { return nil }
            if k > 0 {
                let chord = simd_distance(p[k - 1], p[k])
                if chord > 2 * r * 0.999 { return nil }
                let sag = r - (max(0, r * r - chord * chord / 4)).squareRoot()
                if sag > tol { return nil }
                let u = p[k - 1] - c, v = p[k] - c
                let ang = atan2(u.x * v.y - u.y * v.x, simd_dot(u, v))
                if abs(ang) < 1e-9 { continue }
                let s: Double = ang > 0 ? 1 : -1
                if sign == 0 { sign = s } else if s != sign { return nil }
                sweep += ang
            }
        }
        if sign == 0 || abs(sweep) > 2 * .pi - 0.05 || abs(sweep) < 0.02 { return nil }
        return (c, sign < 0)
    }
}
