import SwiftUI
import AgentSessionManagerCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case sessionCatalog
    case catalogItems
    case autoRefresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .sessionCatalog:
            return "Session Catalog"
        case .catalogItems:
            return "Indexes"
        case .autoRefresh:
            return "Auto Refresh"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .sessionCatalog:
            return "externaldrive"
        case .catalogItems:
            return "square.stack.3d.up"
        case .autoRefresh:
            return "arrow.clockwise"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var viewModel: SessionBrowserViewModel

    @FocusState private var focusedField: Field?
    @State private var selectedPage: SettingsPage = .general
    @State private var newtonReposRootPathDraft: String

    private enum Field: Hashable {
        case newtonReposRootPath
    }

    init(settings: AppSettingsStore, viewModel: SessionBrowserViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        _newtonReposRootPathDraft = State(initialValue: settings.newtonReposRootPath)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                Label(page.title, systemImage: page.systemImage)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 190, idealWidth: 200, maxWidth: 220)

            Divider()

            ScrollView {
                currentPage
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 920, height: 760)
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue != .newtonReposRootPath {
                commitNewtonReposRootPath()
            }
        }
        .onChange(of: settings.newtonReposRootPath) { _, newValue in
            if newtonReposRootPathDraft != newValue {
                newtonReposRootPathDraft = newValue
            }
        }
        .onDisappear(perform: commitNewtonReposRootPath)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch selectedPage {
        case .general:
            generalPage
        case .sessionCatalog:
            sessionCatalogPage
        case .catalogItems:
            CatalogItemsManagementPage(viewModel: viewModel)
        case .autoRefresh:
            autoRefreshPage
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader(
                title: "General",
                subtitle: "Configure app-wide behavior for launch and startup."
            )

            settingsCard {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { settings.launchAtLoginEnabled },
                        set: { settings.setLaunchAtLoginEnabled($0) }
                    )
                )

                if let detail = settings.launchAtLoginStatusDetail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let error = settings.launchAtLoginErrorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var sessionCatalogPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader(
                title: "Session Catalog",
                subtitle: "Adjust how Newton workspace metadata is interpreted for cataloging."
            )

            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Newton repos path") {
                        TextField(
                            "",
                            text: $newtonReposRootPathDraft,
                            prompt: Text("/Users/you/repos")
                                .foregroundStyle(.secondary)
                        )
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.22))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18))
                        )
                        .focused($focusedField, equals: .newtonReposRootPath)
                        .onSubmit(commitNewtonReposRootPath)
                        .frame(minWidth: 420)
                    }

                    Text("Only repos directly under this root whose names start with `newton` are included by the Newton-only filter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var autoRefreshPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader(
                title: "Auto Refresh",
                subtitle: "Control when the catalog refreshes while the app is open."
            )

            settingsCard {
                Picker(
                    "Refresh on a timer",
                    selection: Binding(
                        get: { settings.autoRefreshCadence },
                        set: { settings.setAutoRefreshCadence($0) }
                    )
                ) {
                    ForEach(AutoRefreshCadence.allCases) { cadence in
                        Text(cadence.displayName).tag(cadence)
                    }
                }
                .pickerStyle(.menu)

                Toggle(
                    "Defer scheduled refresh while an app window is focused",
                    isOn: Binding(
                        get: { settings.deferRefreshWhileAppIsActive },
                        set: { settings.setDeferRefreshWhileAppIsActive($0) }
                    )
                )
                .disabled(settings.autoRefreshCadence == .off)

                Toggle(
                    "Refresh on first launch after system startup",
                    isOn: Binding(
                        get: { settings.refreshOnFirstLaunchAfterBoot },
                        set: { settings.setRefreshOnFirstLaunchAfterBoot($0) }
                    )
                )

                Toggle(
                    "Refresh on subsequent launches",
                    isOn: Binding(
                        get: { settings.refreshOnSubsequentLaunches },
                        set: { settings.setRefreshOnSubsequentLaunches($0) }
                    )
                )

                Text("These options run the standard Refresh Sessions path while the app is open. Timer intervals restart after the last completed refresh or timer change. If deferral is enabled, a scheduled refresh that becomes due while an app window is focused is held once and runs after the app next loses focus. If the Mac sleeps past a scheduled time, the app reconciles the missed refresh after wake. The first-launch option applies only once per system boot, and subsequent launches are controlled separately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commitNewtonReposRootPath() {
        settings.setNewtonReposRootPath(newtonReposRootPathDraft)
        newtonReposRootPathDraft = settings.newtonReposRootPath
    }

    @ViewBuilder
    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CatalogItemsManagementPage: View {
    @ObservedObject var viewModel: SessionBrowserViewModel

    @State private var selectedScope: CatalogManagementScope = .projects
    @State private var projectSearchText = ""
    @State private var branchSearchText = ""
    @State private var sessionSearchText = ""
    @State private var selectedProjectIDs: Set<String> = []
    @State private var selectedBranchIDs: Set<String> = []
    @State private var selectedSessionIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Indexes")
                    .font(.title2.weight(.semibold))
                Text("Manage indexed and excluded projects, branches, and sessions using the already-loaded catalog state.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            settingsCard {
                Picker("Scope", selection: $selectedScope) {
                    ForEach(CatalogManagementScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                TextField(searchPlaceholder, text: searchTextBinding)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if filteredItems.isEmpty {
                            Text("No matching \(selectedScope.title.lowercased()).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(filteredItems) { item in
                                CatalogManagementRow(
                                    item: item,
                                    isSelected: selectionBinding(for: item).wrappedValue,
                                    onToggleSelected: { isSelected in
                                        selectionBinding(for: item).wrappedValue = isSelected
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(minHeight: 360)

                HStack {
                    Text(summaryText)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Clear Selection") {
                        clearSelection(for: selectedScope)
                    }
                    .buttonStyle(.bordered)
                    .disabled(currentSelection.isEmpty)

                    Button("Include Selected") {
                        viewModel.includeCatalogItems(selectedItems)
                        clearSelection(for: selectedScope)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!selectedItems.contains(where: { $0.state == .excluded }))

                    Button("Exclude Selected") {
                        viewModel.excludeCatalogItems(selectedItems)
                        clearSelection(for: selectedScope)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!selectedItems.contains(where: { $0.state == .included }))
                }
            }
        }
    }

    private var searchPlaceholder: String {
        "Search \(selectedScope.title.lowercased())"
    }

    private var searchTextBinding: Binding<String> {
        switch selectedScope {
        case .projects:
            return $projectSearchText
        case .branches:
            return $branchSearchText
        case .sessions:
            return $sessionSearchText
        }
    }

    private var currentSearchText: String {
        searchTextBinding.wrappedValue
    }

    private var currentSelection: Set<String> {
        switch selectedScope {
        case .projects:
            return selectedProjectIDs
        case .branches:
            return selectedBranchIDs
        case .sessions:
            return selectedSessionIDs
        }
    }

    private var filteredItems: [CatalogManagementItem] {
        let query = currentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = viewModel.catalogItems(for: selectedScope)
        guard !query.isEmpty else { return items }

        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
                || item.state.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedItems: [CatalogManagementItem] {
        let selectedIDs = currentSelection
        return viewModel.catalogItems(for: selectedScope).filter { selectedIDs.contains($0.id) }
    }

    private var summaryText: String {
        let total = filteredItems.count
        let selected = currentSelection.count
        return selected == 0
            ? "\(total) \(selectedScope.title.lowercased()) shown"
            : "\(selected) selected - \(total) \(selectedScope.title.lowercased()) shown"
    }

    private func selectionBinding(for item: CatalogManagementItem) -> Binding<Bool> {
        switch selectedScope {
        case .projects:
            return Binding(
                get: { selectedProjectIDs.contains(item.id) },
                set: { isSelected in
                    if isSelected {
                        selectedProjectIDs.insert(item.id)
                    } else {
                        selectedProjectIDs.remove(item.id)
                    }
                }
            )
        case .branches:
            return Binding(
                get: { selectedBranchIDs.contains(item.id) },
                set: { isSelected in
                    if isSelected {
                        selectedBranchIDs.insert(item.id)
                    } else {
                        selectedBranchIDs.remove(item.id)
                    }
                }
            )
        case .sessions:
            return Binding(
                get: { selectedSessionIDs.contains(item.id) },
                set: { isSelected in
                    if isSelected {
                        selectedSessionIDs.insert(item.id)
                    } else {
                        selectedSessionIDs.remove(item.id)
                    }
                }
            )
        }
    }

    private func clearSelection(for scope: CatalogManagementScope) {
        switch scope {
        case .projects:
            selectedProjectIDs.removeAll()
        case .branches:
            selectedBranchIDs.removeAll()
        case .sessions:
            selectedSessionIDs.removeAll()
        }
    }
}

private struct CatalogManagementRow: View {
    let item: CatalogManagementItem
    let isSelected: Bool
    let onToggleSelected: (Bool) -> Void

    var body: some View {
        Button {
            onToggleSelected(!isSelected)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(item.state.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.state == .excluded ? Color.orange : Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(item.state == .excluded ? Color.orange.opacity(0.16) : Color.accentColor.opacity(0.14))
                            )

                        if let count = item.count {
                            Text("\(count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.12))
                                )
                        }
                    }

                    Text(item.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }
}

@MainActor
private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    SettingsCard {
        content()
    }
}
