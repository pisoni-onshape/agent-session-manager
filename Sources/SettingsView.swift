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
                    Text("Newton repos path")
                        .font(.headline)
                    TextField("Newton repos path", text: $newtonReposRootPathDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .newtonReposRootPath)
                        .onSubmit(commitNewtonReposRootPath)
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

                Text("These options run the standard Refresh Sessions path while the app is open. The first-launch option applies only once per system boot, and subsequent launches are controlled separately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
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
