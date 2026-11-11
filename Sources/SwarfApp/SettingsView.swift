import AppKit
import CAMCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("settingsTab") var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            ToolLibraryView().tabItem { Label("Tool Library", systemImage: "wrench.and.screwdriver") }.tag(1)
        }
        .frame(width: 860, height: 560)
    }
}

struct GeneralSettings: View {
    @AppStorage("defaultMachineID") var machineID = MachineProfile.workbeeRRF.id
    @AppStorage("defaultMaterialID") var materialID = "mdf"
    @AppStorage("defaultQuality") var quality = ResolutionQuality.normal.rawValue

    var body: some View {
        Form {
            Picker("Default machine", selection: $machineID) {
                ForEach(MachineProfile.builtIn) { Text($0.name).tag($0.id) }
            }
            Picker("Default material", selection: $materialID) {
                ForEach(Material.library) { Text($0.name).tag($0.id) }
            }
            Picker("Default resolution", selection: $quality) {
                ForEach(ResolutionQuality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            LabeledContent("Tool library file") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ToolLibraryStore.fileURL]) }
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolLibraryView: View {
    @ObservedObject var store = ToolLibraryStore.shared
    // Developer hook: -SwarfSelectTool N selects tool number N (automated screenshots).
    @State private var selection: UUID? = {
        let n = UserDefaults.standard.integer(forKey: "SwarfSelectTool")
        return n > 0 ? ToolLibraryStore.shared.tools.first { $0.number == n }?.id : nil
    }()
    @State private var message: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(ToolKind.allCases) { kind in
                    let tools = store.tools.filter { $0.kind == kind }
                    if !tools.isEmpty {
                        Section(kind.displayName) {
                            ForEach(tools) { t in
                                VStack(alignment: .leading) {
                                    Text("T\(t.number) · \(t.name)")
                                    Text(String(format: "Ø%.3g mm · %d fl · %.0f mm cut · %.0f RPM · %.0f mm/min", t.diameter,
                                                t.flutes, t.fluteLength, t.defaults.rpm, t.defaults.feed))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .tag(t.id)
                                .contextMenu {
                                    Button("Duplicate") { var c = t; c.id = UUID(); c.name += " copy"; store.add(c) }
                                    Button("Delete", role: .destructive) { store.remove(t.id) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Menu {
                        ForEach(ToolKind.allCases) { k in
                            Button(k.displayName) {
                                let t = Tool(name: "New \(k.displayName)", kind: k, diameter: 6,
                                             defaults: CuttingData(rpm: 18000, feed: 1200, plunge: 300, stepdown: 1.5, stepoverPercent: k == .ball ? 10 : 40))
                                store.add(t)
                                selection = store.tools.last?.id
                            }
                        }
                    } label: { Label("Add Tool", systemImage: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Import…") { importTools() }
                    Button("Export…") { exportTools() }
                    Spacer()
                    Button("Reset") { store.resetToStarter() }
                }
                .controlSize(.small)
                .padding(8)
            }
        } detail: {
            if let id = selection, let tool = store.tools.first(where: { $0.id == id }) {
                ToolEditor(tool: tool) { store.update($0) }
                    .id(id)
            } else {
                ContentUnavailableView("Select a tool", systemImage: "wrench.and.screwdriver",
                                       description: Text(message ?? "Tools and their default feeds and speeds are saved for all projects. You can import Fusion 360 tool libraries (.json)."))
            }
        }
    }

    func importTools() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { message = "Imported \(try store.importFile(url)) tools." } catch { message = error.localizedDescription }
    }

    func exportTools() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Swarf Tools.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(store.library).write(to: url)
    }
}

struct ToolEditor: View {
    @State var tool: Tool
    var onChange: (Tool) -> Void

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $tool.name)
                IntField(title: "Tool number", value: $tool.number, range: 1...99)
                Picker("Type", selection: $tool.kind) {
                    ForEach(ToolKind.allCases) { Text($0.displayName).tag($0) }
                }
            }
            Section("Geometry") {
                NumberField(title: "Diameter", value: $tool.diameter, step: 0.1, range: 0.1...50, digits: 3)
                if tool.kind == .bullNose { NumberField(title: "Corner radius", value: $tool.cornerRadius, step: 0.1, range: 0...25, digits: 2) }
                if tool.kind == .vBit || tool.kind == .drill {
                    NumberField(title: "Included angle", value: $tool.vAngle, unit: "°", step: 5, range: 10...170, digits: 1)
                    NumberField(title: "Tip diameter", value: $tool.tipDiameter, step: 0.05, range: 0...10)
                }
                IntField(title: "Flutes", value: $tool.flutes, range: 1...8)
                NumberField(title: "Flute length", value: $tool.fluteLength, step: 1, range: 0.5...200)
                NumberField(title: "Stick-out", value: $tool.stickout, step: 1, range: 1...200)
                NumberField(title: "Shank Ø", value: $tool.shankDiameter, step: 0.1, range: 0.5...25)
            }
            Section("Default cutting data (MDF baseline)") {
                NumberField(title: "Spindle", value: $tool.defaults.rpm, unit: "RPM", step: 500, range: 0...60000, digits: 0)
                NumberField(title: "Feed", value: $tool.defaults.feed, unit: "mm/min", step: 50, range: 1...20000, digits: 0)
                NumberField(title: "Plunge", value: $tool.defaults.plunge, unit: "mm/min", step: 25, range: 1...10000, digits: 0)
                NumberField(title: "Stepdown", value: $tool.defaults.stepdown, step: 0.1, range: 0.05...50)
                NumberField(title: "Stepover", value: $tool.defaults.stepoverPercent, unit: "%", step: 1, range: 1...100, digits: 0)
                NumberField(title: "Ramp angle", value: $tool.defaults.rampAngle, unit: "°", step: 0.5, range: 0.5...45, digits: 1)
                LabeledContent("Chip load", value: String(format: "%.3f mm/tooth", tool.chipLoad))
                HStack {
                    Text("Set feed from chip load:")
                    ForEach([0.03, 0.05, 0.08, 0.12], id: \.self) { cl in
                        Button(String(format: "%.2f", cl)) {
                            tool.defaults.feed = FeedsAndSpeeds.feed(rpm: tool.defaults.rpm, flutes: tool.flutes, chipLoad: cl).rounded()
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section("Notes") { TextEditor(text: $tool.notes).frame(minHeight: 50) }
        }
        .formStyle(.grouped)
        .onChange(of: tool) { _, t in onChange(t) }
    }
}
