import AppKit
import SwiftUI
import AgentSessionManagerCore

@main
struct AgentSessionManagerApp: App {
    @StateObject private var settings: AppSettingsStore
    @StateObject private var viewModel: SessionBrowserViewModel

    init() {
        let settings = AppSettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: SessionBrowserViewModel.makeDefault(settings: settings))
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
                .disabled(viewModel.isRefreshing)

                Divider()

                Button("Open Index Folder") {
                    WorkspaceLauncher.openDocument(path: AppPaths.catalogDirectoryURL.path)
                }

                Button("Rebuild Session Index") {
                    Task { await viewModel.rebuildSessions() }
                }
                .disabled(viewModel.isRefreshing)
            }

            CommandMenu("CLI") {
                Button("Install CLI to PATH") {
                    installCLIToPath()
                }
            }
        }
        WindowGroup("Transcript", for: PresentedTranscript.self) { presentedTranscript in
            if let presentedTranscript = presentedTranscript.wrappedValue {
                TranscriptViewerView(
                    transcript: presentedTranscript.transcript,
                    initialSearchText: presentedTranscript.initialSearchText
                )
            } else {
                ContentUnavailableView(
                    "No Transcript Selected",
                    systemImage: "text.bubble",
                    description: Text("Open a transcript from the main window to inspect it here.")
                )
                .frame(minWidth: 920, minHeight: 720)
            }
        }
        .defaultSize(width: 920, height: 720)
        WindowGroup("Plan", for: PresentedPlan.self) { presentedPlan in
            if let presentedPlan = presentedPlan.wrappedValue {
                PlanViewerView(
                    plan: presentedPlan.plan,
                    initialSearchText: presentedPlan.initialSearchText
                )
            } else {
                ContentUnavailableView(
                    "No Plan Selected",
                    systemImage: "doc.text",
                    description: Text("Open a plan from the main window to inspect it here.")
                )
                .frame(minWidth: 920, minHeight: 720)
            }
        }
        .defaultSize(width: 920, height: 720)
        Settings {
            SettingsView(settings: settings, viewModel: viewModel)
        }
    }

    private func installCLIToPath() {
        do {
            let result = try CLIPathInstaller.installForCurrentUser()
            presentAlert(
                title: "CLI Installed",
                message: result.successMessage,
                style: .informational
            )
        } catch {
            presentAlert(
                title: "CLI Installation Failed",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
