import CAMCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Setup") {
                Label {
                    VStack(alignment: .leading) {
                        Text("Model & Orientation")
                        Text(model.document.modelName).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "cube") }
                .tag(SidebarItem.model)
                Label {
                    VStack(alignment: .leading) {
                        Text("Stock & Work Zero")
                        Text(Material.named(model.job.stock.materialID).name).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "shippingbox") }
                .tag(SidebarItem.stock)
                Label {
                    VStack(alignment: .leading) {
                        Text("Machine & Output")
                        Text(model.machine.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } icon: { Image(systemName: "gearshape.2") }
                .tag(SidebarItem.machine)
            }

            Section {
                ForEach(model.job.regions) { r in
                    Label {
                        HStack {
                            Text(r.name).strikethrough(!r.enabled)
                            Spacer()
                            Text(r.kind == .keepOut ? "keep-out" : "only").font(.caption2).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: r.kind == .keepOut ? "nosign" : "square.dashed").foregroundStyle(r.kind == .keepOut ? .red : .green)
                    }
                    .tag(SidebarItem.region(r.id))
                    .contextMenu {
                        Button(r.enabled ? "Disable" : "Enable") { model.regionBinding(r.id, \.enabled).wrappedValue.toggle() }
                        Button("Delete", role: .destructive) { model.deleteRegion(r.id) }
                    }
                }
                if model.job.regions.isEmpty {
                    Text("Drag boxes over features you don't want milled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Regions")
                    Spacer()
                    Button { model.mode = .drawKeepOut } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                        .buttonStyle(.borderless)
                        .help("Draw a keep-out region (⌥⌘K)")
                        .disabled(model.placed == nil)
                }
            }

            if model.job.activeFlip != nil {
                // Two-sided job: one list per step, in the order they run.
                ForEach(FlipStage.allCases, id: \.self) { stage in
                    let ops = model.job.operations.filter { $0.flipStage == stage }
                    Section {
                        operationRows(ops, stage: stage)
                        if ops.isEmpty {
                            Text(stage == .dowels ? "Add dowel holes from the + menu." : stage == .sideB
                                 ? "Set an operation's side to B in its inspector, or right-click it." : "No operations yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(stage == .sideB ? "Side B (back) — after the flip" : stage.title)
                    }
                }
            }

            Section {
                if model.job.activeFlip == nil { operationRows(model.job.operations, stage: nil) }
                if !model.job.operations.isEmpty {
                    Button { model.generateNow() } label: {
                        HStack(spacing: 6) {
                            if model.generating {
                                ProgressView().controlSize(.small)
                                Text("Recalculating…")
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Recalculate All Toolpaths")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.placed == nil)
                    .help("Throw away every calculated toolpath and calculate them all again (⌘G)")
                    .selectionDisabled()
                    .padding(.vertical, 4)
                }
                if model.job.operations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No operations yet.").font(.caption).foregroundStyle(.secondary)
                        Button {
                            model.addFullProcessing()
                        } label: { Label("Full Processing", systemImage: "wand.and.stars") }
                            .disabled(model.placed == nil)
                    }
                }
            } header: {
                HStack {
                    Text(model.job.activeFlip == nil ? "Operations" : "Add operations")
                    Spacer()
                    Menu {
                        Button { model.addFullProcessing() } label: { Label("Full Processing (auto)", systemImage: "wand.and.stars") }
                        Button { model.addRestClearing() } label: { Label("Rest Clearing (smaller bit)", systemImage: "arrow.down.right.and.arrow.up.left") }
                            .disabled(model.restSourceOperation == nil)
                        Divider()
                        ForEach(OperationKind.allCases) { k in
                            Button { model.addOperation(k) } label: { Label(k.displayName, systemImage: k.symbol) }
                        }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.placed == nil)
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            switch model.selection {
            case .operation(let id): model.deleteOperation(id)
            case .region(let id): model.deleteRegion(id)
            default: break
            }
        }
    }
}

extension SidebarView {
    @ViewBuilder func operationRows(_ ops: [CAMCore.Operation], stage: FlipStage?) -> some View {
        ForEach(ops) { op in
            OperationRow(model: model, op: op)
                .tag(SidebarItem.operation(op.id))
                .contextMenu {
                    Button("Duplicate") { model.duplicateOperation(op.id) }
                    Button(op.enabled ? "Disable" : "Enable") { model.opBinding(op.id, \.enabled)?.wrappedValue.toggle() }
                    if model.job.activeFlip != nil && op.kind != .dowelHoles {
                        if op.machiningSide == .b {
                            Button("Move to Side A") { model.setSide(.a, for: op.id) }
                        } else if op.kind.allowedOnSideB {
                            Button("Move to Side B") { model.setSide(.b, for: op.id) }
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { model.deleteOperation(op.id) }
                }
        }
        .onMove { from, to in
            if let stage { model.moveOperations(in: stage, from: from, to: to) } else { model.moveOperations(from: from, to: to) }
        }
        .onDelete { idx in for i in idx { model.deleteOperation(ops[i].id) } }
    }
}

struct OperationRow: View {
    @ObservedObject var model: ProjectModel
    let op: CAMCore.Operation

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: model.opBinding(op.id, \.enabled) ?? .constant(true))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: op.kind.symbol).frame(width: 18).foregroundStyle(op.enabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(op.name).lineLimit(1).foregroundStyle(op.enabled ? .primary : .secondary)
                Text(op.tool.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            statusView
        }
    }

    @ViewBuilder var statusView: some View {
        switch model.status[op.id] {
        case .running(let p):
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
        case .failed(let e):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(e)
        case .done:
            if let tp = model.toolpaths.first(where: { $0.id == op.id }), !tp.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(tp.warnings.joined(separator: "\n"))
            } else if let s = model.stats(for: op.id) {
                Text(formatDuration(s.seconds)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}
