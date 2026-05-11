import SwiftUI
import AgentSessionManagerCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @FocusState private var focusedField: Field?
    @State private var newtonReposRootPathDraft: String

    private enum Field: Hashable {
        case newtonReposRootPath
    }

    init(settings: AppSettingsStore) {
        self.settings = settings
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
                    "Defer scheduled refresh while the app is active",
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

                Text("These options run the standard Refresh Sessions path while the app is open. Timer intervals restart after the last completed refresh or timer change. If deferral is enabled, a scheduled refresh that becomes due while the app is active is held once and runs after the app next becomes inactive. The first-launch option applies only once per system boot, and subsequent launches are controlled separately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620, height: 570)
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
}
