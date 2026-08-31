import AppKit
import SwiftUI
import DDCCCore

struct MainWindow: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(FinderViewModel.self) private var finderViewModel
    @Environment(UninstallViewModel.self) private var uninstallViewModel
    @State private var selectedResultID: UUID?
    @State private var selectedFoundFileID: UUID?
    @State private var selectedUninstallRowID: String?
    // Read once, at the moment the window is built, rather than every redraw:
    // accepting flips this to false and the sheet closes, and the stored
    // version is what decides on the next launch.
    @State private var needsAcceptance = FirstRunGate().needsAcceptance

    var body: some View {
        @Bindable var vm = viewModel
        @Bindable var fvm = finderViewModel
        @Bindable var uvm = uninstallViewModel

        VStack(spacing: 0) {
            if viewModel.showsDiskAccessBanner {
                DiskAccessBanner()
                Divider()
            }

            // The search field is routed by mode rather than shared: without
            // this, typing in Files mode silently rewrote the Caches filter
            // (both fields bound to the same AppViewModel.searchText) while
            // filtering nothing on screen, since FinderListView reads its
            // own view model's filteredFiles.
            Group {
                switch viewModel.mode {
                case .caches:
                    mainSplitView
                        .searchable(text: $vm.searchText, prompt: "Filter results...")
                case .files:
                    mainSplitView
                        .searchable(text: $fvm.searchText, prompt: "Filter files...")
                case .uninstall:
                    // Shipped without one, on the reasoning that the two
                    // identity sections plus dead artifacts already gave the
                    // list a structure to scan by eye. That holds for three
                    // sections and stops holding somewhere around the number
                    // of apps a real machine has. Routed by mode like the
                    // other two, so typing here cannot rewrite another view's
                    // filter — see the comment above.
                    mainSplitView
                        .searchable(text: $uvm.searchText, prompt: "Filter apps...")
                }
            }
            .toolbar {
                switch viewModel.mode {
                case .caches:
                    MainToolbar()
                case .files:
                    FinderToolbar()
                case .uninstall:
                    ToolbarItemGroup {}
                }
            }
            // The split view draws its column dividers full height, so the
            // content/detail divider ran up through the titlebar and straight
            // behind the sort control. An opaque toolbar gives it a surface to
            // stop against.
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        // First, and in front of everything: the app has not been used yet, so
        // there is nothing behind this sheet to lose by blocking it.
        .sheet(isPresented: $needsAcceptance) {
            FirstRunSheet(
                onAgree: {
                    FirstRunGate().accept()
                    needsAcceptance = false
                },
                // Terminate rather than dismiss. Declining the terms and then
                // being dropped into the app would make the question a
                // formality, and the record of acceptance worthless.
                //
                // `terminate(_:)` is a request, not an instruction: a delegate,
                // a modal session or an unbundled launch can all leave it
                // unanswered, and it was observed doing nothing at all when
                // called from this sheet. A Quit button that sometimes does
                // nothing is worse than no button, because the user reads it as
                // "declining is not allowed".
                //
                // So the request is made first — it runs the normal
                // termination path when it works — and a hard exit follows if
                // the process is somehow still alive. Safe *here* specifically:
                // this sheet is shown before the app has been used, so there is
                // no scan in flight, nothing selected and nothing to write out.
                // Do not copy this pattern to a Quit that can run later.
                onQuit: {
                    NSApplication.shared.terminate(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
                })
        }
        .sheet(isPresented: $vm.showDeleteConfirmation) {
            DeleteConfirmationSheet()
        }
        .sheet(item: $vm.pendingApproval) { prompt in
            ApprovalSheet(prompt: prompt)
        }
        .sheet(isPresented: Binding(
            get: { finderViewModel.showTrashConfirmation },
            set: { finderViewModel.showTrashConfirmation = $0 }
        )) {
            TrashConfirmationSheet()
        }
        .task { viewModel.refreshDiskAccess() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            viewModel.refreshDiskAccess()
        }
    }

    // Widths measured from the window layout the owner settled on
    // ( 1264pt wide): ~230 / ~680 / remainder. At SwiftUI's
    // defaults the list column was narrow enough to squeeze the Path
    // column out of the table entirely, leaving only icons and a size.
    // Ranges rather than fixed values so the dividers stay draggable.
    private var mainSplitView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            switch viewModel.mode {
            case .caches:
                ResultsListView(selectedResultID: $selectedResultID)
                    .navigationSplitViewColumnWidth(min: 480, ideal: 680, max: 900)
            case .files:
                FinderListView(selectedFileID: $selectedFoundFileID)
                    .navigationSplitViewColumnWidth(min: 480, ideal: 680, max: 900)
            case .uninstall:
                UninstallListView(selectedRowID: $selectedUninstallRowID)
                    .navigationSplitViewColumnWidth(min: 480, ideal: 680, max: 900)
            }
        } detail: {
            switch viewModel.mode {
            case .caches:
                // `visibleResult`, not `results.first` — the pane must answer
                // to the same collection the list renders, or it describes an
                // item the user cannot see. See `AppViewModel.visibleResult`.
                if let result = viewModel.visibleResult(id: selectedResultID) {
                    DetailView(result: result)
                } else {
                    ContentUnavailableView(
                        "Select an Item",
                        systemImage: "arrow.left.circle",
                        description: Text("Choose an item from the list to see details.")
                    )
                }
            case .files:
                if let file = finderViewModel.visibleFile(id: selectedFoundFileID) {
                    FinderDetailView(file: file)
                } else {
                    ContentUnavailableView(
                        "Select a File",
                        systemImage: "arrow.left.circle",
                        description: Text("Choose a file from the list to see details.")
                    )
                }
            case .uninstall:
                // Asked in turn, and a selection can answer to only one of
                // them — `UninstallDisplayRow.id` prefixes the two kinds
                // `app:` and `dead:`. See `selectedDeadArtifact`.
                if let footprint = uninstallViewModel.selectedFootprint {
                    UninstallDetailView(footprint: footprint)
                } else if let item = uninstallViewModel.selectedDeadArtifact {
                    DeadArtifactDetailView(item: item)
                } else {
                    ContentUnavailableView(
                        "Select an App",
                        systemImage: "arrow.left.circle",
                        description: Text("Choose an app from the list to see what it left behind.")
                    )
                }
            }
        }
    }
}
