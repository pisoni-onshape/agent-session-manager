import AppKit
import SwiftUI
import AgentSessionManagerCore

struct ContentView: View {
    private let sessionListTopAnchorID = "session-list-top-anchor"
    private let refreshButtonColor = Color(
        nsColor: NSColor(
            srgbRed: 0.30,
            green: 0.56,
            blue: 0.45,
            alpha: 1
        )
    )

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

                        ForEach(viewModel.displayedSessions) { session in
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
                    onOpenTranscript: { openTranscript(for: session) },
                    onOpenPlan: { openPlanViewer(for: session) }
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
            ZStack {
                SearchShortcutCaptureView {
                    searchFieldController.focus()
                }
                .frame(width: 0, height: 0)

                WindowFocusObserver { isFocused in
                    viewModel.setWindowIsFocused(isFocused)
                }
                .frame(width: 0, height: 0)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    ToolbarSearchField(
                        text: $viewModel.filters.searchText,
                        placeholder: "Search sessions, transcripts, and plans (Cmd-K)",
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
                    RefreshToolbarButtonLabel(
                        isRefreshing: viewModel.isRefreshing,
                        fillColor: refreshButtonColor
                    )
                }
                .buttonStyle(.plain)
                .opacity(viewModel.isRefreshing ? 0.8 : 1)
                .disabled(viewModel.isRefreshing)
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
        .onAppear {
            viewModel.setWindowIsFocused(NSApp.isActive && NSApp.keyWindow != nil)
            Task { await viewModel.reconcileAutoRefreshSchedule() }
        }
        .onChange(of: viewModel.selectedSessionID) { _, newID in
            if let newID {
                viewModel.checkInProgressState(for: newID)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await viewModel.reconcileAutoRefreshSchedule() }
        }
    }

    private func sessionListRow(for session: SessionRecord) -> some View {
        SessionRowView(
            session: session,
            isSelected: viewModel.selectedSessionID == session.id,
            isStarred: viewModel.isStarred(session),
            searchMatch: viewModel.searchMatch(for: session),
            onToggleStar: {
                viewModel.toggleStar(for: session)
            },
            onOpenTranscriptMatch: {
                openTranscript(for: session, initialSearchText: viewModel.transcriptViewerSearchText)
            },
            onOpenPlanMatch: {
                openPlanViewer(for: session, initialSearchText: viewModel.planViewerSearchText)
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

    private func openPlanViewer(for record: SessionRecord, initialSearchText: String = "") {
        Task {
            guard let presentedPlan = await viewModel.loadPresentedPlan(
                for: record,
                initialSearchText: initialSearchText
            ) else {
                return
            }

            openWindow(value: presentedPlan)
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

            HStack(spacing: 10) {
                SearchableFilterChip(
                    title: "Project",
                    valueText: viewModel.filters.selectedProject == SessionFilterState.allProjectsToken ? "All Projects" : viewModel.filters.selectedProject,
                    systemImage: "folder",
                    isActive: viewModel.filters.hasCustomProjectSelection,
                    prominence: .expanded,
                    items: viewModel.availableProjectOptions,
                    selectedItemID: viewModel.filters.selectedProject,
                    onSelect: { viewModel.filters.selectedProject = $0 }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("In-progress only", isOn: $viewModel.filters.inProgressOnly)
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            SearchableFilterChip(
                title: "Branch",
                valueText: viewModel.filters.selectedBranch == SessionFilterState.allBranchesToken ? "All Branches" : viewModel.filters.selectedBranch,
                systemImage: "arrow.triangle.branch",
                isActive: viewModel.filters.hasCustomBranchSelection,
                prominence: .expanded,
                items: viewModel.availableBranchOptions,
                selectedItemID: viewModel.filters.selectedBranch,
                onSelect: { viewModel.filters.selectedBranch = $0 }
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

private struct RefreshToolbarButtonLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let isRefreshing: Bool
    let fillColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
            Text(isRefreshing ? "Refreshing…" : "Refresh")
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(fillColor.opacity(isEnabled ? 1 : 0.75), in: Capsule())
        .overlay {
            Capsule()
                .fill(.white.opacity(isHovering && isEnabled ? 0.12 : 0))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    .white.opacity(isHovering && isEnabled ? 0.34 : 0.16),
                    lineWidth: 1
                )
        }
        .shadow(
            color: .black.opacity(isHovering && isEnabled ? 0.18 : 0.08),
            radius: isHovering && isEnabled ? 8 : 4,
            y: isHovering && isEnabled ? 3 : 1
        )
        .scaleEffect(isHovering && isEnabled ? 1.01 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .contentShape(Capsule())
        .onHover { isHovering = $0 }
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
            ("transcript:", "transcript:", "Search transcript text only"),
            ("plan:", "plan:", "Search plan text only")
        ]
    }

    private var searchExamples: [String] {
        [
            #"project:"agent session manager" branch:main"#,
            #"title:"session index" source:copilot"#,
            #"model:gpt-5.4 id:abc-123"#,
            #"transcript:"drag bug" project:newton"#,
            #"plan:"search service" source:copilot"#
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

private struct WindowFocusObserver: NSViewRepresentable {
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFocusChange: onFocusChange)
    }

    func makeNSView(context: Context) -> WindowFocusTrackingNSView {
        let view = WindowFocusTrackingNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowFocusTrackingNSView, context: Context) {
        context.coordinator.onFocusChange = onFocusChange
        nsView.coordinator = context.coordinator
        context.coordinator.observe(window: nsView.window)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onFocusChange: (Bool) -> Void

        private weak var observedWindow: NSWindow?
        private var lastFocusState: Bool?

        init(onFocusChange: @escaping (Bool) -> Void) {
            self.onFocusChange = onFocusChange
            super.init()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(handleStateChange), name: NSApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(handleStateChange), name: NSApplication.didResignActiveNotification, object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observe(window: NSWindow?) {
            guard observedWindow !== window else {
                publishFocusState()
                return
            }

            removeWindowObservers()
            observedWindow = window

            guard let window else {
                publishFocusState(window: nil)
                return
            }

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(handleStateChange), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(handleStateChange), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(handleStateChange), name: NSWindow.didMiniaturizeNotification, object: window)
            center.addObserver(self, selector: #selector(handleStateChange), name: NSWindow.didDeminiaturizeNotification, object: window)

            publishFocusState()
        }

        @objc
        private func handleStateChange(_ notification: Notification) {
            publishFocusState()
        }

        private func publishFocusState(window: NSWindow? = nil) {
            let isFocused = currentFocusState(window: window)
            guard lastFocusState != isFocused else { return }
            lastFocusState = isFocused
            onFocusChange(isFocused)
        }

        private func currentFocusState(window: NSWindow? = nil) -> Bool {
            guard let window = window ?? observedWindow else { return false }
            return NSApp.isActive && window.isVisible && !window.isMiniaturized && window.isKeyWindow
        }

        private func removeWindowObservers() {
            let center = NotificationCenter.default
            if let observedWindow {
                center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
                center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
                center.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: observedWindow)
                center.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: observedWindow)
            }
        }
    }
}

private final class WindowFocusTrackingNSView: NSView {
    weak var coordinator: WindowFocusObserver.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.observe(window: window)
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
    let searchMatch: SessionSearchMatch?
    let onToggleStar: () -> Void
    let onOpenTranscriptMatch: () -> Void
    let onOpenPlanMatch: () -> Void

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
                if session.isInProgress {
                    Text("In Progress")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12), in: Capsule())
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

            if let searchMatch {
                HStack(spacing: 8) {
                    if searchMatch.hasTranscriptMatches {
                        SearchMatchPillButton(
                            label: transcriptMatchLabel(searchMatch.transcriptMatchCount),
                            systemImage: "text.bubble",
                            tint: .blue,
                            action: onOpenTranscriptMatch
                        )
                    }
                    if searchMatch.hasPlanMatches {
                        SearchMatchPillButton(
                            label: planMatchLabel(searchMatch.planMatchCount),
                            systemImage: "doc.text",
                            tint: Color(red: 0.76, green: 0.91, blue: 0.78),
                            foreground: Color(red: 0.12, green: 0.36, blue: 0.18),
                            action: onOpenPlanMatch
                        )
                    }
                    Spacer(minLength: 0)
                }

                if let transcriptSnippet = searchMatch.transcriptSnippets.first {
                    Text(transcriptSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let planSnippet = searchMatch.planSnippets.first {
                    Text(planSnippet)
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
                .fill(isSelected ? Color.accentColor.opacity(0.12)
                      : session.isInProgress ? Color(red: 0.922, green: 0.906, blue: 0.890)
                      : Color.primary.opacity(0.035))
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

    private func planMatchLabel(_ count: Int) -> String {
        count == 1 ? "1 plan match" : "\(count) plan matches"
    }
}

private struct SearchMatchPillButton: View {
    let label: String
    let systemImage: String
    let tint: Color
    let foreground: Color
    let action: () -> Void

    init(
        label: String,
        systemImage: String,
        tint: Color,
        foreground: Color = .white,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.foreground = foreground
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint, in: Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(label)
    }
}

private struct PendingExclusionAction: Identifiable {
    let id = UUID()
    let exclusion: SessionCatalogExclusion
    let title: String
    let message: String
}

private struct SessionDetailView: View {
    let session: SessionRecord
    @ObservedObject var viewModel: SessionBrowserViewModel
    let isStarred: Bool
    let onToggleStar: () -> Void
    let onOpenTranscript: () -> Void
    let onOpenPlan: () -> Void

    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @State private var showInProgressResumeWarning = false
    @State private var pendingExclusion: PendingExclusionAction?
    @FocusState private var titleFieldFocused: Bool

    /// Font size for the editable title field. Shared with `titleEditLineHeight` so the height
    /// floor always tracks the applied font.
    private var titleEditFontSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
    }

    /// Canonical single-line height for the title edit font. Used as a `minHeight` floor on the
    /// plain `TextField`: the plain field's intrinsic height is occasionally measured from the
    /// default font before the largeTitle font propagates to the backing `NSTextField`, which
    /// vertically clips the text. The floor lifts only that rare short measurement; when the field
    /// measures correctly it already equals this height, so the floor is a no-op in the good case.
    private var titleEditLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: titleEditFontSize, weight: .semibold))
    }

    /// True when resuming this session would spawn a fresh terminal-based resume that could conflict
    /// with a still-live session. Applies to Copilot Connect and Claude CLI resumes; drives the orange
    /// primary-button tint and the "Session Currently Active" confirmation.
    private var warnsOnInProgressResume: Bool {
        session.isInProgress && (session.resumeKind == .copilotConnect || session.resumeKind == .claudeResume)
    }

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
        .alert(item: $pendingExclusion) { pendingExclusion in
            Alert(
                title: Text(pendingExclusion.title),
                message: Text(pendingExclusion.message),
                primaryButton: .destructive(Text("Exclude")) {
                    viewModel.exclude(pendingExclusion.exclusion)
                },
                secondaryButton: .cancel()
            )
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if isEditingTitle {
                            TextField("Session title", text: $editedTitle, onCommit: commitRename)
                                .textFieldStyle(.plain)
                                .font(.system(size: titleEditFontSize, weight: .semibold))
                                .frame(minHeight: titleEditLineHeight, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                                )
                                .focused($titleFieldFocused)
                                .onChange(of: editedTitle) { _, newValue in
                                    if newValue.count > 100 {
                                        editedTitle = String(newValue.prefix(100))
                                    }
                                }
                                .onExitCommand { cancelRename() }
                        } else {
                            Text(session.title)
                                .font(.system(size: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize, weight: .semibold))
                                .textSelection(.enabled)
                        }
                        if session.source.supportsRename && !isEditingTitle {
                            Button {
                                editedTitle = session.title
                                isEditingTitle = true
                                titleFieldFocused = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(session.isInProgress ? .tertiary : .secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(session.isInProgress)
                            .help(session.isInProgress ? "Editing title is disabled for in-progress sessions" : "Rename session")
                        }
                    }
                    if session.isInProgress {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            Text("This session is currently active in a terminal")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                    SelectableTextLabel(
                        text: session.detailSummary,
                        font: .preferredFont(forTextStyle: .body),
                        textColor: .secondaryLabelColor
                    )
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

    private func commitRename() {
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else {
            cancelRename()
            return
        }
        isEditingTitle = false
        Task { await viewModel.renameSession(session, to: trimmed) }
    }

    private func cancelRename() {
        isEditingTitle = false
        editedTitle = ""
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
                if warnsOnInProgressResume {
                    showInProgressResumeWarning = true
                } else {
                    viewModel.performPrimaryAction(for: session)
                }
            } label: {
                primaryActionLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(warnsOnInProgressResume ? .orange : nil)
            .help(primaryActionHelpText)
            .alert("Session Currently Active", isPresented: $showInProgressResumeWarning) {
                Button("Resume Anyway", role: .destructive) {
                    viewModel.performPrimaryAction(for: session)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This session is currently in use in a terminal. Resuming it from here may cause conflicts with the existing session.")
            }

            if viewModel.canStartNewConversation(for: session) {
                Button {
                    viewModel.startNewConversation(for: session)
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
                .buttonStyle(.bordered)
                .help("Start a fresh conversation in this project's workspace.")
            }

            if viewModel.canResumeInTerminal(for: session) {
                Button {
                    viewModel.resumeInTerminal(for: session)
                } label: {
                    Label("Resume in Terminal", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .help("Resume this conversation in a terminal via `claude --resume`.")
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
                    onOpenPlan()
                } label: {
                    Label("Open Plan", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                .help("Open the related planning document in the built-in plan viewer.")
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

                if session.source == .claudeCodeCLI {
                    Button {
                        viewModel.copyClaudeResumeCommand(session)
                    } label: {
                        Label("Copy Resume Command", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy the claude --resume command for this session.")
                }

                if viewModel.canCopyClaudeDesktopLink(for: session) {
                    Button {
                        viewModel.copyClaudeDesktopLink(for: session)
                    } label: {
                        Label("Copy Claude Desktop Link", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy a claude://resume link that reopens this session in the Claude Desktop app.")
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
        case .claudeResume:
            return "play.circle"
        case .resumeInClaudeDesktop:
            return "macwindow"
        }
    }

    private var primaryActionAppIconAssetName: String? {
        switch session.resumeKind {
        case .openInCursor:
            return "CursorIcon"
        case .openInVSCode:
            return "VSCodeIcon"
        case .copilotConnect, .revealPath, .claudeResume, .resumeInClaudeDesktop:
            return nil
        }
    }

    @ViewBuilder
    private var primaryActionLabel: some View {
        let text = viewModel.primaryActionLabel(for: session)
        if let assetName = primaryActionAppIconAssetName {
            HStack(spacing: 4) {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text(text)
            }
        } else {
            Label(text, systemImage: primaryActionSystemImageName)
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
        case .claudeResume:
            return "Resume this Claude Code conversation in Terminal."
        case .resumeInClaudeDesktop:
            return "Resume this conversation inside the Claude Desktop app."
        }
    }

    private var metadataSection: some View {
        let branchExcludeAction: (() -> Void)? = session.branch == nil ? nil : { queueBranchExclusion() }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Metadata")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                metadataRow(title: "Source", value: session.source.displayName, copyValue: nil, showsCopyButton: false)
                metadataRow(
                    title: "Session ID",
                    value: session.sourceSessionId,
                    copyValue: session.sourceSessionId,
                    excludeLabel: "Exclude this session",
                    excludeAction: { queueSessionExclusion() }
                )
                metadataRow(
                    title: "Project",
                    value: session.projectName,
                    copyValue: session.projectName,
                    excludeLabel: "Exclude this project",
                    excludeAction: { queueProjectExclusion() }
                )
                metadataRow(
                    title: "Workspace",
                    value: session.workspacePath ?? "—",
                    copyValue: session.workspacePath,
                    excludeLabel: "Exclude this project",
                    excludeAction: { queueProjectExclusion() }
                )
                metadataRow(
                    title: "Branch",
                    value: session.branch ?? "—",
                    copyValue: session.branch,
                    excludeLabel: session.branch == nil ? nil : "Exclude this branch",
                    excludeAction: branchExcludeAction
                )
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
                PreviewBlock(
                    title: "First User Prompt",
                    text: session.firstUserPreview
                )
                PreviewBlock(
                    title: "First Assistant Response",
                    text: session.firstAssistantPreview
                )
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

    private func metadataRow(
        title: String,
        value: String,
        copyValue: String?,
        showsCopyButton: Bool = true,
        excludeLabel: String? = nil,
        excludeAction: (() -> Void)? = nil
    ) -> AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 14) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)

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

                    if let excludeAction, let excludeLabel {
                        ExcludeValueButton(label: excludeLabel, action: excludeAction)
                    } else {
                        Color.clear
                            .frame(width: ExcludeValueButton.controlSize, height: ExcludeValueButton.controlSize)
                            .accessibilityHidden(true)
                    }

                    SelectableTextLabel(
                        text: value,
                        font: .preferredFont(forTextStyle: .body),
                        textColor: .labelColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        )
    }

    private func queueSessionExclusion() {
        let exclusion = SessionCatalogExclusion.session(session)
        pendingExclusion = PendingExclusionAction(
            exclusion: exclusion,
            title: "Exclude This Session?",
            message: "This removes only this session from Agent Session Manager. Files on disk stay untouched."
        )
    }

    private func queueProjectExclusion() {
        let exclusion = SessionCatalogExclusion.project(named: session.projectName)
        let affectedCount = viewModel.matchingSessionCount(for: exclusion)
        pendingExclusion = PendingExclusionAction(
            exclusion: exclusion,
            title: "Exclude This Project?",
            message: "This removes \(affectedCount) \(affectedCount == 1 ? "session" : "sessions") from Agent Session Manager and keeps the project hidden on future refreshes. Files on disk stay untouched."
        )
    }

    private func queueBranchExclusion() {
        guard let branch = session.branch else { return }
        let exclusion = SessionCatalogExclusion.branch(branch, inProject: session.projectName)
        let affectedCount = viewModel.matchingSessionCount(for: exclusion)
        pendingExclusion = PendingExclusionAction(
            exclusion: exclusion,
            title: "Exclude This Branch?",
            message: "This removes \(affectedCount) \(affectedCount == 1 ? "session" : "sessions") from the \(session.projectName) project inside Agent Session Manager and keeps that branch hidden on future refreshes. Files on disk stay untouched."
        )
    }

    private var canRevealRawFile: Bool {
        session.rawTranscriptPath != nil || session.rawMetadataPath != nil
    }

    private var showsUtilityActions: Bool {
        session.source == .copilotCLI || session.source == .claudeCodeCLI || canRevealRawFile
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

private struct SearchableFilterChip: View {
    let title: String
    let valueText: String
    let systemImage: String
    let isActive: Bool
    var prominence: FilterMenuChipProminence = .compact
    let items: [SessionFilterOption]
    let selectedItemID: String
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var query = ""
    @State private var highlightedItemID: String?
    @State private var highlightViaKeyboard = false

    var body: some View {
        Button {
            query = ""
            highlightedItemID = selectedItemID
            isPresented = true
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
        .buttonStyle(.plain)
        .pointingHandCursor()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                autocompleteField

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if filteredItems.isEmpty {
                                Text("No matching \(title.lowercased())")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 16)
                            } else {
                                ForEach(filteredItems) { item in
                                    optionButton(item)
                                        .id(item.id)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear {
                        resetHighlight()
                    }
                    .onChange(of: query) { _, _ in
                        resetHighlight()
                    }
                    .onChange(of: highlightedItemID) { _, newValue in
                        guard highlightViaKeyboard, let newValue else { return }
                        highlightViaKeyboard = false
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 340, height: 320)
        }
    }

    private var autocompleteField: some View {
        ZStack(alignment: .leading) {
            if let suffix = autocompleteSuffix {
                HStack(spacing: 0) {
                    Text(query)
                        .foregroundStyle(.clear)
                    Text(suffix)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
            }

            AutocompleteSearchField(
                text: $query,
                placeholder: "Search \(title.lowercased())",
                onMoveUp: { moveHighlight(by: -1) },
                onMoveDown: { moveHighlight(by: 1) },
                onConfirm: confirmSelection,
                onCancel: { isPresented = false }
            )
            .frame(height: 20)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55))
        }
    }

    private var filteredItems: [SessionFilterOption] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return items }

        let lowerQuery = normalizedQuery.lowercased()
        let matches = items.filter { $0.title.localizedCaseInsensitiveContains(normalizedQuery) }
        let prefixMatches = matches.filter { $0.title.lowercased().hasPrefix(lowerQuery) }
        let otherMatches = matches.filter { !$0.title.lowercased().hasPrefix(lowerQuery) }
        return prefixMatches + otherMatches
    }

    private var autocompleteSuffix: String? {
        guard !query.isEmpty,
              let predictedItem,
              predictedItem.title.lowercased().hasPrefix(query.lowercased()),
              predictedItem.title.count > query.count else {
            return nil
        }

        return String(predictedItem.title.dropFirst(query.count))
    }

    private var predictedItem: SessionFilterOption? {
        highlightedSelection ?? filteredItems.first
    }

    @ViewBuilder
    private func optionButton(_ item: SessionFilterOption) -> some View {
        Button {
            onSelect(item.id)
            query = ""
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .foregroundStyle(item.id == selectedItemID && item.id != items.first?.id ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.id != items.first?.id {
                        Text("\(item.count) \(item.count == 1 ? "session" : "sessions")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if item.id == items.first?.id {
                    Text("\(item.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if item.id == selectedItemID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(item.id == items.first?.id ? Color.secondary : Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        item.id == highlightedItemID
                            ? Color.accentColor.opacity(0.18)
                            : item.id == selectedItemID
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering in
            guard isHovering else { return }
            highlightViaKeyboard = false
            highlightedItemID = item.id
        }
    }

    private func moveHighlight(by offset: Int) {
        let selectableItems = filteredItems
        guard !selectableItems.isEmpty else { return }

        let currentIndex = highlightedItemID.flatMap { currentID in
            selectableItems.firstIndex(where: { $0.id == currentID })
        } ?? defaultHighlightIndex(in: selectableItems)

        let nextIndex = max(0, min(selectableItems.count - 1, currentIndex + offset))
        highlightViaKeyboard = true
        highlightedItemID = selectableItems[nextIndex].id
    }

    private func confirmSelection() {
        guard let item = highlightedSelection ?? predictedItem ?? filteredItems.first else {
            return
        }
        onSelect(item.id)
        query = ""
        isPresented = false
    }

    private var highlightedSelection: SessionFilterOption? {
        guard let highlightedItemID else { return nil }
        return filteredItems.first(where: { $0.id == highlightedItemID })
    }

    private func resetHighlight() {
        guard !filteredItems.isEmpty else {
            highlightedItemID = nil
            return
        }

        highlightViaKeyboard = true
        if filteredItems.contains(where: { $0.id == selectedItemID }) && query.isEmpty {
            highlightedItemID = selectedItemID
            return
        }

        highlightedItemID = filteredItems.first?.id
    }

    private func defaultHighlightIndex(in items: [SessionFilterOption]) -> Int {
        if query.isEmpty, let selectedIndex = items.firstIndex(where: { $0.id == selectedItemID }) {
            return selectedIndex
        }
        return 0
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

/// An AppKit-backed single-line text field used inside the searchable filter popovers.
/// Unlike a plain SwiftUI `TextField`, it auto-focuses when shown and intercepts the
/// arrow keys, Return, and Escape so the popover can drive keyboard navigation,
/// autocomplete confirmation, and dismissal.
private struct AutocompleteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .callout)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutocompleteSearchField

        init(_ parent: AutocompleteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onConfirm()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
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

private struct ExcludeValueButton: View {
    static let controlSize: CGFloat = 24

    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orange)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .pointingHandCursor()
    }
}

private struct SelectableTextLabel: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    var maximumNumberOfLines: Int = 0
    var lineBreakMode: NSLineBreakMode = .byWordWrapping

    func makeNSView(context: Context) -> WrappingSelectableTextField {
        let textField = WrappingSelectableTextField()
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = true
        textField.focusRingType = .none
        textField.usesSingleLineMode = maximumNumberOfLines == 1
        textField.allowsEditingTextAttributes = false
        textField.isAutomaticTextCompletionEnabled = false
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(textField)
        return textField
    }

    func updateNSView(_ nsView: WrappingSelectableTextField, context: Context) {
        update(nsView)
    }

    private func update(_ textField: WrappingSelectableTextField) {
        textField.stringValue = text
        textField.font = font
        textField.textColor = textColor
        textField.lineBreakMode = lineBreakMode
        textField.maximumNumberOfLines = maximumNumberOfLines
        textField.usesSingleLineMode = maximumNumberOfLines == 1
        if let cell = textField.cell as? NSTextFieldCell {
            cell.wraps = maximumNumberOfLines != 1
            cell.isScrollable = false
            cell.truncatesLastVisibleLine = maximumNumberOfLines == 1
            cell.lineBreakMode = lineBreakMode
        }
        textField.invalidateIntrinsicContentSize()
    }
}

private final class WrappingSelectableTextField: NSTextField {
    override var intrinsicContentSize: NSSize {
        guard let cell else { return super.intrinsicContentSize }

        let fittingWidth = max(bounds.width, 1)
        let fittingBounds = NSRect(x: 0, y: 0, width: fittingWidth, height: .greatestFiniteMagnitude)
        let size = cell.cellSize(forBounds: fittingBounds)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(size.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)
        if abs(previousWidth - newSize.width) > .ulpOfOne {
            invalidateIntrinsicContentSize()
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
            Group {
                if let text {
                    MarkdownTextBlock(text: text, highlightQuery: nil)
                } else {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
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
            SelectableTextLabel(
                text: value ?? "Unavailable",
                font: .preferredFont(forTextStyle: .body),
                textColor: value == nil ? .secondaryLabelColor : .labelColor
            )
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
    @State private var currentMatchIndex = 0
    @FocusState private var searchFocused: Bool

    init(transcript: TranscriptDocument, initialSearchText: String = "") {
        self.transcript = transcript
        self.initialSearchText = initialSearchText
        _searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
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
                        } else if displayedItems.isEmpty {
                            ContentUnavailableView(
                                "No Chat Messages",
                                systemImage: "text.bubble",
                                description: Text("Turn on Show internal events to inspect non-chat transcript items.")
                            )
                        } else {
                            TranscriptTimelineView(
                                items: displayedItems,
                                highlightQuery: searchResult.highlightQuery,
                                currentMatchEntryID: currentMatchEntryID
                            )
                        }
                    }
                    .padding(24)
                }
                .onAppear {
                    guard !matchingEntryIDs.isEmpty else { return }
                    DispatchQueue.main.async {
                        scrollToCurrentMatch(using: proxy)
                    }
                }
                .onChange(of: searchText) { _, _ in
                    currentMatchIndex = 0
                    scrollToCurrentMatch(using: proxy)
                }
                .onChange(of: currentMatchIndex) { _, _ in
                    scrollToCurrentMatch(using: proxy)
                }
            }
        }
        .frame(minWidth: 920, minHeight: 720)
    }

    private func scrollToCurrentMatch(using proxy: ScrollViewProxy) {
        guard let id = currentMatchEntryID else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript")
                    .font(.title2.weight(.semibold))
                SelectableTextLabel(
                    text: transcript.sessionTitle,
                    font: .preferredFont(forTextStyle: .title3),
                    textColor: .labelColor
                )
                SourceBadge(source: transcript.source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SelectableTextLabel(
                    text: transcript.rawTranscriptPath,
                    font: .preferredFont(forTextStyle: .caption1),
                    textColor: .secondaryLabelColor
                )
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Text(itemSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField("Search chat messages", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($searchFocused)
                        .onSubmit { goToNextMatch() }

                    if let positionLabel {
                        Text(positionLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 96, alignment: .trailing)
                    }

                    Button {
                        goToPreviousMatch()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(matchingEntryIDs.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Previous match")

                    Button {
                        goToNextMatch()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(matchingEntryIDs.isEmpty)
                    .keyboardShortcut("g", modifiers: .command)
                    .help("Next match")

                    Button {
                        searchText = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .disabled(searchText.isEmpty)
                    .help("Clear search")
                }

                Toggle("Show internal events", isOn: $showInternalEvents)
                    .toggleStyle(.checkbox)

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
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        )
    }

    private var searchResult: TranscriptViewerSearchResult {
        transcript.viewerSearchResult(for: searchText)
    }

    private var displayedItems: [TranscriptDisplayItem] {
        showInternalEvents ? transcript.displayItems : transcript.chatDisplayItems
    }

    private var matchingEntryIDs: [String] {
        searchResult.displayItems.map(\.id)
    }

    private var currentMatchEntryID: String? {
        let ids = matchingEntryIDs
        guard ids.indices.contains(currentMatchIndex) else { return nil }
        return ids[currentMatchIndex]
    }

    private var positionLabel: String? {
        guard searchResult.isActive else { return nil }
        let count = matchingEntryIDs.count
        guard count > 0 else { return "No results" }
        let position = min(currentMatchIndex, count - 1) + 1
        return "Message \(position) of \(count)"
    }

    private func goToNextMatch() {
        let count = matchingEntryIDs.count
        guard count > 0 else { return }
        currentMatchIndex = (currentMatchIndex + 1) % count
    }

    private func goToPreviousMatch() {
        let count = matchingEntryIDs.count
        guard count > 0 else { return }
        currentMatchIndex = (currentMatchIndex - 1 + count) % count
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

struct PlanViewerView: View {
    let plan: PlanDocument
    let initialSearchText: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String

    init(plan: PlanDocument, initialSearchText: String = "") {
        self.plan = plan
        self.initialSearchText = initialSearchText
        _searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if plan.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            "Plan Unavailable",
                            systemImage: "doc.text",
                            description: Text("No readable plan text was found in this file.")
                        )
                    } else if searchResult.isActive, searchResult.totalMatchCount == 0 {
                        ContentUnavailableView(
                            "No Matching Plan Text",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search term.")
                        )
                    } else {
                        MarkdownTextBlock(text: plan.text, highlightQuery: searchResult.highlightQuery)
                            .padding(20)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                Text("Plan")
                    .font(.title2.weight(.semibold))
                SelectableTextLabel(
                    text: plan.sessionTitle,
                    font: .preferredFont(forTextStyle: .title3),
                    textColor: .labelColor
                )
                SourceBadge(source: plan.source)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SelectableTextLabel(
                    text: plan.rawPlanPath,
                    font: .preferredFont(forTextStyle: .caption1),
                    textColor: .secondaryLabelColor
                )
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Text(itemSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField("Search plan text", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)

                    if !searchText.isEmpty {
                        Button("Clear") {
                            searchText = ""
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Reveal Raw File") {
                        WorkspaceLauncher.reveal(path: plan.rawPlanPath)
                    }

                    Button("Open in Default App") {
                        WorkspaceLauncher.openDocument(path: plan.rawPlanPath)
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

    private var searchResult: PlanViewerSearchResult {
        plan.viewerSearchResult(for: searchText)
    }

    private var itemSummary: String {
        if searchResult.isActive {
            let matchNoun = searchResult.totalMatchCount == 1 ? "match" : "matches"
            return "\(searchResult.totalMatchCount) \(matchNoun)"
        }

        let lineCount = plan.text.split(separator: "\n", omittingEmptySubsequences: false).count
        let noun = lineCount == 1 ? "line" : "lines"
        return "\(lineCount) \(noun)"
    }
}

private struct TranscriptTimelineView: View {
    let items: [TranscriptDisplayItem]
    let highlightQuery: String?
    let currentMatchEntryID: String?
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if shouldShowDateHeader(at: index) {
                    TranscriptDateHeader(date: item.timestamp!)
                }
                TranscriptTimelineItemView(
                    item: item,
                    highlightQuery: highlightQuery,
                    currentMatchEntryID: currentMatchEntryID
                )
                .id(item.id)
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
    var isCurrentMatch: Bool = false

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
                MarkdownTextBlock(text: body, highlightQuery: highlightQuery, isCurrentMatch: isCurrentMatch)
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
                MarkdownTextBlock(text: body, highlightQuery: highlightQuery, isCurrentMatch: isCurrentMatch)
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
    let currentMatchEntryID: String?

    var body: some View {
        switch item {
        case let .entry(entry):
            TranscriptEntryView(
                entry: entry,
                highlightQuery: highlightQuery,
                isCurrentMatch: entry.id == currentMatchEntryID
            )
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
    let highlightQuery: String?
    let isCurrentMatch: Bool
    private let rawText: String
    private let blocks: [MarkdownBlock]

    init(text: String, highlightQuery: String?, isCurrentMatch: Bool = false) {
        self.highlightQuery = highlightQuery
        self.isCurrentMatch = isCurrentMatch
        rawText = text
        blocks = MarkdownRendering.blocks(from: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if blocks.isEmpty {
                Text(MarkdownRendering.plainTextAttributedString(from: rawText, highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, highlightQuery: highlightQuery, isCurrentMatch: isCurrentMatch)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let highlightQuery: String?
    var isCurrentMatch: Bool = false

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownRendering.inlineAttributedString(from: text, highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
                .font(headingFont(for: level))
                .fontWeight(.semibold)
        case let .paragraph(text):
            Text(MarkdownRendering.inlineAttributedString(from: text, highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
                .font(.body)
        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\u{2022}")
                            .font(.body.weight(.semibold))
                        Text(MarkdownRendering.inlineAttributedString(from: item, highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body.weight(.semibold))
                        Text(MarkdownRendering.inlineAttributedString(from: item, highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case let .blockquote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 4)
                Text(MarkdownRendering.inlineAttributedString(from: text, highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        case let .codeBlock(text):
            ScrollView(.horizontal) {
                Text(MarkdownRendering.plainTextAttributedString(from: text, highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case let .table(rows):
            ScrollView(.horizontal) {
                Text(MarkdownRendering.plainTextAttributedString(from: rows.joined(separator: "\n"), highlightQuery: highlightQuery, isCurrent: isCurrentMatch))
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return .title
        case 2:
            return .title2
        case 3:
            return .title3
        case 4:
            return .headline
        case 5:
            return .subheadline
        default:
            return .body
        }
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
