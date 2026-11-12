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
    /// Edits to the selected tool. They reach the library (and open projects) only when saved.
    @State private var draft: Tool?
    @State private var pendingSelection: UUID??
    @State private var confirmReset = false
    @State private var message: String?

    var saved: Tool? { selection.flatMap { id in store.tools.first { $0.id == id } } }
    var dirty: Bool { draft != nil && saved != nil && draft != saved }

    /// Selecting another tool with unsaved edits asks first.
    var listSelection: Binding<UUID?> {
        Binding(get: { selection }, set: { new in
            guard new != selection else { return }
            if dirty { pendingSelection = .some(new) } else { select(new) }
        })
    }

    func select(_ id: UUID?) {
        selection = id
        draft = id.flatMap { id in store.tools.first { $0.id == id } }
    }

    func saveDraft() {
        guard let d = draft, dirty else { return }
        store.update(d)
        message = "Saved \(d.name)."
    }

    var body: some View {
        // A plain split rather than NavigationSplitView: inside the Settings window, a split view's toolbar replaces
        // the window's own, and the General / Tool Library tab buttons stop working.
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: listSelection) {
                    ForEach(ToolKind.allCases) { kind in
                        let tools = store.tools.filter { $0.kind == kind }
                        if !tools.isEmpty {
                            Section(kind.displayName) {
                                ForEach(tools) { t in
                                    VStack(alignment: .leading) {
                                        Text("T\(t.number) · \(t.name)" + (t.id == selection && dirty ? " (edited)" : ""))
                                        Text(String(format: "Ø%.3g mm · %d fl · %.0f mm cut · %.0f RPM · %.0f mm/min", t.diameter,
                                                    t.flutes, t.fluteLength, t.defaults.rpm, t.defaults.feed))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .tag(t.id)
                                    .contextMenu {
                                        Button("Duplicate") { var c = t; c.id = UUID(); c.name += " copy"; store.add(c) }
                                        Button("Delete", role: .destructive) {
                                            store.remove(t.id)
                                            if selection == t.id { select(nil) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let note = store.lastError ?? message {
                        Text(note).font(.caption).foregroundStyle(store.lastError != nil ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Menu {
                            ForEach(ToolKind.allCases) { k in
                                Button(k.displayName) { addTool(k) }
                            }
                        } label: { Label("Add Tool", systemImage: "plus") }
                        .fixedSize()
                        Button("Import…") { importTools() }
                        Button("Export…") { exportTools() }
                        Spacer()
                        Button("Reset…") { confirmReset = true }
                    }
                }
                .controlSize(.small)
                .padding(8)
            }
            .frame(width: 300)
            Divider()
            VStack(spacing: 0) {
                if let d = draft, saved != nil {
                    ToolEditor(tool: Binding(get: { d }, set: { draft = $0 }))
                        .id(selection)
                    Divider()
                    HStack {
                        if dirty {
                            Label("Unsaved changes", systemImage: "pencil.circle.fill").foregroundStyle(.orange).font(.callout)
                        } else {
                            Text("Saved. Open projects using this tool pick up its geometry.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revert") { commitFieldThen { draft = saved } }.disabled(!dirty)
                        Button("Save") { commitFieldThen { saveDraft() } }
                            .keyboardShortcut("s", modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(!dirty)
                    }
                    .padding(10)
                } else {
                    ContentUnavailableView("Select a tool", systemImage: "wrench.and.screwdriver",
                                           description: Text(message ?? "Tools and their default feeds and speeds are saved for all projects. You can import Fusion 360 tool libraries (.json)."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { if draft == nil { select(selection) } }
        // Closing the window keeps the edits rather than silently throwing them away.
        .onDisappear { saveDraft() }
        .alert("Save changes to \(draft?.name ?? "this tool")?", isPresented: Binding(
            get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })) {
            Button("Save") { saveDraft(); if let p = pendingSelection { select(p) }; pendingSelection = nil }
            Button("Discard", role: .destructive) { if let p = pendingSelection { select(p) }; pendingSelection = nil }
            Button("Cancel", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("You edited this tool but haven't saved it.")
        }
        .alert("Reset the tool library?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.resetToStarter(); select(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All your tools are replaced with the starter set. Export the library first if you want to keep a copy.")
        }
    }

    /// A number typed into a field is only committed on Return or when the field loses focus, and clicking a button
    /// doesn't take focus. End editing first so the typed value is part of what gets saved.
    func commitFieldThen(_ action: @escaping () -> Void) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async { action() }
    }

    func addTool(_ k: ToolKind) {
        if dirty { saveDraft() }
        let t = Tool(name: "New \(k.displayName)", kind: k, diameter: 6,
                     defaults: CuttingData(rpm: 18000, feed: 1200, plunge: 300, stepdown: 1.5, stepoverPercent: k == .ball ? 10 : 40))
        store.add(t)
        select(store.tools.last?.id)
    }

    func importTools() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        store.lastError = nil
        do {
            let n = try store.importFile(url)
            message = n == 0 ? "Nothing new to import: those tools are already in the library." : "Imported \(n) tool\(n == 1 ? "" : "s")."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportTools() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Swarf Tools.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(store.library).write(to: url, options: .atomic)
            message = "Exported \(store.tools.count) tools to \(url.lastPathComponent)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}

struct ToolEditor: View {
    @Binding var tool: Tool

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
            Section {
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
            } header: {
                Text("Default cutting data (MDF baseline)")
            } footer: {
                Text("These are for MDF. When an operation picks up this tool, Swarf scales them for the project's stock material (hardwood: feed and plunge ×0.8, stepdown ×0.75). Existing operations keep their own feeds until you click Reset to tool defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes") { TextEditor(text: $tool.notes).frame(minHeight: 50) }
        }
        .formStyle(.grouped)
    }
}
