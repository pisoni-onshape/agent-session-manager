import SwiftUI

@main
struct AgentSessionManagerApp: App {
    @StateObject private var viewModel: SessionBrowserViewModel

    init() {
        _viewModel = StateObject(wrappedValue: SessionBrowserViewModel.makeDefault())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1200, minHeight: 760)
                .task {
                    await viewModel.loadInitialData()
                }
        }
        .commands {
            CommandMenu("Catalog") {
                Button("Refresh Sessions") {
                    Task { await viewModel.refreshSessions() }
                }
                .keyboardShortcut("r")

                Divider()

                Button("Rebuild Session Index") {
                    Task { await viewModel.rebuildSessions() }
                }
            }
        }
    }
}
