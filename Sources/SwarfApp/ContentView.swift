import CAMCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var document: SwarfDocument
    @StateObject private var model: ProjectModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @State private var dropTargeted = false

    init(document: SwarfDocument) {
        self.document = document
        _model = StateObject(wrappedValue: ProjectModel(document: document))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 360)
        } detail: {
            ZStack {
                ViewportView(model: model)
                    .ignoresSafeArea()
                ViewportOverlay(model: model)
                if document.mesh == nil { EmptyStateView(model: model) }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .padding(20).allowsHitTesting(false)
                }
            }
            // An overlay, not a ZStack child, so the banner never changes the layout of the 3D view underneath.
            .overlay(alignment: .top) {
                if let n = model.notice {
                    NoticeBanner(notice: n) { model.notice = nil }
                        .padding(.top, 64)
                        .padding(.leading, 76)  // clear of the view's tool strip on the left
                        .padding(.trailing, 16)
                        .id(n.id)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "stl" else { return }
                    Task { @MainActor in model.importSTL(url: url) }
                }
                return true
            }
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar { toolbar }
        .navigationTitle(document.modelName)
        .navigationSubtitle(subtitle)
        .focusedSceneValue(\.projectModel, model)
        .onAppear {
            model.undoManager = undoManager
            if document.mesh == nil, let url = PendingImports.shared.next() { model.importSTL(url: url) }
            // Developer hook: -SwarfOpenSettings YES (with -settingsTab 1 for the tool library).
            if UserDefaults.standard.bool(forKey: "SwarfOpenSettings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openSettings() }
            }
        }
        .onChange(of: undoManager) { _, um in model.undoManager = um }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.stlModel, .data]) { result in
            switch result {
            case .success(let url):
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                model.importSTL(url: url)
            case .failure(let error):
                model.errorMessage = "The file could not be opened: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $model.showExport) { ExportView(model: model) }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    var subtitle: String {
        guard let p = model.placed else { return "No model" }
        let s = p.stockSize
        return String(format: "Stock %.1f × %.1f × %.1f mm · %@", s.x, s.y, s.z, model.machine.name)
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.presentImport() } label: { Label("Import STL", systemImage: "square.and.arrow.down") }
                .help("Import an STL model (⇧⌘I)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.generateNow() } label: {
                if model.generating {
                    Label { Text("Recalculating…") } icon: { ProgressView().controlSize(.small) }
                } else {
                    Label("Recalculate All", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.placed == nil || model.job.operations.isEmpty)
            .help("Recalculate every toolpath from scratch (⌘G)")
            Toggle(isOn: $model.simMode.animation()) {
                Label("Simulate", systemImage: "play.square.stack")
            }
            .onChange(of: model.simMode) { _, on in
                if on { model.startSimulation() } else { model.stopSimulation() }
            }
            .disabled(model.toolpaths.isEmpty)
            .help("Material-removal simulation (⌘R)")
            Button { model.showExport = true } label: { Label("Export G-code", systemImage: "square.and.arrow.up.on.square") }
                .disabled(model.toolpaths.isEmpty)
                .help("Post-process and export (⌘E)")
            Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var model: ProjectModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Drop an STL here").font(.title2.weight(.semibold))
            Text("Swarf turns 3D models into G-code for your CNC.\nWorks with GRBL, Duet, Mach3 and more.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Import STL…") { model.presentImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Open Sample Project") { model.loadSample() }
            }
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct ViewportOverlay: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                viewControls
                Spacer()
                legend
            }
            HStack(alignment: .top) {
                toolPalette
                if model.mode != .orbit { modeHint }
                Spacer()
            }
            Spacer()
            if model.simMode { SimulationBar(model: model) } else { statusBar }
        }
        .padding(12)
    }

    var viewControls: some View {
        HStack(spacing: 6) {
            ForEach(ViewPreset.allCases) { v in
                Button(v.label) { model.requestView(v) }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 3)
            }
            Divider().frame(height: 16)
            Menu {
                Toggle("Model", isOn: $model.showModel)
                Toggle("Stock", isOn: $model.showStock)
                Toggle("Toolpaths", isOn: $model.showToolpaths)
                Toggle("Rapid moves", isOn: $model.showRapids)
                Divider()
                Toggle("Highlight undercuts", isOn: $model.showUndercuts)
            } label: { Image(systemName: "eye") }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    var toolPalette: some View {
        VStack(spacing: 2) {
            ForEach(InteractionMode.allCases) { m in
                Button {
                    model.mode = model.mode == m ? .orbit : m
                    if m == .orbit { model.highlightTriangles = [] }
                } label: {
                    Image(systemName: m.symbol)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 30)
                        .background(model.mode == m ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(model.mode == m ? .white : .primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.label)
                .disabled(model.placed == nil || (m == .placeTab && model.selectedOperation?.kind != .cutout)
                          || (m == .placeDowel && (model.job.activeFlip == nil || model.dowelOperation == nil)))
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    var modeHint: some View {
        let text: String = {
            switch model.mode {
            case .faceUp: return "Click a face to make it the TOP (machined) face"
            case .faceDown: return "Click a face to lay it flat on the bed"
            case .drawKeepOut: return "Drag a rectangle over features that must not be milled"
            case .placeTab: return model.selectedOperation?.kind == .cutout ? "Click along the cutout path to add tabs" : "Select a Cutout operation first"
            case .placeDowel: return "Click in the waste to add a mirrored dowel pair; click a hole to remove it"
            case .orbit: return ""
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: model.mode.symbol)
            Text(text).lineLimit(3).frame(maxWidth: 380, alignment: .leading)
            Button("Done") { model.mode = .orbit; model.highlightTriangles = [] }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.toolpaths.enumerated()), id: \.element.id) { i, tp in
                HStack(spacing: 6) {
                    let c = Renderer.palette[i % Renderer.palette.count]
                    Circle().fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))).frame(width: 8, height: 8)
                    Text(tp.name).font(.caption)
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .opacity(model.toolpaths.isEmpty || !model.showToolpaths ? 0 : 1)
    }

    var statusBar: some View {
        HStack(spacing: 14) {
            if let p = model.placed {
                let s = p.modelBounds.size
                Label(String(format: "%.1f × %.1f × %.1f mm", s.x, s.y, s.z), systemImage: "cube")
            }
            if let d = model.diagnostics {
                Label("\(d.triangleCount.formatted()) triangles", systemImage: "triangle")
                if !d.isWatertight {
                    Label("Not watertight", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help("\(d.openEdges) open edges, \(d.nonManifoldEdges) non-manifold edges. Heightmap CAM is tolerant of this.")
                }
            }
            if let t = model.job.activeTestCut {
                Label("Test cut", systemImage: "testtube.2").foregroundStyle(.orange)
                    .help("Test cut mode: \(t.summary). Turn it off in Stock settings for the real job.")
            }
            if !model.toolpaths.isEmpty {
                Label(formatDuration(model.totalSeconds), systemImage: "clock")
                    .help("Estimated machining time including accelerations")
            }
            if model.generating { ProgressView().controlSize(.small); Text("Generating…") }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}

struct SimulationBar: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.simPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                }
                .buttonStyle(.borderless)
                Slider(value: Binding(get: { model.simPosition }, set: { v in
                    model.simPosition = v
                    model.seekSimulation(to: v, analyze: v >= 1)
                }), in: 0...1)
                .frame(minWidth: 300)
                Text(String(format: "%3.0f%%", model.simPosition * 100)).monospacedDigit().frame(width: 44)
                Button("Exit") { model.stopSimulation() }.controlSize(.small)
            }
            if let a = model.simAnalysis {
                HStack(spacing: 16) {
                    Label(a.gougeCells == 0 ? "No gouges" : String(format: "Gouges: max %.2f mm", a.maxGouge),
                          systemImage: a.gougeCells == 0 ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(a.gougeCells == 0 ? .green : .red)
                    Label(String(format: "Max leftover %.2f mm", a.maxLeftover), systemImage: "square.stack.3d.down.forward")
                        .foregroundStyle(.blue)
                    Label(String(format: "Removed %.1f cm³", a.removedVolume / 1000), systemImage: "trash")
                    let kv = StockSimulator.keepOutViolations(model.toolpaths, regions: model.job.regions, stockTop: model.placed?.stockTop, stockSize: model.placed?.stockSize)
                    if !kv.isEmpty {
                        Label("\(kv.count) keep-out violation(s)", systemImage: "nosign").foregroundStyle(.red).help(kv.joined(separator: "\n"))
                    }
                }
                .font(.caption)
                if let hint = model.restSuggestion {
                    HStack(spacing: 8) {
                        Label(hint.text, systemImage: "arrow.down.right.and.arrow.up.left")
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Button("Add Rest Clearing") { model.addRestClearing(after: hint.opID) }.controlSize(.small)
                    }
                    .font(.caption)
                }
            } else {
                Text("Simulating…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 760)
    }
}

func formatDuration(_ s: Double) -> String {
    guard s.isFinite else { return "unknown" }
    let secs = Int(min(max(s, 0), 3.6e8))
    let m = secs / 60, h = m / 60
    return h > 0 ? "\(h) h \(m % 60) min" : "\(m) min \(secs % 60) s"
}

/// Banner shown over the 3D view when Swarf changed something on the user's behalf.
struct NoticeBanner: View {
    let notice: ProjectModel.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue).font(.title3)
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.text).fixedSize(horizontal: false, vertical: true)
                if let title = notice.actionTitle, let action = notice.action {
                    Button(title) { action() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.5)))
        .shadow(radius: 6, y: 2)
    }
}
