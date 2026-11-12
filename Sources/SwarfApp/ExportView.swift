import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @ObservedObject var model: ProjectModel
    @Environment(\.dismiss) var dismiss
    @State private var machineID: String = ""
    @State private var selectedFile = 0
    @State private var files: [PostFile] = []
    @State private var warnings: [String] = []
    @State private var exported: String?
    @State private var problem: String?
    @State private var blocking = false
    @State private var fileName = ""
    /// Line count per file, worked out once in the background (counting a large file on every redraw was slow).
    @State private var lineCounts: [Int] = []
    @State private var estimate: Double = 0
    @State private var preparing = false
    @State private var buildTask: Task<Void, Never>?
    /// The base name the current `files` were named with, so a new file name only renames them.
    @State private var builtBase = ""
    /// Showing the G-code is optional: off by default, remembered between exports.
    @AppStorage("exportShowPreview") private var showPreview = false

    var profile: MachineProfile { MachineProfile.find(machineID.isEmpty ? model.job.machineID : machineID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Export G-code").font(.title2.bold())
                Spacer()
                Picker("Machine", selection: $machineID) {
                    ForEach(MachineProfile.builtIn) { Text($0.name).tag($0.id) }
                }
                .frame(width: 360)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    GroupBox("File name") {
                        HStack {
                            TextField("File name", text: $fileName, prompt: Text(model.document.modelName))
                                .textFieldStyle(.roundedBorder)
                            Text(".\(profile.fileExtension)").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Files") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                                Button {
                                    selectedFile = i
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.text")
                                        Text(f.name).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(lineCounts.indices.contains(i) ? "\(lineCounts[i].formatted()) lines" : "").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(4)
                                    .background(i == selectedFile ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Setup") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let p = model.placed {
                                Text(String(format: "Stock: %.1f × %.1f × %.1f mm", p.stockSize.x, p.stockSize.y, p.stockSize.z))
                                Text("Zero: \(model.job.origin.y.rawValue)-\(model.job.origin.x.rawValue), \(model.job.origin.z == .stockTop ? "top of stock" : "bed")")
                            }
                            Text("Estimated time: " + (preparing ? "…" : formatDuration(estimate)))
                            if profile.splitFilesPerTool && files.count > 1 {
                                Label("Run the files in order. Change the bit and re-probe Z between them.", systemImage: "info.circle").font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !warnings.isEmpty {
                        GroupBox("Checks") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer()
                }
                .frame(width: showPreview ? 330 : nil)
                .frame(maxWidth: showPreview ? 330 : .infinity)
                if showPreview {
                    ScrollView([.vertical, .horizontal]) {
                        Text(preview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .defaultScrollAnchor(.topLeading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            }
            if preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.generating ? "Waiting for toolpaths…" : "Preparing G-code…").foregroundStyle(.secondary)
                }
            }
            if let p = problem {
                Label(p, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let e = exported {
                Label(e, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                Button("Setup Sheet (PDF)…") { exportSetupSheet() }
                Toggle("Show G-code", isOn: $showPreview)
                Button("Copy G-code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(files.indices.contains(selectedFile) ? files[selectedFile].content : "", forType: .string)
                }
                .disabled(files.isEmpty || preparing)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(files.count > 1 ? "Export \(files.count) Files…" : "Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || blocking || preparing)
            }
        }
        .padding(20)
        .frame(minWidth: showPreview ? 980 : 560, minHeight: showPreview ? 620 : 420)
        .onAppear {
            machineID = model.job.machineID
            fileName = model.job.exportName ?? model.document.modelName
            rebuild()
        }
        .onChange(of: fileName) { _, _ in rename() }
        .onDisappear { buildTask?.cancel() }
        .onChange(of: machineID) { _, _ in rebuild() }
        .onChange(of: model.toolpathVersion) { _, _ in rebuild() }
        .onChange(of: model.generating) { _, _ in rebuild() }
    }

    /// The first 400 lines of the selected file. Scans only as far as it needs to, so it is cheap on huge files.
    var preview: String {
        guard showPreview, files.indices.contains(selectedFile) else { return "" }
        let content = files[selectedFile].content
        let total = lineCounts.indices.contains(selectedFile) ? lineCounts[selectedFile] : 0
        var seen = 0
        var cut = content.utf8.endIndex
        for i in content.utf8.indices where content.utf8[i] == UInt8(ascii: "\n") {
            seen += 1
            if seen == 400 { cut = i; break }
        }
        let head = String(content[..<cut])
        return total > 400 ? head + "\n… (\((total - 400).formatted()) more lines)" : head
    }

    /// The typed name, or nil for "use the model name".
    var chosenName: String? {
        let t = fileName.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty || t == model.document.modelName) ? nil : t
    }

    /// Remembers the chosen name in the project so the next export starts from it.
    func saveFileName() {
        let name = chosenName
        if model.job.exportName != name { model.updateJob("Change Export Name") { $0.exportName = name } }
    }

    /// Applies a new file name by renaming the prepared files; their contents don't depend on the name.
    func rename() {
        guard var post = model.postProcessor(profile: profile), !files.isEmpty, !builtBase.isEmpty else { return }
        post.fileName = chosenName
        let base = post.fileBaseName
        guard base != builtBase else { return }
        files = files.map { f in
            var f = f
            if f.name.hasPrefix(builtBase) { f.name = base + f.name.dropFirst(builtBase.count) }
            return f
        }
        builtBase = base
        exported = nil
    }

    /// Prepares the files in the background. Big 3D jobs produce millions of lines, and doing it on the main
    /// thread froze the dialog. A newer request cancels an older one.
    func rebuild() {
        exported = nil
        problem = nil
        blocking = model.generating
        buildTask?.cancel()
        guard var post = model.postProcessor(profile: profile) else {
            files = []; lineCounts = []
            warnings = ["There is no model to export."]
            preparing = false
            return
        }
        post.fileName = chosenName
        let toolpaths = model.toolpaths
        let issues = model.exportIssues
        let regions = model.job.regions
        let stockTop = model.placed?.stockTop
        let profile = self.profile
        preparing = true
        buildTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([PostFile], [Int], [String], Double)? in
                let files = post.process(toolpaths)
                if Task.isCancelled { return nil }
                let counts = files.map { f in f.content.utf8.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) } }
                var w = issues
                if files.isEmpty && w.isEmpty { w.append("There are no toolpaths to export. Add an operation first.") }
                w += post.validate(toolpaths)
                w += toolpaths.flatMap { tp in tp.warnings.map { "\(tp.name): \($0)" } }
                w += StockSimulator.keepOutViolations(toolpaths, regions: regions, stockTop: stockTop)
                let secs = toolpaths.reduce(0) { $0 + $1.stats(rapidRate: profile.rapidRate, acceleration: profile.acceleration).seconds }
                return (files, counts, w, secs)
            }.value
            guard !Task.isCancelled, let (f, c, w, secs) = result else { return }
            files = f
            lineCounts = c
            warnings = w
            estimate = secs
            builtBase = post.fileBaseName
            if !files.indices.contains(selectedFile) { selectedFile = 0 }
            preparing = false
            rename()  // the name may have been edited while the files were being prepared
        }
    }

    func export() {
        if files.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = files[0].name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try files[0].content.write(to: url, atomically: true, encoding: .utf8)
                saveFileName()
                exported = "Saved \(url.lastPathComponent)"
                problem = nil
            } catch { problem = "Could not save \(url.lastPathComponent): \(error.localizedDescription)" }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            // A folder picker gives no overwrite warning of its own, so ask before replacing files.
            let existing = files.map(\.name).filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            if !existing.isEmpty {
                let alert = NSAlert()
                alert.messageText = existing.count == 1 ? "Replace \(existing[0])?" : "Replace \(existing.count) existing files?"
                alert.informativeText = "The folder \(dir.lastPathComponent) already has G-code with the same name" + (existing.count == 1 ? "." : "s.")
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            var written = 0
            do {
                for f in files {
                    try f.content.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
                    written += 1
                }
                saveFileName()
                exported = "Saved \(files.count) files to \(dir.lastPathComponent)"
                problem = nil
                NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(files[0].name)])
            } catch {
                problem = "Only \(written) of \(files.count) files were saved. Do not run this set: \(error.localizedDescription)"
            }
        }
    }

    @MainActor func exportSetupSheet() {
        guard let placed = model.placed else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.document.modelName + " setup.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var sim = StockSimulator(stockSize: placed.stockSize, resolution: StockSimulator.defaultResolution(for: placed.stockSize))
        sim.run(model.toolpaths)
        let ppm = max(1, min(8, 480 / max(placed.stockSize.x, placed.stockSize.y)))
        let img = TopView.render(stock: sim.stock, stockSize: placed.stockSize, analysis: nil, toolpaths: [], regions: model.job.regions, pixelsPerMM: ppm)
        let sheet = SetupSheet(model: model, profile: profile, image: img.cgImage)
        let renderer = ImageRenderer(content: sheet.frame(width: 595, height: 842))
        var wrote = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            wrote = true
        }
        guard wrote, FileManager.default.fileExists(atPath: url.path) else {
            problem = "Could not write the setup sheet to \(url.lastPathComponent). Check that the folder can be written to."
            return
        }
        problem = nil
        exported = "Saved setup sheet"
        NSWorkspace.shared.open(url)
    }
}

extension TopView.Image {
    var cgImage: CGImage? {
        let provider = CGDataProvider(data: Data(rgb) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct SetupSheet: View {
    let model: ProjectModel
    let profile: MachineProfile
    let image: CGImage?

    var body: some View {
        let stockSize = model.placed?.stockSize ?? .zero
        let stockTop = model.placed?.stockTop ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.document.modelName).font(.system(size: 22, weight: .bold))
                    Text("Setup sheet · \(profile.name)").font(.system(size: 11)).foregroundStyle(.gray)
                }
                Spacer()
                Text(Date.now.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.gray)
            }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260, maxHeight: 260)
                        .overlay(alignment: originAlignment) {
                            Circle().fill(.red).frame(width: 10, height: 10).overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stock").font(.headline)
                    Text(String(format: "%.1f × %.1f × %.1f mm %@", stockSize.x, stockSize.y, stockSize.z, Material.named(model.job.stock.materialID).name))
                    Text("Work zero").font(.headline).padding(.top, 6)
                    Text("XY: \(model.job.origin.y.rawValue)-\(model.job.origin.x.rawValue) of the stock (red dot)")
                    Text("Z: \(model.job.origin.z == .stockTop ? "top of stock" : "bed / stock bottom")")
                    Text(String(format: "Safe height: %.1f mm above stock", model.job.safeHeight))
                    Text("Estimated time").font(.headline).padding(.top, 6)
                    Text(formatDuration(model.toolpaths.reduce(0) { $0 + $1.stats(rapidRate: profile.rapidRate, acceleration: profile.acceleration).seconds }))
                }
                .font(.system(size: 11))
            }
            Text("Operations").font(.headline).padding(.top, 8)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("#").bold(); Text("Operation").bold(); Text("Tool").bold(); Text("RPM").bold(); Text("Feed").bold(); Text("Depth").bold(); Text("Time").bold()
                }
                ForEach(Array(model.toolpaths.enumerated()), id: \.offset) { i, tp in
                    let s = tp.stats(rapidRate: profile.rapidRate, acceleration: profile.acceleration)
                    let op = model.job.operations.first { $0.id == tp.id }
                    GridRow {
                        Text("\(i + 1)")
                        Text(tp.name)
                        Text("T\(tp.tool.number) \(tp.tool.name)")
                        Text("\(Int(tp.rpm))")
                        Text("\(Int(op?.cutting.feed ?? 0))")
                        Text(String(format: "%.1f", stockTop - s.bounds.min.z))
                        Text(formatDuration(s.seconds))
                    }
                }
            }
            .font(.system(size: 10))
            Spacer()
            Text("Generated by Swarf — open-source CAM for hobby CNC").font(.system(size: 9)).foregroundStyle(.gray)
        }
        .padding(36)
        .foregroundStyle(.black)
        .background(.white)
    }

    var originAlignment: Alignment {
        let o = model.job.origin
        switch (o.x, o.y) {
        case (.left, .front): return .bottomLeading
        case (.center, .front): return .bottom
        case (.right, .front): return .bottomTrailing
        case (.left, .center): return .leading
        case (.center, .center): return .center
        case (.right, .center): return .trailing
        case (.left, .back): return .topLeading
        case (.center, .back): return .top
        case (.right, .back): return .topTrailing
        }
    }
}
