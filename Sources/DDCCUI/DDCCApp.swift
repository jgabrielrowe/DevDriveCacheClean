import AppKit
import SwiftUI

public struct DDCCApp: App {
    @NSApplicationDelegateAdaptor(MenuBarTidy.self) private var menuBar
    @State private var viewModel = AppViewModel()
    @State private var finderViewModel = FinderViewModel()
    @State private var uninstallViewModel = UninstallViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(viewModel)
                .environment(finderViewModel)
                .environment(uninstallViewModel)
        }
        .defaultSize(width: 1280, height: 700)
        .commands { menuCommands }
    }

    /// The menu bar, cut down to what this app can actually do.
    ///
    /// SwiftUI's defaults assume a document editor. Removed here: New Window,
    /// because every window would share one set of view models and show the
    /// same thing; Undo and Redo, because nothing DDCC does is undoable and an
    /// Undo item in a program that deletes files is a false promise; the
    /// text-editing group, which serves a document this app does not have; and
    /// Show/Customize Toolbar, since the toolbar declares no customization
    /// identifiers and the customize sheet opens empty.
    ///
    /// `.textFormatting` is deliberately NOT replaced. Measured with a probe:
    /// replacing it is what creates the Format menu, as an empty container that
    /// SwiftUI restores as fast as AppKit can remove it. Left alone, no Format
    /// menu is built at all.
    ///
    /// The pasteboard group stays. Measured: with it removed, ⌘V does nothing
    /// in a text field, because the key equivalents are carried by the menu
    /// items themselves. DDCC has four text inputs — three filter fields and
    /// the confirmation field that requires typing DELETE.
    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .toolbar) {}

        // All three, always, named for what they scan rather than for the view
        // they belong to, so the primary verbs have a keyboard route and a name
        // in the menu bar. Each switches to its own view first: starting a
        // sweep while looking at the Caches list would happen off screen.
        CommandMenu("Actions") {
            Button("Scan Caches") { start(.caches) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isScanRunning)
            Button("Find Large Files") { start(.files) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(finderViewModel.isRunning)
            Button("Sweep Installed Apps") { start(.uninstall) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(uninstallViewModel.isSweeping)
            Divider()
            Button("Stop") { stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!isRunning)
        }
    }

    private var isRunning: Bool {
        viewModel.isScanRunning || finderViewModel.isRunning || uninstallViewModel.isSweeping
    }

    private func start(_ mode: AppMode) {
        viewModel.mode = mode
        switch mode {
        case .caches: viewModel.startScan()
        case .files: finderViewModel.startFind()
        case .uninstall: uninstallViewModel.startSweep()
        }
    }

    /// Stops whichever run is going, not the current view's: the view can be
    /// switched while a run continues, and a Stop that did nothing because you
    /// had navigated away would be worse than no Stop at all.
    private func stop() {
        if viewModel.isScanRunning { viewModel.cancelScan() }
        if finderViewModel.isRunning { finderViewModel.cancelFind() }
        if uninstallViewModel.isSweeping { uninstallViewModel.cancelSweep() }
    }
}

/// Puts the sidebar toggle where macOS users look for it: SwiftUI files it
/// under Help rather than View.
///
/// The empty-menu sweep is a net, not the fix. Measured with a probe that dumps
/// `NSApp.mainMenu`: removing an empty container works, and SwiftUI rebuilds it
/// on the next update pass, so nothing removed this way stays removed. An empty
/// menu is prevented by not replacing the command group that creates it — see
/// `menuCommands`.
@MainActor
public final class MenuBarTidy: NSObject, NSApplicationDelegate, NSMenuDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu?.delegate = self
        tidy()
    }

    public nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { tidy() }
    }

    private func tidy() {
        guard let main = NSApp.mainMenu else { return }
        // Cheap early exit: nothing to do unless a menu is empty.
        guard main.items.contains(where: { $0.submenu?.items.isEmpty ?? false }) else { return }

        if let help = main.items.first(where: { $0.title == "Help" })?.submenu,
            let toggle = help.items.first(where: { $0.title.contains("Sidebar") }),
            let view = main.items.first(where: { $0.title == "View" })?.submenu
        {
            help.removeItem(toggle)
            view.insertItem(toggle, at: 0)
        }

        for item in main.items where item.submenu?.items.isEmpty ?? false {
            main.removeItem(item)
        }
    }
}
