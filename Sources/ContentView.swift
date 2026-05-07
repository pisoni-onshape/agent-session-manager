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
        .sheet(item: $viewModel.presentedTranscript) { transcript in
            TranscriptViewerSheet(transcript: transcript)
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

            Button("View Transcript") {
                viewModel.openTranscript(for: session)
            }
            .disabled(session.rawTranscriptPath == nil)

            if session.source == .copilotCLI {
                Button("Copy Resume Command") {
                    viewModel.copyPrimaryCommand(session)
                }
            }

            Button("Reveal Raw File") {
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

private struct TranscriptViewerSheet: View {
    let transcript: TranscriptDocument
    @Environment(\.dismiss) private var dismiss

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
                    } else {
                        TranscriptTimelineView(transcript: transcript)
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
                Label(transcript.source.displayName, systemImage: transcript.source.systemImageName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(transcript.rawTranscriptPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Text("\(transcript.entries.count) items")
                    .font(.callout)
                    .foregroundStyle(.secondary)

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
}

private struct TranscriptTimelineView: View {
    let transcript: TranscriptDocument
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(transcript.displayItems.enumerated()), id: \.element.id) { index, item in
                if shouldShowDateHeader(at: index) {
                    TranscriptDateHeader(date: item.timestamp!)
                }
                TranscriptTimelineItemView(item: item)
            }
        }
    }

    private func shouldShowDateHeader(at index: Int) -> Bool {
        guard let timestamp = transcript.displayItems[index].timestamp else {
            return false
        }
        guard index > 0, let previousTimestamp = transcript.displayItems[index - 1].timestamp else {
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
                MarkdownTextBlock(text: body)
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
                MarkdownTextBlock(text: body)
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

    var body: some View {
        switch item {
        case let .entry(entry):
            TranscriptEntryView(entry: entry)
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
                    TranscriptEntryView(entry: entry)
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

    var body: some View {
        Group {
            if let attributedText = try? AttributedString(markdown: text) {
                Text(attributedText)
            } else {
                Text(text)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
