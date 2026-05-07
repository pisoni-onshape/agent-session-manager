import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: SessionBrowserViewModel
    @StateObject private var searchFieldController = ToolbarSearchFieldController()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                List(viewModel.displayedSessions, selection: $viewModel.selectedSessionID) { session in
                    SessionRowView(session: session)
                        .tag(session.id)
                }
                .overlay {
                    if viewModel.displayedSessions.isEmpty {
                        ContentUnavailableView(
                            "No Sessions Found",
                            systemImage: "tray",
                            description: Text("Adjust the filters or refresh the local index.")
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 340, ideal: 400)
        } detail: {
            if let session = viewModel.selectedSession {
                SessionDetailView(session: session, viewModel: viewModel)
                    .padding(24)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "sidebar.left",
                    description: Text("Choose a session from the list to inspect its details.")
                )
            }
        }
        .background {
            SearchShortcutCaptureView {
                searchFieldController.focus()
            }
            .frame(width: 0, height: 0)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarSearchField(
                    text: $viewModel.filters.searchText,
                    placeholder: "Search title, project, branch, preview (Cmd-K)",
                    controller: searchFieldController
                )
                .frame(width: 420)
            }

            ToolbarItemGroup {
                Button {
                    Task { await viewModel.refreshSessions() }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRefreshing)

                if let lastRefreshDisplayText = viewModel.lastRefreshDisplayText {
                    Text(lastRefreshDisplayText)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("Index refresh recommended", isPresented: $viewModel.showStaleRefreshPrompt) {
            Button("No", role: .cancel) {}
            Button("Yes") {
                Task { await viewModel.refreshSessions() }
            }
        } message: {
            Text(viewModel.staleRefreshPromptMessage)
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
            } else {
                HStack {
                    Text(viewModel.sessionCountSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Source", selection: $viewModel.filters.selectedSourceRawValue) {
                    Text("All Sources").tag(SessionFilterState.allSourcesToken)
                    ForEach(SessionSource.allCases) { source in
                        Text(source.displayName).tag(source.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Picker("Project", selection: $viewModel.filters.selectedProject) {
                    Text("All Projects").tag(SessionFilterState.allProjectsToken)
                    ForEach(viewModel.availableProjects.dropFirst(), id: \.self) { project in
                        Text(project).tag(project)
                    }
                }
                .pickerStyle(.menu)

                Picker("Branch", selection: $viewModel.filters.selectedBranch) {
                    Text("All Branches").tag(SessionFilterState.allBranchesToken)
                    ForEach(viewModel.availableBranches.dropFirst(), id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Toggle("newton* only", isOn: $viewModel.filters.newtonOnly)
                    .toggleStyle(.switch)

                Spacer()

                Picker("Sort", selection: $viewModel.filters.sortMode) {
                    ForEach(SessionSortMode.allCases) { sortMode in
                        Text(sortMode.displayName).tag(sortMode)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(16)
        .background(.bar)
    }
}

private final class ToolbarSearchFieldController: ObservableObject {
    weak var searchField: NSSearchField?

    func focus() {
        guard let searchField else { return }
        DispatchQueue.main.async {
            searchField.window?.makeFirstResponder(searchField)
        }
    }
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let controller: ToolbarSearchFieldController

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.sendsSearchStringImmediately = true
        controller.searchField = searchField
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        controller.searchField = nsView
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }
    }
}

private struct SearchShortcutCaptureView: NSViewRepresentable {
    let onFocusSearch: () -> Void

    func makeNSView(context: Context) -> SearchShortcutNSView {
        let view = SearchShortcutNSView()
        view.onFocusSearch = onFocusSearch
        return view
    }

    func updateNSView(_ nsView: SearchShortcutNSView, context: Context) {
        nsView.onFocusSearch = onFocusSearch
    }
}

private final class SearchShortcutNSView: NSView {
    var onFocusSearch: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "k" {
            onFocusSearch?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

private struct SessionRowView: View {
    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(session.source.displayName, systemImage: session.source.systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isNewtonProject {
                    Text("newton")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
            }

            Text(session.title)
                .font(.headline)
                .lineLimit(2)

            if !session.subtitle.isEmpty {
                Text(session.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(session.detailSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let bestTimestamp = session.bestTimestamp {
                Text(bestTimestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SessionDetailView: View {
    let session: SessionRecord
    @ObservedObject var viewModel: SessionBrowserViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.title)
                        .font(.largeTitle.weight(.semibold))
                    Text(session.detailSummary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                actionBar
                metadataSection
                previewSection
                pathSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(viewModel.primaryActionLabel(for: session)) {
                viewModel.performPrimaryAction(for: session)
            }
            .buttonStyle(.borderedProminent)

            Button("Copy Session ID") {
                viewModel.copySessionID(session)
            }

            if session.relatedPlanPath != nil {
                Button("Open Plan") {
                    viewModel.openPlan(for: session)
                }
            }

            if session.source == .copilotCLI {
                Button("Copy Resume Command") {
                    viewModel.copyPrimaryCommand(session)
                }
            }

            Button("Reveal Transcript") {
                viewModel.revealTranscript(for: session)
            }
            .disabled(session.rawTranscriptPath == nil && session.rawMetadataPath == nil)
        }
    }

    private var metadataSection: some View {
        GroupBox("Metadata") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                metadataRow(title: "Source", value: session.source.displayName)
                metadataRow(title: "Session ID", value: session.sourceSessionId)
                metadataRow(title: "Project", value: session.projectName)
                metadataRow(title: "Branch", value: session.branch ?? "—")
                metadataRow(title: "Model", value: session.conversationModel ?? "—")
                metadataRow(title: "Started", value: session.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                metadataRow(title: "Updated", value: session.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                metadataRow(title: "Newton Project", value: session.isNewtonProject ? "Yes" : "No")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var previewSection: some View {
        GroupBox("Early Conversation") {
            VStack(alignment: .leading, spacing: 16) {
                PreviewBlock(title: "First User Prompt", text: session.firstUserPreview)
                PreviewBlock(title: "First Assistant Response", text: session.firstAssistantPreview)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pathSection: some View {
        GroupBox("Paths") {
            VStack(alignment: .leading, spacing: 12) {
                PathRow(label: "Workspace", value: session.workspacePath)
                PathRow(label: "Transcript", value: session.rawTranscriptPath)
                PathRow(label: "Metadata", value: session.rawMetadataPath)
                PathRow(label: "Plan", value: session.relatedPlanPath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metadataRow(title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PreviewBlock: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text ?? "Unavailable")
                .textSelection(.enabled)
                .foregroundStyle(text == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct PathRow: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.headline)
            Text(value ?? "Unavailable")
                .textSelection(.enabled)
                .foregroundStyle(value == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
