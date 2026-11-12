import AppKit
import CAMCore
import SwiftUI

@main
struct SwarfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { SwarfDocument() }) { file in
            ContentView(document: file.document)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands { SwarfCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = true
        Disclaimer.presentAtLaunch()
        // Developer hook: -SwarfOpen <path> opens a file at launch (used for automated screenshots).
        if let path = UserDefaults.standard.string(forKey: "SwarfOpen") {
            PendingImports.open([URL(fileURLWithPath: path)])
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        PendingImports.open(urls)
    }
}

// MARK: Launch disclaimer

enum Disclaimer {
    static let title = "Swarf is experimental software"
    static let message = """
    Swarf is experimental, open-source software provided under the MIT License, without warranty of any kind. \
    You use it, and any G-code it produces, entirely at your own discretion and risk.

    • Check every toolpath and G-code file before you run it.
    • Air-cut first, with Z zeroed well above the stock.
    • Try new jobs on inexpensive material such as MDF, pine or scrap before good stock.
    • Never leave a running machine unattended. Wear eye and hearing protection and keep hands clear.

    The authors accept no liability for damage to machines, tools or materials, or for injury.
    """

    /// Shown on every launch; the app quits unless the user acknowledges it.
    /// Developer hook: -SwarfSkipDisclaimer YES (automated screenshots only).
    @MainActor static func presentAtLaunch() {
        if UserDefaults.standard.bool(forKey: "SwarfSkipDisclaimer") { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "I Understand")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() != .alertFirstButtonReturn { NSApp.terminate(nil) }
    }
}

// MARK: Focused model for menu commands

struct FocusedModelKey: FocusedValueKey { typealias Value = ProjectModel }

extension FocusedValues {
    var projectModel: ProjectModel? {
        get { self[FocusedModelKey.self] }
        set { self[FocusedModelKey.self] = newValue }
    }
}

struct SwarfCommands: Commands {
    @FocusedValue(\.projectModel) var model
    @Environment(\.openSettings) var openSettings

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import STL…") { model?.presentImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Export G-code…") { model?.showExport = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model?.toolpaths.isEmpty ?? true)
        }
        CommandMenu("Model") {
            Button("Rotate +90° about X") { model?.rotate(axis: V3(1, 0, 0), degrees: 90) }.keyboardShortcut("x", modifiers: [.command, .option])
            Button("Rotate +90° about Y") { model?.rotate(axis: V3(0, 1, 0), degrees: 90) }.keyboardShortcut("y", modifiers: [.command, .option])
            Button("Rotate +90° about Z") { model?.rotate(axis: V3(0, 0, 1), degrees: 90) }.keyboardShortcut("z", modifiers: [.command, .option])
            Divider()
            Button("Lay Flat (Largest Face Down)") { model?.layFlat() }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Pick Face to Point Up") { model?.mode = .faceUp }.keyboardShortcut("u", modifiers: [.command, .option])
            Button("Pick Face to Lay on Bed") { model?.mode = .faceDown }.keyboardShortcut("d", modifiers: [.command, .option])
            Button("Reset Orientation") { model?.resetOrientation() }
            Divider()
            Button("Draw Keep-out Region") { model?.mode = .drawKeepOut }.keyboardShortcut("k", modifiers: [.command, .option])
        }
        CommandMenu("Toolpath") {
            Button("Recalculate All Toolpaths") { model?.generateNow() }.keyboardShortcut("g", modifiers: .command)
            Button("Full Processing Template") { model?.addFullProcessing() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Menu("Add Operation") {
                ForEach(OperationKind.allCases) { k in Button(k.displayName) { model?.addOperation(k) } }
            }
            Divider()
            Button(model?.simMode == true ? "Exit Simulation" : "Simulate") { model?.toggleSimulation() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Play / Pause Simulation") { model?.togglePlay() }
                .keyboardShortcut(" ", modifiers: [])
                .disabled(model?.simMode != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Iso View") { model?.requestView(.iso) }.keyboardShortcut("0", modifiers: .command)
            Button("Top View") { model?.requestView(.top) }.keyboardShortcut("1", modifiers: .command)
            Button("Front View") { model?.requestView(.front) }.keyboardShortcut("2", modifiers: .command)
            Button("Right View") { model?.requestView(.right) }.keyboardShortcut("3", modifiers: .command)
            Button("Bottom View") { model?.requestView(.bottom) }.keyboardShortcut("4", modifiers: .command)
            Divider()
        }
        CommandGroup(after: .windowArrangement) {
            Button("Tool Library…") {
                UserDefaults.standard.set(1, forKey: "settingsTab")
                openSettings()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}
