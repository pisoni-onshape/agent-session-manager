import AppKit
import SwiftUI
import AgentSessionManagerCore

struct ContentView: View {
    private let sessionListTopAnchorID = "session-list-top-anchor"

    @ObservedObject var viewModel: SessionBrowserViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var searchFieldController = ToolbarSearchFieldController()

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                ScrollViewReader { proxy in
                    List(selection: $viewModel.selectedSessionID) {
                        Color.clear
                            .frame(height: 1)
                            .id(sessionListTopAnchorID)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)

                        ForEach(viewModel.displayedSessionSections.starred) { session in
                            sessionListRow(for: session)
                        }

                        if viewModel.displayedSessionSections.showsUnstarredDivider {
                            SessionListDividerView()
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .allowsHitTesting(false)
                        }

                        ForEach(viewModel.displayedSessionSections.unstarred) { session in
                            sessionListRow(for: session)
                        }
                    }
                    .onChange(of: viewModel.filters) { _, _ in
                        scrollSessionListToTop(with: proxy)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .overlay {
                        if viewModel.shouldShowLoadingPlaceholder {
                            LoadingStateView(
                                title: viewModel.startupLoadingText,
                                detail: viewModel.startupLoadingDetailText
                            )
                        } else if viewModel.displayedSessions.isEmpty {
                            ContentUnavailableView(
                                viewModel.emptyStateTitle,
                                systemImage: viewModel.filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "tray" : "magnifyingglass",
                                description: Text(viewModel.emptyStateDescription)
                            )
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 340, ideal: 400)
        } detail: {
            if let session = viewModel.selectedSession {
                SessionDetailView(
                    session: session,
                    viewModel: viewModel,
                    isStarred: viewModel.isStarred(session),
                    onToggleStar: { viewModel.toggleStar(for: session) },
                    onOpenTranscript: { openTranscript(for: session) }
                )
                    .padding(24)
            } else if viewModel.shouldShowLoadingPlaceholder {
                LoadingStateView(
                    title: viewModel.startupLoadingText,
                    detail: viewModel.startupLoadingDetailText
                )
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
                HStack(spacing: 8) {
                    ToolbarSearchField(
                        text: $viewModel.filters.searchText,
                        placeholder: "Search sessions and transcripts (Cmd-K)",
                        controller: searchFieldController
                    )
                    .frame(width: 390)

                    SearchLabelHintMenu(
                        searchText: $viewModel.filters.searchText,
                        controller: searchFieldController
                    )
                }
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
                    if let refreshStatusText = viewModel.refreshStatusText {
                        ProgressView()
                            .controlSize(.small)
                        Text(refreshStatusText)
                            .font(.callout)
                        Text(viewModel.refreshDetailText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if !viewModel.hasCompletedInitialLoad {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading session index…")
                            .font(.callout)
                        Text("Preparing the local session catalog.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let transcriptLoadingStatusText = viewModel.transcriptLoadingStatusText {
                        ProgressView()
                            .controlSize(.small)
                        Text(transcriptLoadingStatusText)
                            .font(.callout)
                        if let transcriptLoadingDetailText = viewModel.transcriptLoadingDetailText {
                            Text(transcriptLoadingDetailText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 10) {
                            Text(viewModel.sessionCountSummary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let searchStatusText = viewModel.searchStatusText {
                                ProgressView()
                                    .controlSize(.small)
                                Text(searchStatusText)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if let lastRefreshDisplayText = viewModel.lastRefreshDisplayText {
                        Text(lastRefreshDisplayText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)
            }
        }
    }

    private func sessionListRow(for session: SessionRecord) -> some View {
        SessionRowView(
            session: session,
            isSelected: viewModel.selectedSessionID == session.id,
            isStarred: viewModel.isStarred(session),
            transcriptMatch: viewModel.searchMatch(for: session),
            onToggleStar: {
                viewModel.toggleStar(for: session)
            },
            onOpenTranscriptMatch: {
                openTranscript(for: session, initialSearchText: viewModel.transcriptViewerSearchText)
            }
        )
        .tag(session.id)
        .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func openTranscript(for record: SessionRecord, initialSearchText: String = "") {
        Task {
            guard let presentedTranscript = await viewModel.loadPresentedTranscript(
                for: record,
                initialSearchText: initialSearchText
            ) else {
                return
            }

            openWindow(value: presentedTranscript)
        }
    }

    private func scrollSessionListToTop(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(sessionListTopAnchorID, anchor: .top)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FilterMenuChip(
                    title: "Source",
                    valueText: viewModel.filters.selectedSource?.displayName ?? "All Sources",
                    systemImage: "line.3.horizontal.decrease.circle",
                    isActive: viewModel.filters.hasCustomSourceSelection,
                    items: [
                        FilterMenuItem(
                            id: SessionFilterState.allSourcesToken,
                            title: "All Sources",
                            isSelected: viewModel.filters.selectedSourceRawValue == SessionFilterState.allSourcesToken,
                            highlightsSelection: false,
                            action: { viewModel.filters.selectedSourceRawValue = SessionFilterState.allSourcesToken }
                        )
                    ] + SessionSource.allCases.map { source in
                        FilterMenuItem(
                            id: source.rawValue,
                            title: source.displayName,
                            isSelected: viewModel.filters.selectedSourceRawValue == source.rawValue,
                            highlightsSelection: true,
                            action: { viewModel.filters.selectedSourceRawValue = source.rawValue }
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Newton repos only", isOn: $viewModel.filters.newtonOnly)
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            FilterMenuChip(
                title: "Project",
                valueText: viewModel.filters.selectedProject == SessionFilterState.allProjectsToken ? "All Projects" : viewModel.filters.selectedProject,
                systemImage: "folder",
                isActive: viewModel.filters.hasCustomProjectSelection,
                prominence: .expanded,
                items: viewModel.availableProjects.map { project in
                    let isDefault = project == SessionFilterState.allProjectsToken
                    let title = isDefault ? "All Projects" : project
                    return FilterMenuItem(
                        id: project,
                        title: title,
                        isSelected: viewModel.filters.selectedProject == project,
                        highlightsSelection: !isDefault,
                        action: { viewModel.filters.selectedProject = project }
                    )
                }
            )

            FilterMenuChip(
                title: "Branch",
                valueText: viewModel.filters.selectedBranch == SessionFilterState.allBranchesToken ? "All Branches" : viewModel.filters.selectedBranch,
                systemImage: "arrow.triangle.branch",
                isActive: viewModel.filters.hasCustomBranchSelection,
                prominence: .expanded,
                items: viewModel.availableBranches.map { branch in
                    let isDefault = branch == SessionFilterState.allBranchesToken
                    let title = isDefault ? "All Branches" : branch
                    return FilterMenuItem(
                        id: branch,
                        title: title,
                        isSelected: viewModel.filters.selectedBranch == branch,
                        highlightsSelection: !isDefault,
                        action: { viewModel.filters.selectedBranch = branch }
                    )
                }
            )

            HStack(spacing: 10) {
                FilterMenuChip(
                    title: "Starred",
                    valueText: viewModel.filters.starFilter.displayName,
                    systemImage: "star",
                    isActive: viewModel.filters.hasCustomStarFilter,
                    items: SessionStarFilter.allCases.map { starFilter in
                        FilterMenuItem(
                            id: starFilter.rawValue,
                            title: starFilter.displayName,
                            isSelected: viewModel.filters.starFilter == starFilter,
                            highlightsSelection: starFilter != .all,
                            action: { viewModel.filters.starFilter = starFilter }
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                FilterMenuChip(
                    title: "Sort",
                    valueText: viewModel.filters.sortMode.displayName,
                    systemImage: "arrow.up.arrow.down",
                    isActive: viewModel.filters.hasCustomSortMode,
                    items: SessionSortMode.allCases.map { sortMode in
                        FilterMenuItem(
                            id: sortMode.rawValue,
                            title: sortMode.displayName,
                            isSelected: viewModel.filters.sortMode == sortMode,
                            highlightsSelection: sortMode != .recentlyUpdated,
                            action: { viewModel.filters.sortMode = sortMode }
                        )
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.bar)
    }
}

private struct SessionListDividerView: View {
    var body: some View {
        Divider()
        .padding(.vertical, 4)
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

private struct LoadingStateView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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

private struct SearchLabelHintMenu: View {
    @Binding var searchText: String
    let controller: ToolbarSearchFieldController

    var body: some View {
        Menu {
            Section("Field labels") {
                ForEach(searchLabels, id: \.label) { item in
                    Button {
                        insertToken(item.token)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                            Text(item.hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Examples") {
                ForEach(searchExamples, id: \.self) { example in
                    Button(example) {
                        searchText = example
                        controller.focus()
                    }
                }
            }
        } label: {
            Label("Labels", systemImage: "tag")
        }
        .help("Structured search labels")
    }

    private func insertToken(_ token: String) {
        let needsSpace = !searchText.isEmpty && !searchText.hasSuffix(" ")
        searchText += needsSpace ? " \(token)" : token
        controller.focus()
    }

    private var searchLabels: [(label: String, token: String, hint: String)] {
        [
            ("title:", "title:", "Match session titles"),
            ("project:", "project:", "Match project names"),
            ("branch:", "branch:", "Match git branches"),
            ("source:", "source:", "Match Copilot CLI, Cursor, or VS Code"),
            ("model:", "model:", "Match conversation models"),
            ("id:", "id:", "Match source session IDs"),
            ("transcript:", "transcript:", "Search transcript text only")
        ]
    }

    private var searchExamples: [String] {
        [
            #"project:"agent session manager" branch:main"#,
            #"title:"session index" source:copilot"#,
            #"model:gpt-5.4 id:abc-123"#,
            #"transcript:"drag bug" project:newton"#
        ]
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

/// Displays the session source with its official app icon (Cursor, VS Code) or SF Symbol fallback.
private struct SourceBadge: View {
    let source: SessionSource

    var body: some View {
        if let assetName = source.appIconAssetName {
            HStack(spacing: 4) {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text(source.displayName)
            }
        } else {
            Label(source.displayName, systemImage: source.systemImageName)
        }
    }
}

private struct SessionRowView: View {
    let session: SessionRecord
    let isSelected: Bool
    let isStarred: Bool
    let transcriptMatch: TranscriptSessionSearchMatch?
    let onToggleStar: () -> Void
    let onOpenTranscriptMatch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                SourceBadge(source: session.source)
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

            HStack(alignment: .top, spacing: 8) {
                SessionStarButton(
                    isStarred: isStarred,
                    size: 14,
                    action: onToggleStar
                )

                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
            }

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

            if let transcriptMatch {
                Button(action: onOpenTranscriptMatch) {
                    Label(transcriptMatchLabel(transcriptMatch.matchCount), systemImage: "text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                if let snippet = transcriptMatch.snippets.first {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let bestTimestamp = session.bestTimestamp {
                Text(bestTimestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 1.2 : 1
                )
        }
        .shadow(
            color: Color.black.opacity(isSelected ? 0.08 : 0.025),
            radius: isSelected ? 6 : 2,
            x: 0,
            y: 1
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func transcriptMatchLabel(_ count: Int) -> String {
        count == 1 ? "1 transcript match" : "\(count) transcript matches"
    }
}

private struct SessionDetailView: View {
    let session: SessionRecord
    @ObservedObject var viewModel: SessionBrowserViewModel
    let isStarred: Bool
    let onToggleStar: () -> Void
    let onOpenTranscript: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                metadataSection
                previewSection
                pathSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SessionStarButton(
                    isStarred: isStarred,
                    size: 22,
                    action: onToggleStar
                )
                .padding(.top, 5)

                VStack(alignment: .leading, spacing: 10) {
                    Text(session.title)
                        .font(.largeTitle.weight(.semibold))
                        .textSelection(.enabled)
                    Text(session.detailSummary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .overlay(Color.primary.opacity(0.08))

            actionBar
        }
        .padding(20)
        .detailSurfaceStyle(
            fill: Color.primary.opacity(0.035),
            stroke: Color.primary.opacity(0.06)
        )
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                primaryActionButtons
                Spacer(minLength: 0)
                utilityActionButtons
            }

            VStack(alignment: .leading, spacing: 14) {
                primaryActionButtons
                if showsUtilityActions {
                    utilityActionButtons
                }
            }
        }
    }

    private var primaryActionButtons: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.performPrimaryAction(for: session)
            } label: {
                Label(viewModel.primaryActionLabel(for: session), systemImage: primaryActionSystemImageName)
            }
            .buttonStyle(.borderedProminent)
            .help(primaryActionHelpText)

            if viewModel.canStartNewConversation(for: session) {
                Button {
                    viewModel.startNewConversation(for: session)
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
                .buttonStyle(.bordered)
                .help("Start a fresh Copilot CLI conversation in this project's workspace.")
            }

            Button {
                onOpenTranscript()
            } label: {
                Label("Transcript", systemImage: "text.bubble")
            }
            .buttonStyle(.bordered)
            .disabled(session.rawTranscriptPath == nil)
            .help("Open the transcript viewer for this session.")

            if session.relatedPlanPath != nil {
                Button {
                    viewModel.openPlan(for: session)
                } label: {
                    Label("Open Plan", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                .help("Open the related planning document for this session.")
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var utilityActionButtons: some View {
        if showsUtilityActions {
            HStack(spacing: 10) {
                if session.source == .copilotCLI {
                    Button {
                        viewModel.copyPrimaryCommand(session)
                    } label: {
                        Label("Copy Resume Command", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy the Copilot CLI resume command for this session.")
                }

                if canRevealRawFile {
                    Button {
                        viewModel.revealTranscript(for: session)
                    } label: {
                        Label("Reveal Raw File", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal the stored raw transcript or metadata file in Finder.")
                }
            }
            .controlSize(.regular)
        }
    }

    private var primaryActionSystemImageName: String {
        switch session.resumeKind {
        case .copilotConnect:
            return "play.circle"
        case .openInCursor:
            return "cursorarrow.rays"
        case .openInVSCode:
            return "chevron.left.forwardslash.chevron.right"
        case .revealPath:
            return "folder"
        }
    }

    private var primaryActionHelpText: String {
        switch session.resumeKind {
        case .copilotConnect:
            return "Resume this Copilot CLI conversation."
        case .openInCursor:
            return "Open this workspace in Cursor."
        case .openInVSCode:
            return "Open this workspace in VS Code."
        case .revealPath:
            return "Reveal the stored session files in Finder."
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Metadata")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                metadataRow(title: "Source", value: session.source.displayName, copyValue: nil, showsCopyButton: false)
                metadataRow(title: "Session ID", value: session.sourceSessionId, copyValue: session.sourceSessionId)
                metadataRow(title: "Project", value: session.projectName, copyValue: session.projectName)
                metadataRow(title: "Workspace", value: session.workspacePath ?? "—", copyValue: session.workspacePath)
                metadataRow(title: "Branch", value: session.branch ?? "—", copyValue: session.branch)
                metadataRow(title: "Model", value: session.conversationModel ?? "—", copyValue: nil, showsCopyButton: false)
                metadataRow(
                    title: "Started",
                    value: session.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                    copyValue: nil,
                    showsCopyButton: false
                )
                metadataRow(
                    title: "Updated",
                    value: session.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—",
                    copyValue: nil,
                    showsCopyButton: false
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .detailSurfaceStyle(
            fill: Color.secondary.opacity(0.055),
            stroke: Color.primary.opacity(0.05)
        )
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
    private func metadataRow(title: String, value: String, copyValue: String?, showsCopyButton: Bool = true) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if showsCopyButton {
                    CopyValueButton(
                        value: copyValue,
                        label: "Copy \(title)"
                    ) {
                        if let copyValue {
                            viewModel.copyToClipboard(copyValue)
                        }
                    }
                } else {
                    Color.clear
                        .frame(width: CopyValueButton.controlSize, height: CopyValueButton.controlSize)
                        .accessibilityHidden(true)
                }

                Text(value)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var canRevealRawFile: Bool {
        session.rawTranscriptPath != nil || session.rawMetadataPath != nil
    }

    private var showsUtilityActions: Bool {
        session.source == .copilotCLI || canRevealRawFile
    }
}

private extension View {
    func detailSurfaceStyle(fill: Color, stroke: Color) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
    }
}

private struct FilterMenuItem: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let highlightsSelection: Bool
    let action: () -> Void
}

private enum FilterMenuChipProminence {
    case compact
    case expanded
}

private struct FilterMenuChip: View {
    let title: String
    let valueText: String
    let systemImage: String
    let isActive: Bool
    var prominence: FilterMenuChipProminence = .compact
    let items: [FilterMenuItem]

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(action: item.action) {
                    HStack(spacing: 10) {
                        Text(item.title)
                            .foregroundStyle(item.isSelected && item.highlightsSelection ? Color.accentColor : Color.primary)

                        if item.isSelected {
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                                .foregroundStyle(item.highlightsSelection ? Color.accentColor : Color.secondary)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: prominence == .expanded ? 2 : 1) {
                    Text(valueText)
                        .font(valueFont)
                        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
            }
        }
        .menuStyle(.borderlessButton)
    }

    private var valueFont: Font {
        switch prominence {
        case .compact:
            return .callout.weight(.semibold)
        case .expanded:
            return .body.weight(.semibold)
        }
    }

    private var titleFont: Font {
        switch prominence {
        case .compact:
            return .caption2
        case .expanded:
            return .caption
        }
    }

    private var verticalPadding: CGFloat {
        switch prominence {
        case .compact:
            return 8
        case .expanded:
            return 10
        }
    }
}

private struct SessionStarButton: View {
    let isStarred: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isStarred ? "star.fill" : "star")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isStarred ? Color.yellow : Color.secondary)
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isStarred ? "Remove star" : "Star this session")
        .pointingHandCursor()
    }
}

private struct CopyValueButton: View {
    static let controlSize: CGFloat = 24

    let value: String?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(value == nil ? Color.secondary.opacity(0.6) : Color.accentColor)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
        .help(label)
        .pointingHandCursor()
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

struct TranscriptViewerView: View {
    let transcript: TranscriptDocument
    let initialSearchText: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String
    @State private var showInternalEvents = false

    init(transcript: TranscriptDocument, initialSearchText: String = "") {
        self.transcript = transcript
        self.initialSearchText = initialSearchText
        _searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let timestampNotice = transcript.timestampNotice {
                        Label(timestampNotice, systemImage: "clock.badge.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if transcript.entries.isEmpty {
                        ContentUnavailableView(
                            "Transcript Unavailable",
                            systemImage: "text.bubble",
                            description: Text("No readable conversation entries were found in this transcript.")
                        )
                    } else if searchResult.isActive, searchResult.displayItems.isEmpty {
                        ContentUnavailableView(
                            "No Matching Messages",
                            systemImage: "text.magnifyingglass",
                            description: Text("Only user and assistant messages are searched in this view.")
                        )
                    } else if displayedItems.isEmpty {
                        ContentUnavailableView(
                            "No Chat Messages",
                            systemImage: "text.bubble",
                            description: Text("Turn on Show internal events to inspect non-chat transcript items.")
                        )
                    } else {
                        TranscriptTimelineView(
                            items: displayedItems,
                            highlightQuery: searchResult.highlightQuery
                        )
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 920, minHeight: 720)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript")
                    .font(.title2.weight(.semibold))
                Text(transcript.sessionTitle)
                    .font(.title3)
                SourceBadge(source: transcript.source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(transcript.rawTranscriptPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Text(itemSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField("Search chat messages", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)

                    if !searchText.isEmpty {
                        Button("Clear") {
                            searchText = ""
                        }
                    }
                }

                Toggle("Show internal events", isOn: $showInternalEvents)
                    .toggleStyle(.checkbox)
                    .disabled(searchResult.isActive)

                HStack(spacing: 10) {
                    Button("Reveal Raw File") {
                        WorkspaceLauncher.reveal(path: transcript.rawTranscriptPath)
                    }

                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
    }

    private var searchResult: TranscriptViewerSearchResult {
        transcript.viewerSearchResult(for: searchText)
    }

    private var displayedItems: [TranscriptDisplayItem] {
        if searchResult.isActive {
            return searchResult.displayItems
        }
        return showInternalEvents ? transcript.displayItems : transcript.chatDisplayItems
    }

    private var itemSummary: String {
        if searchResult.isActive {
            let itemNoun = searchResult.matchingEntryCount == 1 ? "message" : "messages"
            let matchNoun = searchResult.totalMatchCount == 1 ? "match" : "matches"
            return "\(searchResult.totalMatchCount) \(matchNoun) in \(searchResult.matchingEntryCount) \(itemNoun)"
        }
        if showInternalEvents {
            return "\(transcript.entries.count) items"
        }
        let chatCount = transcript.chatDisplayItems.count
        let noun = chatCount == 1 ? "chat message" : "chat messages"
        return "\(chatCount) \(noun)"
    }
}

private struct TranscriptTimelineView: View {
    let items: [TranscriptDisplayItem]
    let highlightQuery: String?
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if shouldShowDateHeader(at: index) {
                    TranscriptDateHeader(date: item.timestamp!)
                }
                TranscriptTimelineItemView(item: item, highlightQuery: highlightQuery)
            }
        }
    }

    private func shouldShowDateHeader(at index: Int) -> Bool {
        guard let timestamp = items[index].timestamp else {
            return false
        }
        guard index > 0, let previousTimestamp = items[index - 1].timestamp else {
            return true
        }
        return !calendar.isDate(previousTimestamp, inSameDayAs: timestamp)
    }
}

private struct TranscriptDateHeader: View {
    let date: Date

    var body: some View {
        HStack {
            Text(date.formatted(date: .complete, time: .omitted))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
        }
        .padding(.vertical, 4)
    }
}

private struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    let highlightQuery: String?

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                chatCard
                    .frame(maxWidth: 700, alignment: .trailing)
            }
        case .assistant:
            HStack {
                chatCard
                    .frame(maxWidth: 700, alignment: .leading)
                Spacer(minLength: 80)
            }
        case .tool, .system:
            eventCard
        }
    }

    private var chatCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let timestamp = entry.timestamp {
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let body = entry.body {
                MarkdownTextBlock(text: body, highlightQuery: highlightQuery)
            }
        }
        .padding(16)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(entry.title, systemImage: entry.role == .tool ? "hammer" : "info.circle")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let timestamp = entry.timestamp {
                    Text(timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let body = entry.body {
                MarkdownTextBlock(text: body, highlightQuery: highlightQuery)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var backgroundColor: Color {
        switch entry.role {
        case .user:
            return Color.accentColor.opacity(0.14)
        case .assistant:
            return Color.green.opacity(0.12)
        case .tool, .system:
            return Color.secondary.opacity(0.08)
        }
    }
}

private struct TranscriptTimelineItemView: View {
    let item: TranscriptDisplayItem
    let highlightQuery: String?

    var body: some View {
        switch item {
        case let .entry(entry):
            TranscriptEntryView(entry: entry, highlightQuery: highlightQuery)
        case let .collapsedEvents(_, entries):
            CollapsedTranscriptEventsView(entries: entries)
        }
    }
}

private struct CollapsedTranscriptEventsView: View {
    let entries: [TranscriptEntry]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { entry in
                    TranscriptEntryView(entry: entry, highlightQuery: nil)
                }
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summaryTitle)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if let timeSummary {
                        Text(timeSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let summaryDetail {
                    Text(summaryDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var summaryTitle: String {
        let noun = entries.count == 1 ? "internal event" : "internal events"
        return "\(entries.count) \(noun)"
    }

    private var summaryDetail: String? {
        let previewTitles = entries.prefix(2).map(\.title)
        guard !previewTitles.isEmpty else { return nil }
        var components = previewTitles
        if entries.count > previewTitles.count {
            components.append("+\(entries.count - previewTitles.count) more")
        }
        return components.joined(separator: " • ")
    }

    private var timeSummary: String? {
        let timestamps = entries.compactMap(\.timestamp)
        guard let first = timestamps.first else { return nil }
        guard let last = timestamps.last, last != first else {
            return first.formatted(date: .omitted, time: .shortened)
        }
        return "\(first.formatted(date: .omitted, time: .shortened)) - \(last.formatted(date: .omitted, time: .shortened))"
    }
}

private struct MarkdownTextBlock: View {
    let text: String
    let highlightQuery: String?

    var body: some View {
        Group {
            if SearchTextMatcher.normalizedQuery(highlightQuery) != nil {
                Text(SearchTextMatcher.highlightedAttributedString(from: text, query: highlightQuery))
            } else if let attributedText = try? AttributedString(markdown: text) {
                Text(attributedText)
            } else {
                Text(text)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}
