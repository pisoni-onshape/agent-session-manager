import SwiftUI
import AgentSessionManagerCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var viewModel: SessionBrowserViewModel
    @FocusState private var focusedField: Field?
    @State private var newtonReposRootPathDraft: String
    @State private var exclusionSearchText = ""

    private enum Field: Hashable {
        case newtonReposRootPath
    }

    init(settings: AppSettingsStore, viewModel: SessionBrowserViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        _newtonReposRootPathDraft = State(initialValue: settings.newtonReposRootPath)
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { settings.launchAtLoginEnabled },
                        set: { settings.setLaunchAtLoginEnabled($0) }
                    )
                )

                if let launchAtLoginStatusDetail = settings.launchAtLoginStatusDetail {
                    Text(launchAtLoginStatusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let launchAtLoginErrorMessage = settings.launchAtLoginErrorMessage {
                    Text(launchAtLoginErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Session Catalog") {
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
                            .frame(minWidth: 390)
                    }

                    Text("Only repos directly under this root whose names start with `newton` are included by the Newton-only filter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .padding(.vertical, 4)

                    Text("Exclusions")
                        .font(.headline)

                    TextField("Search excluded sessions, projects, and branches", text: $exclusionSearchText)
                        .textFieldStyle(.roundedBorder)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ExclusionListGroup(
                                title: "Sessions",
                                exclusions: filteredExclusions(viewModel.sessionExclusions),
                                emptyText: "No excluded sessions.",
                                onRestore: viewModel.restoreExclusion
                            )
                            ExclusionListGroup(
                                title: "Projects",
                                exclusions: filteredExclusions(viewModel.projectExclusions),
                                emptyText: "No excluded projects.",
                                onRestore: viewModel.restoreExclusion
                            )
                            ExclusionListGroup(
                                title: "Branches",
                                exclusions: filteredExclusions(viewModel.branchExclusions),
                                emptyText: "No excluded branches.",
                                onRestore: viewModel.restoreExclusion
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 250)

                    Text("Re-including an item restores it on the next refresh. Excluding only affects Agent Session Manager - it never deletes files from disk.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Auto Session Refresh") {
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
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 720, height: 760)
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

    private func commitNewtonReposRootPath() {
        settings.setNewtonReposRootPath(newtonReposRootPathDraft)
        newtonReposRootPathDraft = settings.newtonReposRootPath
    }

    private func filteredExclusions(_ exclusions: [SessionCatalogExclusion]) -> [SessionCatalogExclusion] {
        let query = exclusionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return exclusions }

        return exclusions.filter { exclusion in
            exclusion.displayTitle.localizedCaseInsensitiveContains(query)
                || exclusion.detailText.localizedCaseInsensitiveContains(query)
                || exclusion.kind.displayName.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct ExclusionListGroup: View {
    let title: String
    let exclusions: [SessionCatalogExclusion]
    let emptyText: String
    let onRestore: (SessionCatalogExclusion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if exclusions.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(exclusions) { exclusion in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exclusion.displayTitle)
                                .font(.callout.weight(.semibold))
                            Text(exclusion.detailText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button("Re-include") {
                            onRestore(exclusion)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
            }
        }
    }
}
