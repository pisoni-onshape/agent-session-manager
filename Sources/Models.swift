import Foundation

enum SessionSource: String, CaseIterable, Codable, Identifiable {
    case copilotCLI = "copilot-cli"
    case cursor
    case vscodeCopilot = "vscode-copilot"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copilotCLI:
            return "Copilot CLI"
        case .cursor:
            return "Cursor"
        case .vscodeCopilot:
            return "VS Code Copilot"
        }
    }

    var systemImageName: String {
        switch self {
        case .copilotCLI:
            return "terminal"
        case .cursor:
            return "cursorarrow.rays"
        case .vscodeCopilot:
            return "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum ResumeActionKind: String, Codable {
    case copilotConnect
    case openInCursor
    case openInVSCode
    case revealPath
}

enum SessionSortMode: String, CaseIterable, Identifiable {
    case recentlyUpdated
    case startedAt
    case project
    case source
    case title

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyUpdated:
            return "Recently Updated"
        case .startedAt:
            return "Started Time"
        case .project:
            return "Project"
        case .source:
            return "Source"
        case .title:
            return "Title"
        }
    }
}

struct SessionRecord: Identifiable, Equatable {
    let source: SessionSource
    let sourceSessionId: String
    let workspacePath: String?
    let projectName: String
    let branch: String?
    let conversationModel: String?
    let startedAt: Date?
    let updatedAt: Date?
    let title: String
    let summary: String?
    let firstUserPreview: String?
    let firstAssistantPreview: String?
    let rawTranscriptPath: String?
    let rawMetadataPath: String?
    let relatedPlanPath: String?
    let resumeKind: ResumeActionKind
    let resumePayload: String
    let isNewtonProject: Bool

    var id: String {
        "\(source.rawValue)::\(sourceSessionId)"
    }

    var subtitle: String {
        [projectName, branch].compactMap { $0 }.joined(separator: " • ")
    }

    var bestTimestamp: Date? {
        updatedAt ?? startedAt
    }

    var detailSummary: String {
        summary ?? firstAssistantPreview ?? firstUserPreview ?? "No preview available."
    }
}

struct TranscriptPreview {
    var sessionId: String?
    var startedAt: Date?
    var latestModel: String?
    var firstUser: String?
    var firstAssistant: String?

    var summary: String? {
        TextSanitizer.summarize(firstAssistant ?? firstUser)
    }
}

struct SessionFilterState {
    static let allProjectsToken = "__all_projects__"
    static let allBranchesToken = "__all_branches__"
    static let allSourcesToken = "__all_sources__"

    var searchText = ""
    var selectedSourceRawValue = allSourcesToken
    var selectedProject = allProjectsToken
    var selectedBranch = allBranchesToken
    var newtonOnly = false
    var sortMode: SessionSortMode = .recentlyUpdated

    var selectedSource: SessionSource? {
        SessionSource(rawValue: selectedSourceRawValue)
    }
}
