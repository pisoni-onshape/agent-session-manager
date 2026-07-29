import AppKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT_UTILITIES = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func isMissingSQLiteTableError(_ error: Error, table: String) -> Bool {
    guard let sqliteError = error as? SQLiteStoreError else {
        return false
    }

    let tableMessage = "no such table: \(table)"
    switch sqliteError {
    case .openFailed:
        return false
    case .executionFailed(_, let message),
         .prepareFailed(_, let message),
         .stepFailed(_, let message):
        return message.localizedCaseInsensitiveContains(tableMessage)
    }
}

public enum AppPaths {
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AgentSessionManager", isDirectory: true)
    }

    public static var catalogDirectoryURL: URL {
        catalogDatabaseURL.deletingLastPathComponent()
    }

    public static var catalogDatabaseURL: URL {
        applicationSupportDirectory.appendingPathComponent("catalog.sqlite3")
    }

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}

enum ISO8601DateCoding {
    private final class FormatterBox: @unchecked Sendable {
        let formatter: ISO8601DateFormatter

        init(formatOptions: ISO8601DateFormatter.Options) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = formatOptions
            self.formatter = formatter
        }
    }

    private static let fractionalFormatter = FormatterBox(
        formatOptions: [.withInternetDateTime, .withFractionalSeconds]
    )

    private static let regularFormatter = FormatterBox(
        formatOptions: [.withInternetDateTime]
    )

    static func parse(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        return fractionalFormatter.formatter.date(from: rawValue) ?? regularFormatter.formatter.date(from: rawValue)
    }

    static func string(_ date: Date?) -> String? {
        guard let date else { return nil }
        return fractionalFormatter.formatter.string(from: date)
    }
}

enum TextSanitizer {
    private final class RegexBox: @unchecked Sendable {
        let regex: NSRegularExpression

        init(_ pattern: String, options: NSRegularExpression.Options = []) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private static let wrapperPatterns = [
        RegexBox("<current_datetime>.*?</current_datetime>", options: [.dotMatchesLineSeparators]),
        RegexBox("<timestamp>.*?</timestamp>", options: [.dotMatchesLineSeparators]),
        RegexBox("<system_reminder>.*?</system_reminder>", options: [.dotMatchesLineSeparators]),
        RegexBox("<reminder>.*?</reminder>", options: [.dotMatchesLineSeparators]),
        RegexBox("<sql_tables>.*?</sql_tables>", options: [.dotMatchesLineSeparators]),
        RegexBox("</?user_query>")
    ]
    private static let trailingWhitespaceBeforeNewlinePattern = RegexBox("[ \\t]+\\n")
    private static let excessiveNewlinesPattern = RegexBox("\\n{3,}")
    private static let collapsedWhitespacePattern = RegexBox("\\s+")

    static func clean(_ rawText: String?) -> String? {
        sanitize(rawText, preservesLineBreaks: true)
    }

    static func compact(_ rawText: String?) -> String? {
        sanitize(rawText, preservesLineBreaks: false)
    }

    private static func sanitize(_ rawText: String?, preservesLineBreaks: Bool) -> String? {
        guard var text = rawText else { return nil }
        for pattern in wrapperPatterns {
            text = replacingMatches(in: text, using: pattern, with: " ")
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        if preservesLineBreaks {
            text = text.replacingOccurrences(of: "\t", with: "    ")
            text = replacingMatches(in: text, using: trailingWhitespaceBeforeNewlinePattern, with: "\n")
            text = replacingMatches(in: text, using: excessiveNewlinesPattern, with: "\n\n")
        } else {
            text = replacingMatches(in: text, using: collapsedWhitespacePattern, with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func replacingMatches(in text: String, using pattern: RegexBox, with template: String) -> String {
        pattern.regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: template
        )
    }

    static func summarize(_ rawText: String?, limit: Int = 220) -> String? {
        guard let text = compact(rawText) else { return nil }
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func inferTitle(from rawText: String?, fallback: String) -> String {
        summarize(rawText, limit: 90) ?? fallback
    }
}

public struct HighlightedTextSegment: Equatable, Sendable {
    public let text: String
    public let isMatch: Bool

    public init(text: String, isMatch: Bool) {
        self.text = text
        self.isMatch = isMatch
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletList(items: [String])
    case numberedList(items: [String])
    case blockquote(text: String)
    case codeBlock(text: String)
    case table(rows: [String])
    case thematicBreak
}

public enum MarkdownRendering {
    // Parsing Markdown (block splitting and `AttributedString(markdown:)`) is the dominant
    // cost when rendering a transcript, and SwiftUI re-inits row views on every scroll and
    // every highlight change. Cache the parsed results keyed by the raw text so the work
    // happens once per unique string; re-renders then only re-apply the cheap highlight
    // overlay. This keeps both initial open and incremental search navigation fast.
    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private final class AttributedStringBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static nonisolated(unsafe) let blocksCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 4000
        return cache
    }()

    private static nonisolated(unsafe) let inlineAttributedCache: NSCache<NSString, AttributedStringBox> = {
        let cache = NSCache<NSString, AttributedStringBox>()
        cache.countLimit = 8000
        return cache
    }()

    private static nonisolated(unsafe) let fullAttributedCache: NSCache<NSString, AttributedStringBox> = {
        let cache = NSCache<NSString, AttributedStringBox>()
        cache.countLimit = 2000
        return cache
    }()

    public static func inlineAttributedString(from rawText: String, highlightQuery rawQuery: String? = nil, isCurrent: Bool = false) -> AttributedString {
        let attributed = parseInlineMarkdown(rawText) ?? AttributedString(rawText)
        return highlightedAttributedString(from: attributed, query: rawQuery, isCurrent: isCurrent)
    }

    public static func plainTextAttributedString(from rawText: String, highlightQuery rawQuery: String? = nil, isCurrent: Bool = false) -> AttributedString {
        highlightedAttributedString(from: AttributedString(rawText), query: rawQuery, isCurrent: isCurrent)
    }

    public static func visibleText(from rawText: String) -> String {
        if let attributed = parseFullMarkdown(rawText) {
            return String(attributed.characters)
        }
        return rawText
    }

    /// The visible strings that a block renders and highlights over, in render order
    /// (one per inline block, one per list item, one for plain code/table blocks).
    /// Mirrors how `MarkdownBlockView` renders so block-level match detection agrees
    /// with the highlighting.
    public static func runStrings(for block: MarkdownBlock) -> [String] {
        switch block {
        case let .heading(_, text):
            return [inlineVisibleText(text)]
        case let .paragraph(text):
            return [inlineVisibleText(text)]
        case let .bulletList(items):
            return items.map(inlineVisibleText)
        case let .numberedList(items):
            return items.map(inlineVisibleText)
        case let .blockquote(text):
            return [inlineVisibleText(text)]
        case let .codeBlock(text):
            return [text]
        case let .table(rows):
            return [rows.joined(separator: "\n")]
        case .thematicBreak:
            return []
        }
    }

    /// Whether a block contains at least one match for the query.
    public static func blockContainsMatch(_ block: MarkdownBlock, query rawQuery: String?) -> Bool {
        guard let query = SearchTextMatcher.normalizedQuery(rawQuery) else { return false }
        return runStrings(for: block).contains { !SearchTextMatcher.matchRanges(in: $0, query: query).isEmpty }
    }

    private static func inlineVisibleText(_ text: String) -> String {
        String((parseInlineMarkdown(text) ?? AttributedString(text)).characters)
    }

    public static func blocks(from rawText: String) -> [MarkdownBlock] {
        let key = rawText as NSString
        if let cached = blocksCache.object(forKey: key) {
            return cached.blocks
        }
        let result = computeBlocks(from: rawText)
        blocksCache.setObject(BlocksBox(result), forKey: key)
        return result
    }

    /// Pre-populates the block and inline parse caches for the given texts. Intended to be
    /// called off the main thread while a transcript is loading, so the row views hit warm
    /// caches (no synchronous Markdown parsing) when they first scroll into view.
    public static func warmCaches(for texts: [String]) {
        for text in texts where !text.isEmpty {
            for block in blocks(from: text) {
                _ = runStrings(for: block)
            }
        }
    }

    private static func computeBlocks(from rawText: String) -> [MarkdownBlock] {
        let normalizedText = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = codeFenceDelimiter(in: trimmed) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
                continue
            }

            if isThematicBreak(trimmed) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if let heading = heading(in: line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            let nextLine = index + 1 < lines.count ? lines[index + 1] : nil
            if isTableHeader(line, nextLine: nextLine) {
                var rows = [trimmed]
                index += 2
                while index < lines.count {
                    let candidate = lines[index]
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    let candidateNextLine = index + 1 < lines.count ? lines[index + 1] : nil
                    guard !candidateTrimmed.isEmpty,
                          candidate.contains("|"),
                          !startsStandaloneBlock(candidate, nextLine: candidateNextLine) else {
                        break
                    }
                    rows.append(candidateTrimmed)
                    index += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }

            if let firstItem = bulletListItem(in: line) {
                var items = [firstItem]
                index += 1
                while index < lines.count, let item = bulletListItem(in: lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            if let firstItem = numberedListItem(in: line) {
                var items = [firstItem]
                index += 1
                while index < lines.count, let item = numberedListItem(in: lines[index]) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.numberedList(items: items))
                continue
            }

            if let quoteLine = blockquoteLine(in: line) {
                var quoteLines = [quoteLine]
                index += 1
                while index < lines.count, let nextQuoteLine = blockquoteLine(in: lines[index]) {
                    quoteLines.append(nextQuoteLine)
                    index += 1
                }
                let quoteText = TextSanitizer.clean(quoteLines.joined(separator: "\n")) ?? quoteLines.joined(separator: "\n")
                blocks.append(.blockquote(text: quoteText))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                let candidateNextLine = index + 1 < lines.count ? lines[index + 1] : nil
                if candidateTrimmed.isEmpty || startsStandaloneBlock(candidate, nextLine: candidateNextLine) {
                    break
                }
                paragraphLines.append(candidate)
                index += 1
            }

            let paragraphText = TextSanitizer.clean(paragraphLines.joined(separator: "\n")) ?? paragraphLines.joined(separator: "\n")
            blocks.append(.paragraph(text: paragraphText))
        }

        return blocks
    }

    private static func parseInlineMarkdown(_ rawText: String) -> AttributedString? {
        let key = rawText as NSString
        if let cached = inlineAttributedCache.object(forKey: key) {
            return cached.value
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: rawText, options: options) else {
            return nil
        }
        inlineAttributedCache.setObject(AttributedStringBox(parsed), forKey: key)
        return parsed
    }

    private static func parseFullMarkdown(_ rawText: String) -> AttributedString? {
        let key = rawText as NSString
        if let cached = fullAttributedCache.object(forKey: key) {
            return cached.value
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: rawText, options: options) else {
            return nil
        }
        fullAttributedCache.setObject(AttributedStringBox(parsed), forKey: key)
        return parsed
    }

    private static func highlightedAttributedString(from attributed: AttributedString, query rawQuery: String?, isCurrent: Bool = false) -> AttributedString {
        var highlighted = attributed

        guard let query = SearchTextMatcher.normalizedQuery(rawQuery) else {
            return highlighted
        }

        let highlightColor = isCurrent
            ? NSColor.systemOrange.withAlphaComponent(0.5)
            : NSColor.systemYellow.withAlphaComponent(0.35)

        let visible = String(highlighted.characters)
        for range in SearchTextMatcher.matchRanges(in: visible, query: query) {
            guard let lowerBound = AttributedString.Index(range.lowerBound, within: highlighted),
                  let upperBound = AttributedString.Index(range.upperBound, within: highlighted) else {
                continue
            }
            highlighted[lowerBound..<upperBound].backgroundColor = highlightColor
        }

        return highlighted
    }

    private static func startsStandaloneBlock(_ line: String, nextLine: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return codeFenceDelimiter(in: trimmed) != nil
            || isThematicBreak(trimmed)
            || heading(in: line) != nil
            || bulletListItem(in: line) != nil
            || numberedListItem(in: line) != nil
            || blockquoteLine(in: line) != nil
            || isTableHeader(line, nextLine: nextLine)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty,
              hashes.count <= 6,
              trimmed.dropFirst(hashes.count).first?.isWhitespace == true else {
            return nil
        }

        let text = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (hashes.count, text)
    }

    private static func bulletListItem(in line: String) -> String? {
        guard let range = line.range(of: #"^\s*[-*+]\s+(.+)$"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(line[range])
        return matched.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
    }

    private static func numberedListItem(in line: String) -> String? {
        guard let range = line.range(of: #"^\s*\d+[.)]\s+(.+)$"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(line[range])
        return matched.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
    }

    private static func blockquoteLine(in line: String) -> String? {
        guard let range = line.range(of: #"^\s*>\s?(.*)$"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(line[range])
        return matched.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
    }

    private static func isTableHeader(_ line: String, nextLine: String?) -> Bool {
        guard line.contains("|"), let nextLine else { return false }
        let trimmed = nextLine.trimmingCharacters(in: .whitespaces)
        return trimmed.range(
            of: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isThematicBreak(_ trimmedLine: String) -> Bool {
        trimmedLine.range(of: #"^([-*_])(?:\s*\1){2,}$"#, options: .regularExpression) != nil
    }

    private static func codeFenceDelimiter(in trimmedLine: String) -> String? {
        guard let first = trimmedLine.first,
              first == "`" || first == "~" else {
            return nil
        }

        let fenceLength = trimmedLine.prefix { $0 == first }.count
        guard fenceLength >= 3 else { return nil }
        return String(repeating: String(first), count: fenceLength)
    }
}

public enum SearchTextMatcher {
    public static func normalizedQuery(_ rawQuery: String?) -> String? {
        guard let rawQuery else { return nil }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    public static func visibleText(from rawText: String) -> String {
        MarkdownRendering.visibleText(from: rawText)
    }

    public static func matchCount(in rawText: String?, query: String) -> Int {
        guard let rawText else { return 0 }
        return matchRanges(in: visibleText(from: rawText), query: query).count
    }

    public static func segments(in rawText: String, query rawQuery: String?) -> [HighlightedTextSegment] {
        guard let query = normalizedQuery(rawQuery) else {
            return [HighlightedTextSegment(text: visibleText(from: rawText), isMatch: false)]
        }

        let visible = visibleText(from: rawText)
        let ranges = matchRanges(in: visible, query: query)
        guard !ranges.isEmpty else {
            return [HighlightedTextSegment(text: visible, isMatch: false)]
        }

        var segments: [HighlightedTextSegment] = []
        var cursor = visible.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                segments.append(
                    HighlightedTextSegment(
                        text: String(visible[cursor..<range.lowerBound]),
                        isMatch: false
                    )
                )
            }
            segments.append(
                HighlightedTextSegment(
                    text: String(visible[range]),
                    isMatch: true
                )
            )
            cursor = range.upperBound
        }

        if cursor < visible.endIndex {
            segments.append(
                HighlightedTextSegment(
                    text: String(visible[cursor..<visible.endIndex]),
                    isMatch: false
                )
            )
        }

        return segments
    }

    public static func highlightedAttributedString(from rawText: String, query rawQuery: String?) -> AttributedString {
        MarkdownRendering.inlineAttributedString(from: rawText, highlightQuery: rawQuery)
    }

    public static func snippet(in rawText: String, query rawQuery: String?, limit: Int = 120) -> String? {
        guard let query = normalizedQuery(rawQuery) else { return nil }
        let visible = visibleText(from: rawText)
        guard let range = matchRanges(in: visible, query: query).first else { return nil }

        let prefixLength = max(0, limit / 2)
        let suffixLength = max(0, limit - prefixLength)
        let start = visible.index(range.lowerBound, offsetBy: -prefixLength, limitedBy: visible.startIndex) ?? visible.startIndex
        let end = visible.index(range.upperBound, offsetBy: suffixLength, limitedBy: visible.endIndex) ?? visible.endIndex

        var snippet = String(visible[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > visible.startIndex {
            snippet = "..." + snippet
        }
        if end < visible.endIndex {
            snippet += "..."
        }
        return snippet
    }

    public static func snippet(in rawText: String, queries: [String], limit: Int = 120) -> String? {
        for query in queries {
            if let snippet = snippet(in: rawText, query: query, limit: limit) {
                return snippet
            }
        }
        return nil
    }

    public static func matchRanges(in text: String, query rawQuery: String?) -> [Range<String.Index>] {
        guard let query = normalizedQuery(rawQuery) else { return [] }

        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}

public enum PathUtilities {
    public static func displayProjectName(workspacePath: String?, fallback: String) -> String {
        guard let workspacePath, !workspacePath.isEmpty else { return fallback }
        let url = URL(fileURLWithPath: workspacePath)
        if url.pathExtension.lowercased() == "code-workspace" {
            return url.deletingPathExtension().lastPathComponent
        }
        return url.lastPathComponent
    }

    public static func cursorFallbackProjectName(from encodedDirectoryName: String) -> String {
        let username = AppPaths.homeDirectory.lastPathComponent
        let knownPrefixes = [
            "Users-\(username)-repos-",
            "Users-\(username)-Development-LocalProjects-"
        ]

        for prefix in knownPrefixes where encodedDirectoryName.hasPrefix(prefix) {
            let suffix = encodedDirectoryName.dropFirst(prefix.count)
            if !suffix.isEmpty {
                return String(suffix)
            }
        }

        return encodedDirectoryName
    }

    public static func normalizedDirectoryPath(
        _ rawPath: String?,
        homeDirectoryPath: String = AppPaths.homeDirectory.path
    ) -> String? {
        guard let rawPath else { return nil }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expandedHome = trimmed.replacingOccurrences(of: "$HOME", with: homeDirectoryPath)
        let expandedTilde = (expandedHome as NSString).expandingTildeInPath
        let normalized = (expandedTilde as NSString).standardizingPath
        return normalized.isEmpty ? nil : normalized
    }

    public static func isNewtonProject(workspacePath: String?, reposRootPath: String) -> Bool {
        NewtonProjectMatcher(reposRootPath: reposRootPath).matches(workspacePath: workspacePath)
    }

    public static func decodeCursorWorkspacePath(from encodedDirectoryName: String) -> String? {
        let directCandidate = "/" + encodedDirectoryName.split(separator: "-").joined(separator: "/")
        if FileManager.default.fileExists(atPath: directCandidate) {
            return directCandidate
        }

        let username = AppPaths.homeDirectory.lastPathComponent
        let commonPrefix = "Users-\(username)-repos-"
        if encodedDirectoryName.hasPrefix(commonPrefix) {
            let suffix = encodedDirectoryName.dropFirst(commonPrefix.count)
            let candidate = AppPaths.homeDirectory
                .appendingPathComponent("repos", isDirectory: true)
                .appendingPathComponent(String(suffix)).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        let localProjectsPrefix = "Users-\(username)-Development-LocalProjects-"
        if encodedDirectoryName.hasPrefix(localProjectsPrefix) {
            let suffix = encodedDirectoryName.dropFirst(localProjectsPrefix.count)
            let candidate = AppPaths.homeDirectory
                .appendingPathComponent("Development", isDirectory: true)
                .appendingPathComponent("LocalProjects", isDirectory: true)
                .appendingPathComponent(String(suffix)).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    public static func cursorProjectDirectoryName(forWorkspacePath workspacePath: String) -> String {
        let trimmed = workspacePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "" }
        return trimmed.replacingOccurrences(
            of: #"[/\s]+"#,
            with: "-",
            options: .regularExpression
        )
    }

    public static func workspacePathFromFileURI(_ uri: String?) -> String? {
        guard let uri, let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path(percentEncoded: false)
    }

    public static func base64EncodedASCII(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

struct NewtonProjectMatcher: Equatable, Sendable {
    let reposRootPath: String
    private let reposRootComponents: [String]

    init(reposRootPath: String) {
        let normalizedRootPath = PathUtilities.normalizedDirectoryPath(reposRootPath) ?? reposRootPath
        self.reposRootPath = normalizedRootPath
        self.reposRootComponents = URL(fileURLWithPath: normalizedRootPath, isDirectory: true)
            .standardizedFileURL
            .pathComponents
    }

    func matches(workspacePath: String?) -> Bool {
        guard let normalizedWorkspacePath = PathUtilities.normalizedDirectoryPath(workspacePath) else {
            return false
        }

        let workspaceComponents = URL(fileURLWithPath: normalizedWorkspacePath, isDirectory: true)
            .standardizedFileURL
            .pathComponents
        guard workspaceComponents.count > reposRootComponents.count,
              Array(workspaceComponents.prefix(reposRootComponents.count)) == reposRootComponents else {
            return false
        }

        let repoDirectoryName = workspaceComponents[reposRootComponents.count]
        return repoDirectoryName.lowercased().hasPrefix("newton")
    }
}

struct SourceRoots {
    let copilotCLI: URL
    let cursorProjects: URL
    let cursorWorkspaceStorage: URL
    let cursorGlobalStorage: URL
    let vscodeWorkspaceStorage: URL
    let claudeProjects: URL
    /// Claude Desktop's per-session metadata store (its "Code" tab), joined to transcripts by `cliSessionId`.
    let claudeCodeSessions: URL
    /// Claude Code's per-process session-state store (`~/.claude/sessions/<pid>.json`), used to detect
    /// in-progress CLI sessions by matching a live PID's `sessionId` against a record's `sourceSessionId`.
    let claudeSessions: URL

    static let live = SourceRoots(
        copilotCLI: AppPaths.homeDirectory.appendingPathComponent(".copilot/session-state", isDirectory: true),
        cursorProjects: AppPaths.homeDirectory.appendingPathComponent(".cursor/projects", isDirectory: true),
        cursorWorkspaceStorage: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage", isDirectory: true),
        cursorGlobalStorage: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true),
        vscodeWorkspaceStorage: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage", isDirectory: true),
        claudeProjects: AppPaths.homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
        claudeCodeSessions: AppPaths.homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true),
        claudeSessions: ClaudeCodeAdapter.liveSessionsRoot
    )
}

public enum WorkspaceLauncher {
    public static func performPrimaryAction(for record: SessionRecord) throws {
        switch record.resumeKind {
        case .copilotConnect:
            try resumeCopilotCLI(sessionId: record.resumePayload, workingDirectory: record.workspacePath)
        case .openInCursor:
            open(path: record.resumePayload, withApplication: "Cursor")
        case .openInVSCode:
            open(path: record.resumePayload, withApplication: "Visual Studio Code")
        case .revealPath:
            reveal(path: record.resumePayload)
        case .claudeResume:
            try resumeClaudeCLI(sessionId: record.resumePayload, workingDirectory: record.workspacePath)
        case .resumeInClaudeDesktop:
            resumeInClaudeDesktop(sessionId: record.resumePayload)
        }
    }

    public static func startNewConversation(for record: SessionRecord) throws {
        guard let workingDirectory = record.workspacePath else {
            throw NSError(domain: "WorkspaceLauncher", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "This session does not include a project workspace path."
            ])
        }

        switch record.source {
        case .claudeCodeCLI, .claudeCodeVSCode, .claudeDesktop:
            try runTerminalCommand(
                claudeNewConversationCommand(workingDirectory: workingDirectory),
                failureDescription: "Terminal failed to launch a new Claude Code conversation."
            )
        case .copilotCLI, .cursor, .vscodeCopilot:
            try runTerminalCommand(
                copilotNewConversationCommand(workingDirectory: workingDirectory),
                failureDescription: "Terminal failed to launch a new Copilot conversation."
            )
        }
    }

    public static func reveal(path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public static func openDocument(path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    public static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public static func copilotResumeCommand(for record: SessionRecord) -> String {
        var components: [String] = []
        if let workspacePath = record.workspacePath {
            components.append("cd \(shellQuote(workspacePath))")
        }
        components.append("copilot --resume \(shellQuote(record.sourceSessionId))")
        return components.joined(separator: " && ")
    }

    public static func copilotNewConversationCommand(workingDirectory: String) -> String {
        "cd \(shellQuote(workingDirectory)) && copilot"
    }

    public static func claudeNewConversationCommand(workingDirectory: String) -> String {
        "cd \(shellQuote(workingDirectory)) && claude"
    }

    /// Builds the `claude://resume?session=<id>` deep link that resumes an existing conversation
    /// inside the Claude Desktop app. This route is undocumented (discovered in the app bundle,
    /// tracked in anthropics/claude-code#69894) but resumes the exact session by its Claude Code id.
    public static func claudeDesktopResumeURL(sessionId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        return components.url
    }

    public static func resumeInClaudeDesktop(sessionId: String) {
        guard let url = claudeDesktopResumeURL(sessionId: sessionId) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Shell command that resumes a Claude Code session in its workspace directory.
    public static func claudeResumeCommand(for record: SessionRecord) -> String {
        claudeResumeShellCommand(sessionId: record.sourceSessionId, workingDirectory: record.workspacePath)
    }

    /// Resumes a Claude Code session in a terminal via `claude --resume <cliSessionId>`. Desktop
    /// sessions use this for their secondary action, passing the cli session id (not the Desktop
    /// native id used by the `claude://resume` deep link).
    public static func resumeClaudeInTerminal(sessionId: String, workingDirectory: String?) throws {
        try resumeClaudeCLI(sessionId: sessionId, workingDirectory: workingDirectory)
    }

    private static func resumeClaudeCLI(sessionId: String, workingDirectory: String?) throws {
        try runTerminalCommand(
            claudeResumeShellCommand(sessionId: sessionId, workingDirectory: workingDirectory),
            failureDescription: "Terminal failed to launch the Claude Code resume command."
        )
    }

    private static func claudeResumeShellCommand(sessionId: String, workingDirectory: String?) -> String {
        var commandComponents: [String] = []
        if let workingDirectory {
            commandComponents.append("cd \(shellQuote(workingDirectory))")
        }
        commandComponents.append("claude --resume \(shellQuote(sessionId))")
        return commandComponents.joined(separator: " && ")
    }

    private static func resumeCopilotCLI(sessionId: String, workingDirectory: String?) throws {
        let shellCommand = copilotResumeShellCommand(sessionId: sessionId, workingDirectory: workingDirectory)

        try runTerminalCommand(
            shellCommand,
            failureDescription: "Terminal failed to launch the Copilot resume command."
        )
    }

    private static func copilotResumeShellCommand(sessionId: String, workingDirectory: String?) -> String {
        var commandComponents: [String] = []
        if let workingDirectory {
            commandComponents.append("cd \(shellQuote(workingDirectory))")
        }
        commandComponents.append("copilot --resume \(shellQuote(sessionId))")
        return commandComponents.joined(separator: " && ")
    }

    private static func runTerminalCommand(_ shellCommand: String, failureDescription: String) throws {
        let script = """
        tell application "Terminal"
          activate
          do script \(appleScriptStringLiteral(shellCommand))
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "WorkspaceLauncher", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: failureDescription
            ])
        }
    }

    private static func open(path: String, withApplication application: String) {
        NSWorkspace.shared.openFile(path, withApplication: application)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

enum FlatYAMLParser {
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}

/// Rewrites specific key-value pairs in a flat YAML file while preserving order, comments, and other entries.
public enum FlatYAMLWriter {
    /// Updates the given keys in the YAML file at `path`. Keys that exist are rewritten in-place;
    /// keys that don't exist are appended at the end. Returns true on success.
    @discardableResult
    public static func updateValues(at path: String, updates: [String: String]) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return false }

        var lines = text.components(separatedBy: "\n")
        var remaining = updates

        for i in lines.indices {
            let line = lines[i]
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let newValue = remaining[key] else { continue }
            lines[i] = "\(key): \(newValue)"
            remaining.removeValue(forKey: key)
        }

        // Append any keys that weren't found
        for (key, value) in remaining.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }

        let output = lines.joined(separator: "\n")
        return FileManager.default.createFile(atPath: path, contents: output.data(using: .utf8))
    }
}

enum SessionArtifactLocator {
    static func preferredPlanPath(in directory: URL) -> String? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

        let directPlan = directory.appendingPathComponent("plan.md")
        if FileManager.default.fileExists(atPath: directPlan.path) {
            return directPlan.path
        }

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var fallback: URL?
        while let next = enumerator?.nextObject() as? URL {
            guard next.pathExtension.lowercased() == "md" else { continue }
            let name = next.lastPathComponent.lowercased()
            if name == "plan.md" {
                return next.path
            }
            if name.contains("plan") && fallback == nil {
                fallback = next
            }
        }

        return fallback?.path
    }

    static func vscodePlanPath(workspaceDirectory: URL, sessionId: String) -> String? {
        let memoriesRoot = workspaceDirectory.appendingPathComponent("GitHub.copilot-chat/memory-tool/memories", isDirectory: true)
        let encodedSessionID = PathUtilities.base64EncodedASCII(sessionId)
        let sessionMemoryDirectory = memoriesRoot.appendingPathComponent(encodedSessionID, isDirectory: true)
        return preferredPlanPath(in: sessionMemoryDirectory)
    }
}

public enum TranscriptLoadingError: LocalizedError {
    case transcriptUnavailable
    case transcriptUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            return "This session does not have a readable transcript file."
        case let .transcriptUnreadable(path):
            return "The transcript at \(path) could not be read."
        }
    }
}

public enum PlanLoadingError: LocalizedError {
    case planUnavailable
    case planUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .planUnavailable:
            return "This session does not have a readable plan file."
        case let .planUnreadable(path):
            return "The plan at \(path) could not be read."
        }
    }
}

struct VSCodeSessionMetadata {
    let sessionId: String?
    let title: String?
    let startedAt: Date?
    let updatedAt: Date?
    let latestModel: String?
    let firstUser: String?
    let firstAssistant: String?

    var summary: String? {
        TextSanitizer.summarize(firstAssistant ?? firstUser)
    }
}

/// Preview + metadata gathered in a single pass over a Claude Code session JSONL.
struct ClaudeCodePreview {
    var firstUser: String?
    var firstAssistant: String?
    var startedAt: Date?
    var updatedAt: Date?
    var latestModel: String?
    var cwd: String?
    var gitBranch: String?
    var entrypoint: String?
    /// User-set session title (`custom-title` record) — highest priority.
    var customTitle: String?
    /// Auto-generated session title (`ai-title` record).
    var aiTitle: String?
    /// Every `~/.claude/plans/*.md` path referenced in the transcript, in encounter order.
    /// The adapter picks the most recent one that actually exists on disk.
    var planPaths: [String] = []

    var summary: String? {
        TextSanitizer.summarize(firstAssistant ?? firstUser)
    }
}

private enum VSCodeChatSessionPathComponent {
    case key(String)
    case index(Int)
}

public enum TranscriptPreviewExtractor {
    private static let slackTranscriptSidecarFilename = "slack-transcript.jsonl"

    public static func loadTranscript(for record: SessionRecord) throws -> TranscriptDocument {
        guard let transcriptPath = record.rawTranscriptPath else {
            throw TranscriptLoadingError.transcriptUnavailable
        }

        let url = URL(fileURLWithPath: transcriptPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptLoadingError.transcriptUnreadable(url.path)
        }

        switch record.source {
        case .copilotCLI:
            return try extractEventTranscriptDocument(
                from: url,
                source: record.source,
                sessionId: record.sourceSessionId,
                title: record.title
            )
        case .vscodeCopilot:
            if isWorkspaceChatSessionTranscript(url) {
                return try extractWorkspaceChatSessionDocument(
                    from: url,
                    source: record.source,
                    sessionId: record.sourceSessionId,
                    title: record.title
                )
            }
            return try extractEventTranscriptDocument(
                from: url,
                source: record.source,
                sessionId: record.sourceSessionId,
                title: record.title
            )
        case .cursor:
            if isWorkspaceChatSessionTranscript(url) {
                return try extractWorkspaceChatSessionDocument(
                    from: url,
                    source: record.source,
                    sessionId: record.sourceSessionId,
                    title: record.title
                )
            }
            if isCursorBubbleTranscriptStore(url) {
                return try extractCursorBubbleTranscriptDocument(
                    from: url,
                    source: record.source,
                    sessionId: record.sourceSessionId,
                    title: record.title
                )
            }
            return try extractCursorTranscriptDocument(
                from: url,
                source: record.source,
                sessionId: record.sourceSessionId,
                title: record.title
            )
        case .claudeCodeCLI, .claudeCodeVSCode, .claudeDesktop:
            return try extractClaudeCodeTranscriptDocument(
                from: url,
                source: record.source,
                sessionId: record.sourceSessionId,
                title: record.title
            )
        }
    }

    public static func loadPlan(for record: SessionRecord) throws -> PlanDocument {
        guard let planPath = record.relatedPlanPath else {
            throw PlanLoadingError.planUnavailable
        }

        let url = URL(fileURLWithPath: planPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlanLoadingError.planUnreadable(url.path)
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return PlanDocument(
            sessionID: record.sourceSessionId,
            sessionTitle: record.title,
            source: record.source,
            rawPlanPath: url.path,
            text: text
        )
    }

    public static func searchableEntries(for record: SessionRecord) throws -> [TranscriptIndexEntry] {
        let transcript = try loadTranscript(for: record)
        var entries: [TranscriptIndexEntry] = transcript.entries.enumerated().compactMap { element in
            let (index, entry) = element
            guard entry.isChatMessage,
                  let body = TextSanitizer.compact(entry.body) else {
                return nil
            }

            return TranscriptIndexEntry(
                sessionRecordID: record.id,
                entryIndex: index,
                text: body
            )
        }

        if let plan = try? loadPlan(for: record) {
            entries.append(contentsOf: searchablePlanEntries(for: record, plan: plan))
        }

        return entries
    }

    private static func searchablePlanEntries(for record: SessionRecord, plan: PlanDocument) -> [TranscriptIndexEntry] {
        chunkedPlanText(plan.text).enumerated().map { element in
            let (index, chunk) = element
            return TranscriptIndexEntry(
                sessionRecordID: record.id,
                entryIndex: -(index + 1),
                text: chunk
            )
        }
    }

    private static func chunkedPlanText(_ rawText: String, chunkLimit: Int = 800) -> [String] {
        let visibleText = SearchTextMatcher.visibleText(from: rawText)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        let paragraphs = visibleText
            .components(separatedBy: "\n\n")
            .compactMap { TextSanitizer.compact($0) }

        var chunks: [String] = []
        for paragraph in paragraphs {
            if paragraph.count <= chunkLimit {
                chunks.append(paragraph)
                continue
            }

            var current = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
                if candidate.count <= chunkLimit {
                    current = candidate
                    continue
                }

                if !current.isEmpty {
                    chunks.append(current)
                    current = String(word)
                    continue
                }

                var remaining = String(word)
                while remaining.count > chunkLimit {
                    let splitIndex = remaining.index(remaining.startIndex, offsetBy: chunkLimit)
                    chunks.append(String(remaining[..<splitIndex]))
                    remaining = String(remaining[splitIndex...])
                }
                current = remaining
            }

            if !current.isEmpty {
                chunks.append(current)
            }
        }

        return chunks
    }

    static func extractEventTranscript(from url: URL) throws -> TranscriptPreview {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var preview = TranscriptPreview()

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            switch type {
            case "session.start":
                if let payload = object["data"] as? [String: Any] {
                    preview.sessionId = payload["sessionId"] as? String ?? preview.sessionId
                    preview.startedAt = ISO8601DateCoding.parse(payload["startTime"] as? String) ?? preview.startedAt
                }
            case "session.model_change":
                if let payload = object["data"] as? [String: Any] {
                    preview.latestModel = normalizeModelIdentifier(payload["newModel"] as? String) ?? preview.latestModel
                }
            case "user.message":
                if preview.firstUser == nil {
                    preview.firstUser = TextSanitizer.clean((object["data"] as? [String: Any])?["content"] as? String)
                }
            case "assistant.message":
                if preview.firstAssistant == nil {
                    preview.firstAssistant = TextSanitizer.clean((object["data"] as? [String: Any])?["content"] as? String)
                }
            default:
                break
            }

            if preview.firstUser != nil, preview.firstAssistant != nil, preview.startedAt != nil {
                break
            }
        }

        return preview
    }

    static func extractVSCodeSessionMetadata(from url: URL) throws -> VSCodeSessionMetadata {
        if isWorkspaceChatSessionTranscript(url) {
            return try extractWorkspaceChatSessionMetadata(from: url)
        }

        let preview = try extractEventTranscript(from: url)
        return VSCodeSessionMetadata(
            sessionId: preview.sessionId,
            title: nil,
            startedAt: preview.startedAt,
            updatedAt: nil,
            latestModel: preview.latestModel,
            firstUser: preview.firstUser,
            firstAssistant: preview.firstAssistant
        )
    }

    private static func extractEventTranscriptDocument(
        from url: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var toolNamesByCallID: [String: String] = [:]
        var entries: [TranscriptEntry] = []

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            let payload = object["data"] as? [String: Any]
            let entryID = object["id"] as? String ?? UUID().uuidString
            let timestamp = eventTimestamp(in: object, payload: payload)

            if type == "tool.execution_start",
               let toolCallId = payload?["toolCallId"] as? String,
               let toolName = payload?["toolName"] as? String {
                toolNamesByCallID[toolCallId] = toolName
            }

            guard let entry = eventTranscriptEntry(
                type: type,
                payload: payload,
                timestamp: timestamp,
                entryID: entryID,
                toolNamesByCallID: toolNamesByCallID
            ) else {
                continue
            }

            entries.append(entry)
        }

        let slackEntries = try loadSlackTranscriptSidecarEntries(
            sessionId: sessionId,
            alongside: url
        )
        let mergedEntries = mergeTranscriptEntries(entries, with: slackEntries)

        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: url.path,
            entries: mergedEntries,
            timestampsAreComplete: true,
            timestampNotice: nil
        )
    }

    private static func loadSlackTranscriptSidecarEntries(
        sessionId: String,
        alongside transcriptURL: URL
    ) throws -> [TranscriptEntry] {
        let sidecarURL = transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent(slackTranscriptSidecarFilename)
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return []
        }

        let contents = try String(contentsOf: sidecarURL, encoding: .utf8)
        var entries: [TranscriptEntry] = []

        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let sender = (object["sender"] as? String)?.lowercased() ?? "system"
            let role: TranscriptEntryRole
            let title: String
            switch sender {
            case "user":
                role = .user
                title = "Slack User"
            case "assistant":
                role = .assistant
                title = "Slack Assistant"
            default:
                role = .system
                title = "Slack"
            }

            let body = TextSanitizer.compact(object["text"] as? String)
            let timestamp = ISO8601DateCoding.parse(object["timestamp"] as? String)
                ?? ISO8601DateCoding.parse(object["recorded_at"] as? String)
            let rawMessageID = (object["slack_ts"] as? String)?.replacingOccurrences(of: ".", with: "-")
                ?? "\(index)"

            entries.append(
                TranscriptEntry(
                    id: "\(sessionId)-slack-\(rawMessageID)",
                    role: role,
                    title: title,
                    body: body,
                    timestamp: timestamp
                )
            )
        }

        return entries
    }

    private static func mergeTranscriptEntries(
        _ primary: [TranscriptEntry],
        with secondary: [TranscriptEntry]
    ) -> [TranscriptEntry] {
        let merged = primary.enumerated().map { (group: 0, order: $0.offset, entry: $0.element) }
            + secondary.enumerated().map { (group: 1, order: $0.offset, entry: $0.element) }

        return merged.sorted { lhs, rhs in
            switch (lhs.entry.timestamp, rhs.entry.timestamp) {
            case let (left?, right?) where left != right:
                return left < right
            case let (left?, right?) where left == right:
                break
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            if lhs.group != rhs.group {
                return lhs.group < rhs.group
            }
            return lhs.order < rhs.order
        }
        .map(\.entry)
    }

    static func extractVSCodeChatSessionModel(from url: URL) throws -> String? {
        try extractWorkspaceChatSessionMetadata(from: url).latestModel
    }

    static func extractCursorTranscript(from url: URL) throws -> TranscriptPreview {
        if isWorkspaceChatSessionTranscript(url) {
            let metadata = try extractWorkspaceChatSessionMetadata(from: url)
            return TranscriptPreview(
                sessionId: metadata.sessionId,
                startedAt: metadata.startedAt,
                latestModel: metadata.latestModel,
                firstUser: metadata.firstUser,
                firstAssistant: metadata.firstAssistant
            )
        }
        if isCursorBubbleTranscriptStore(url) {
            throw TranscriptLoadingError.transcriptUnreadable(url.path)
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        var preview = TranscriptPreview()

        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String else {
                continue
            }

            let text = extractCursorText(from: object)
            switch role {
            case "user" where preview.firstUser == nil:
                preview.firstUser = text
            case "assistant" where preview.firstAssistant == nil:
                preview.firstAssistant = text
            default:
                break
            }

            if preview.firstUser != nil, preview.firstAssistant != nil {
                break
            }
        }

        return preview
    }

    static func extractCursorBubbleTranscript(from databaseURL: URL, sessionId: String) throws -> TranscriptPreview {
        let entries = try loadCursorBubbleEntries(from: databaseURL, sessionId: sessionId)
        return TranscriptPreview(
            sessionId: sessionId,
            startedAt: entries.compactMap(\.timestamp).min(),
            latestModel: nil,
            firstUser: entries.first(where: { $0.role == .user })?.body,
            firstAssistant: entries.first(where: { $0.role == .assistant })?.body
        )
    }

    private static func extractCursorTranscriptDocument(
        from url: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var entries: [TranscriptEntry] = []

        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String,
                  let body = extractCursorText(from: object) else {
                continue
            }

            let entryRole: TranscriptEntryRole
            let entryTitle: String
            switch role {
            case "user":
                entryRole = .user
                entryTitle = "User"
            case "assistant":
                entryRole = .assistant
                entryTitle = "Assistant"
            default:
                entryRole = .system
                entryTitle = role.capitalized
            }

            entries.append(
                TranscriptEntry(
                    id: "\(sessionId)-\(index)",
                    role: entryRole,
                    title: entryTitle,
                    body: body,
                    timestamp: nil
                )
            )
        }

        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: url.path,
            entries: entries,
            timestampsAreComplete: false,
            timestampNotice: "Cursor transcripts preserve message order, but the inspected local JSONL files do not include per-message timestamps."
        )
    }

    private static func extractCursorBubbleTranscriptDocument(
        from databaseURL: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let entries = try loadCursorBubbleEntries(from: databaseURL, sessionId: sessionId)
        let timestampsAreComplete = entries.allSatisfy { $0.timestamp != nil }
        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: databaseURL.path,
            entries: entries,
            timestampsAreComplete: timestampsAreComplete,
            timestampNotice: timestampsAreComplete
                ? nil
                : "Cursor composer bubble transcripts preserve message order, but some inspected local rows do not expose a reliable timestamp for every message."
        )
    }

    private static func extractWorkspaceChatSessionDocument(
        from url: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let root = try loadVSCodeChatSessionRoot(from: url)
        let requests = root["requests"] as? [[String: Any]] ?? []
        var entries: [TranscriptEntry] = []

        for (index, request) in requests.enumerated() {
            let requestID = request["requestId"] as? String ?? "\(sessionId)-request-\(index)"
            let requestTimestamp = dateFromEpochMilliseconds(request["timestamp"])

            if let userText = extractVSCodeChatRequestText(from: request) {
                entries.append(
                    TranscriptEntry(
                        id: "\(requestID)-user",
                        role: .user,
                        title: "User",
                        body: userText,
                        timestamp: requestTimestamp
                    )
                )
            }

            if let assistantText = extractVSCodeChatResponseText(from: request["response"]) {
                entries.append(
                    TranscriptEntry(
                        id: "\(requestID)-assistant",
                        role: .assistant,
                        title: "Assistant",
                        body: assistantText,
                        timestamp: nil
                    )
                )
            }
        }

        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: url.path,
            entries: entries,
            timestampsAreComplete: false,
            timestampNotice: "Workspace chatSessions preserve creation and request timestamps, but the inspected local files do not expose a reliable per-response timestamp for every assistant chunk."
        )
    }

    static func extractMarkdownSummary(from url: URL) throws -> String? {
        let text = try String(contentsOf: url, encoding: .utf8)
        let cleaned = text
            .split(separator: "\n")
            .map { line in
                line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            }
            .joined(separator: "\n")
        return TextSanitizer.summarize(cleaned, limit: 240)
    }

    private static func extractCursorText(from object: [String: Any]) -> String? {
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            let text = content.compactMap { item -> String? in
                if item["type"] as? String == "text" {
                    return item["text"] as? String
                }
                return nil
            }.joined(separator: "\n\n")
            return TextSanitizer.clean(text)
        }

        if let message = object["message"] as? String {
            return TextSanitizer.clean(message)
        }

        return nil
    }

    // MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

    private struct ClaudeContentBlock {
        let role: TranscriptEntryRole
        let title: String
        let body: String?
    }

    private static let claudePlanPathRegex = try! NSRegularExpression(
        pattern: "(~|/)[^\\s\"',]*\\.claude/plans/[^\\s\"',]+\\.md"
    )

    private static func extractClaudeCodeTranscriptDocument(
        from url: URL,
        source: SessionSource,
        sessionId: String,
        title: String
    ) throws -> TranscriptDocument {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var entries: [TranscriptEntry] = []

        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant" || type == "attachment" else {
                continue
            }

            let timestamp = ISO8601DateCoding.parse(object["timestamp"] as? String)
            let baseId = (object["uuid"] as? String) ?? "\(sessionId)-\(index)"

            // Human "steering" prompts typed while the assistant is mid-turn are not stored as
            // normal user messages; Claude records them as a queued-command attachment. Surface
            // them as user chat so they appear at their chronological position.
            if type == "attachment" {
                guard let block = claudeQueuedHumanPromptBlock(object["attachment"]) else {
                    continue
                }
                appendClaudeEntry(block, id: baseId, timestamp: timestamp, into: &entries)
                continue
            }

            let content = (object["message"] as? [String: Any])?["content"]
            let blocks: [ClaudeContentBlock]
            if type == "user" {
                let isMeta = object["isMeta"] as? Bool ?? false
                let isCompactSummary = object["isCompactSummary"] as? Bool ?? false
                blocks = claudeUserContentBlocks(content, isMeta: isMeta, isCompactSummary: isCompactSummary)
            } else {
                blocks = claudeContentBlocks(content, defaultRole: .assistant)
            }

            for (subIndex, block) in blocks.enumerated() {
                appendClaudeEntry(
                    block,
                    id: blocks.count > 1 ? "\(baseId)-\(subIndex)" : baseId,
                    timestamp: timestamp,
                    into: &entries
                )
            }
        }

        let timestampsAreComplete = !entries.isEmpty && entries.allSatisfy { $0.timestamp != nil }
        return TranscriptDocument(
            sessionID: sessionId,
            sessionTitle: title,
            source: source,
            rawTranscriptPath: url.path,
            entries: entries,
            timestampsAreComplete: timestampsAreComplete,
            timestampNotice: timestampsAreComplete
                ? nil
                : "Claude Code transcripts preserve message order, but some inspected records did not include a per-message timestamp."
        )
    }

    /// Normalizes a Claude `message.content` value (either a plain string or an array of
    /// `text`/`tool_use`/`tool_result` blocks) into ordered transcript blocks.
    private static func claudeContentBlocks(_ content: Any?, defaultRole: TranscriptEntryRole) -> [ClaudeContentBlock] {
        let chatTitle = defaultRole == .user ? "User" : "Assistant"

        if let text = content as? String {
            guard let cleaned = TextSanitizer.clean(text) else { return [] }
            return [ClaudeContentBlock(role: defaultRole, title: chatTitle, body: cleaned)]
        }

        guard let array = content as? [[String: Any]] else { return [] }

        var blocks: [ClaudeContentBlock] = []
        for item in array {
            switch item["type"] as? String {
            case "text":
                if let cleaned = TextSanitizer.clean(item["text"] as? String) {
                    blocks.append(ClaudeContentBlock(role: defaultRole, title: chatTitle, body: cleaned))
                }
            case "tool_use":
                let name = item["name"] as? String ?? "tool"
                blocks.append(ClaudeContentBlock(role: .tool, title: "Tool: \(name)", body: toolArgumentsSummary(item["input"])))
            case "tool_result":
                blocks.append(ClaudeContentBlock(role: .tool, title: "Tool Result", body: claudeToolResultText(item["content"])))
            default:
                continue
            }
        }
        return blocks
    }

    /// Normalizes a Claude `type: user` message into transcript blocks, reclassifying
    /// harness-injected turns (task notifications, slash-command scaffolding, IDE context,
    /// hooks, and other `isMeta` wrappers) as internal `.system` events so they stay hidden
    /// unless "Show internal events" is on. Genuine human prompts remain `.user`, and a
    /// task notification's inner `<result>` payload is surfaced as a visible `.assistant`
    /// message so useful subagent output is not lost.
    private static func claudeUserContentBlocks(_ content: Any?, isMeta: Bool, isCompactSummary: Bool) -> [ClaudeContentBlock] {
        if let text = content as? String {
            return claudeUserTextBlocks(text, isMeta: isMeta, isCompactSummary: isCompactSummary)
        }

        guard let array = content as? [[String: Any]] else { return [] }

        var blocks: [ClaudeContentBlock] = []
        for item in array {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String {
                    blocks.append(contentsOf: claudeUserTextBlocks(text, isMeta: isMeta, isCompactSummary: isCompactSummary))
                }
            case "tool_use":
                let name = item["name"] as? String ?? "tool"
                blocks.append(ClaudeContentBlock(role: .tool, title: "Tool: \(name)", body: toolArgumentsSummary(item["input"])))
            case "tool_result":
                blocks.append(ClaudeContentBlock(role: .tool, title: "Tool Result", body: claudeToolResultText(item["content"])))
            default:
                continue
            }
        }
        return blocks
    }

    /// Classifies a single user text block into transcript blocks. Runs only on `user`
    /// lines and does cheap prefix checks; the `<result>` and `<command-args>` extraction
    /// paths execute only for the relevant wrapper payloads.
    private static func claudeUserTextBlocks(_ rawText: String, isMeta: Bool, isCompactSummary: Bool) -> [ClaudeContentBlock] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("<task-notification>") {
            var blocks: [ClaudeContentBlock] = []
            let title = claudeTaggedValue("summary", in: rawText)
                .map { "Task notification: \($0)" } ?? "Task notification"
            let wrapperSource = claudeRemovingResultBlock(rawText)
            if let wrapperBody = TextSanitizer.summarize(wrapperSource, limit: 400) {
                blocks.append(ClaudeContentBlock(role: .system, title: title, body: wrapperBody))
            } else {
                blocks.append(ClaudeContentBlock(role: .system, title: title, body: nil))
            }
            if let result = claudeTaggedValue("result", in: rawText),
               let cleanedResult = TextSanitizer.clean(result) {
                blocks.append(ClaudeContentBlock(role: .assistant, title: "Assistant", body: cleanedResult))
            }
            return blocks
        }

        // A slash-command turn stores the user's typed prose in `<command-args>` (the
        // `<command-name>` is the invoked command, `<command-message>` is only its display
        // name). Surface the args as the real user prompt, reconstructed with the command
        // name; commands without args (e.g. /model, /clear) stay internal.
        if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>") {
            let name = claudeTaggedValue("command-name", in: rawText)
            if let args = claudeTaggedValue("command-args", in: rawText),
               let cleanedArgs = TextSanitizer.clean(args) {
                let body = name.map { "\($0) \(cleanedArgs)" } ?? cleanedArgs
                return [ClaudeContentBlock(role: .user, title: "User", body: body)]
            }
            let title = name.map { "Slash command: \($0)" } ?? "Slash command"
            return [ClaudeContentBlock(role: .system, title: title, body: TextSanitizer.summarize(rawText, limit: 200))]
        }

        // Auto-generated recap injected when a compacted session is resumed. It duplicates
        // earlier turns that are still present in the transcript, so keep it internal.
        if isCompactSummary {
            return [ClaudeContentBlock(
                role: .system,
                title: "Session continued (compacted summary)",
                body: TextSanitizer.summarize(rawText, limit: 400)
            )]
        }

        if isMeta || claudeTextIsHarnessWrapper(trimmed) {
            guard let cleaned = TextSanitizer.summarize(rawText, limit: 400) else { return [] }
            return [ClaudeContentBlock(role: .system, title: claudeHarnessWrapperTitle(trimmed), body: cleaned)]
        }

        guard let cleaned = TextSanitizer.clean(rawText) else { return [] }
        return [ClaudeContentBlock(role: .user, title: "User", body: cleaned)]
    }

    /// Appends a transcript entry, skipping an immediately repeated identical user body so a
    /// surfaced queued prompt is not duplicated by a coincident normal user turn.
    private static func appendClaudeEntry(
        _ block: ClaudeContentBlock,
        id: String,
        timestamp: Date?,
        into entries: inout [TranscriptEntry]
    ) {
        if block.role == .user,
           let body = block.body,
           let previous = entries.last,
           previous.role == .user,
           previous.body == body {
            return
        }
        entries.append(
            TranscriptEntry(id: id, role: block.role, title: block.title, body: block.body, timestamp: timestamp)
        )
    }

    /// Extracts a human-authored queued (steering) prompt from a Claude `attachment` record.
    /// These are prompts typed while the assistant is mid-turn; Claude stores them as a
    /// `queued_command` attachment rather than a normal user message, so they would otherwise
    /// never appear in the transcript. Non-human queued commands (e.g. task notifications)
    /// are ignored.
    private static func claudeQueuedHumanPromptBlock(_ attachment: Any?) -> ClaudeContentBlock? {
        guard let attachment = attachment as? [String: Any],
              attachment["type"] as? String == "queued_command",
              (attachment["origin"] as? [String: Any])?["kind"] as? String == "human",
              let cleaned = TextSanitizer.clean(attachment["prompt"] as? String) else {
            return nil
        }
        return ClaudeContentBlock(role: .user, title: "User", body: cleaned)
    }


    /// Returns the text between the first `<tag>` and its matching `</tag>`, or nil.
    private static func claudeTaggedValue(_ tag: String, in text: String) -> String? {
        guard let openRange = text.range(of: "<\(tag)>"),
              let closeRange = text.range(of: "</\(tag)>", range: openRange.upperBound..<text.endIndex) else {
            return nil
        }
        let inner = text[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Strips the `<result>...</result>` block (which can be large) from a notification so
    /// the internal wrapper entry keeps only its metadata and does not duplicate the payload.
    private static func claudeRemovingResultBlock(_ text: String) -> String {
        guard let openRange = text.range(of: "<result>"),
              let closeRange = text.range(of: "</result>", range: openRange.upperBound..<text.endIndex) else {
            return text
        }
        var stripped = text
        stripped.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: "")
        return stripped
    }

    private static func claudeTextIsHarnessWrapper(_ trimmed: String) -> Bool {
        claudeMetaPromptPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// A friendly label for a harness-injected internal event, based on its leading tag.
    private static func claudeHarnessWrapperTitle(_ trimmed: String) -> String {
        if trimmed.hasPrefix("<command-") { return "Slash command" }
        if trimmed.hasPrefix("<local-command-") || trimmed.hasPrefix("<bash-") { return "Command output" }
        if trimmed.hasPrefix("<ide_") { return "IDE context" }
        if trimmed.hasPrefix("<user-prompt-submit-hook") || trimmed.hasPrefix("<session-start-hook") { return "Hook" }
        if trimmed.hasPrefix("<user-memory-input") { return "Memory" }
        if trimmed.hasPrefix("Caveat:") { return "Caveat" }
        return "Internal event"
    }

    private static func claudeToolResultText(_ content: Any?) -> String? {
        if let text = content as? String {
            return TextSanitizer.summarize(text, limit: 400)
        }
        if let array = content as? [[String: Any]] {
            let joined = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return TextSanitizer.summarize(joined, limit: 400)
        }
        return nil
    }

    /// Single-pass preview + metadata scan used by `ClaudeCodeAdapter.loadRecord`.
    static func extractClaudeCodePreview(from url: URL) throws -> ClaudeCodePreview {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var preview = ClaudeCodePreview()

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let rawLine = String(line)

            // Plan-file linkage: plan paths appear in record text (harness messages, prose).
            // Collect every candidate; the adapter resolves the most recent existing one.
            if rawLine.contains(".claude/plans/") {
                preview.planPaths.append(contentsOf: allMatches(of: claudePlanPathRegex, in: rawLine))
            }

            guard let data = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if preview.cwd == nil { preview.cwd = object["cwd"] as? String }
            if preview.gitBranch == nil { preview.gitBranch = object["gitBranch"] as? String }
            if preview.entrypoint == nil { preview.entrypoint = object["entrypoint"] as? String }

            if let timestamp = ISO8601DateCoding.parse(object["timestamp"] as? String) {
                if preview.startedAt == nil { preview.startedAt = timestamp }
                preview.updatedAt = timestamp
            }

            // Claude records its own session titles in dedicated records; keep the latest of each.
            // A user-set `custom-title` outranks the auto-generated `ai-title`.
            if let customTitle = object["customTitle"] as? String { preview.customTitle = customTitle }
            if let aiTitle = object["aiTitle"] as? String { preview.aiTitle = aiTitle }

            guard let type = object["type"] as? String,
                  type == "user" || type == "assistant" else {
                continue
            }

            let message = object["message"] as? [String: Any]
            if type == "assistant", let model = normalizeModelIdentifier(message?["model"] as? String) {
                preview.latestModel = model
            }

            if type == "user", preview.firstUser == nil {
                // Use the shared classifier so the preview reflects the first real human prompt
                // (including a slash command's `<command-args>`) and skips wrapper/meta/recap turns.
                let isMeta = object["isMeta"] as? Bool ?? false
                let isCompactSummary = object["isCompactSummary"] as? Bool ?? false
                if let body = claudeUserContentBlocks(message?["content"], isMeta: isMeta, isCompactSummary: isCompactSummary)
                    .first(where: { $0.role == .user })?
                    .body {
                    preview.firstUser = body
                }
            }
            if type == "assistant", preview.firstAssistant == nil {
                preview.firstAssistant = claudeContentBlocks(message?["content"], defaultRole: .assistant)
                    .first(where: { $0.role == .assistant })?
                    .body
            }
        }

        return preview
    }

    /// Wrapper prefixes Claude Code injects into a user turn (slash-command scaffolding, IDE
    /// context, hooks) that should not be treated as the human's prompt for titling/preview.
    /// Also reused by the transcript parser to reclassify these turns as internal events.
    private static let claudeMetaPromptPrefixes = [
        "<task-notification>",
        "<local-command-caveat", "<command-name", "<command-message", "<command-args",
        "<command-contents", "<local-command-stdout", "<local-command-stderr",
        "<bash-input", "<bash-stdout", "<bash-stderr",
        "<ide_opened_file", "<ide_selection", "<ide_diagnostics",
        "<ide_recently_modified_files", "<user-prompt-submit-hook", "<session-start-hook",
        "<user-memory-input", "Caveat:"
    ]

    private static func allMatches(of regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { result in
            Range(result.range, in: text).map { String(text[$0]) }
        }
    }

    private static func isWorkspaceChatSessionTranscript(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "chatSessions"
    }

    private static func isCursorBubbleTranscriptStore(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "vscdb"
    }

    static func extractWorkspaceChatSessionMetadata(from url: URL) throws -> VSCodeSessionMetadata {
        let root = try loadVSCodeChatSessionRoot(from: url)
        let requests = root["requests"] as? [[String: Any]] ?? []
        let createdAt = dateFromEpochMilliseconds(root["creationDate"])
        let updatedAt = requests.compactMap { dateFromEpochMilliseconds($0["timestamp"]) }.max() ?? createdAt
        let firstUser = requests.lazy.compactMap { extractVSCodeChatRequestText(from: $0) }.first
        let firstAssistant = requests.lazy.compactMap { extractVSCodeChatResponseText(from: $0["response"]) }.first
        let latestModel = requests
            .reversed()
            .lazy
            .compactMap { request in
                normalizeModelIdentifier(request["modelId"] as? String)
                    ?? normalizeModelIdentifier(nestedString(in: request, path: ["agent", "modelId"]))
            }
            .first
            ?? normalizeModelIdentifier(
                nestedString(in: root, path: ["inputState", "selectedModel", "identifier"])
            )

        return VSCodeSessionMetadata(
            sessionId: root["sessionId"] as? String,
            title: TextSanitizer.compact(root["customTitle"] as? String),
            startedAt: createdAt,
            updatedAt: updatedAt,
            latestModel: latestModel,
            firstUser: firstUser,
            firstAssistant: firstAssistant
        )
    }

    private static func loadCursorBubbleEntries(from databaseURL: URL, sessionId: String) throws -> [TranscriptEntry] {
        let rawValues: [String: String]
        do {
            rawValues = try loadSQLiteValues(from: databaseURL, table: "cursorDiskKV", keyLike: "bubbleId:\(sessionId):%")
        } catch {
            if isMissingSQLiteTableError(error, table: "cursorDiskKV") {
                return []
            }
            throw error
        }
        let entries = rawValues.compactMap { key, rawValue -> TranscriptEntry? in
            guard let data = rawValue.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return cursorBubbleTranscriptEntry(from: object, sessionId: sessionId, fallbackID: key)
        }
        return entries.sorted { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (left?, right?):
                if left != right {
                    return left < right
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func cursorBubbleTranscriptEntry(
        from object: [String: Any],
        sessionId: String,
        fallbackID: String
    ) -> TranscriptEntry? {
        let role: TranscriptEntryRole
        let title: String
        switch (object["type"] as? NSNumber)?.intValue {
        case 1:
            role = .user
            title = "User"
        case 2:
            role = .assistant
            title = "Assistant"
        default:
            return nil
        }

        guard let body = extractCursorBubbleText(from: object) else {
            return nil
        }

        let messageID = (object["bubbleId"] as? String).map { "\(sessionId)-\($0)" } ?? fallbackID
        let timestamp = ISO8601DateCoding.parse(object["createdAt"] as? String)
            ?? dateFromEpochMilliseconds(object["createdAt"])

        return TranscriptEntry(
            id: messageID,
            role: role,
            title: title,
            body: body,
            timestamp: timestamp
        )
    }

    private static func extractCursorBubbleText(from object: [String: Any]) -> String? {
        if let text = TextSanitizer.clean(object["text"] as? String) {
            return text
        }

        guard let richText = object["richText"] as? String,
              let data = richText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let flattened = flattenCursorRichText(from: root)
        guard !flattened.isEmpty else {
            return nil
        }
        return TextSanitizer.clean(flattened.joined(separator: "\n\n"))
    }

    private static func flattenCursorRichText(from value: Any) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            if let text = dictionary["text"] as? String,
               let cleaned = TextSanitizer.compact(text) {
                return [cleaned]
            }
            return dictionary.keys.sorted().flatMap { key in
                flattenCursorRichText(from: dictionary[key] as Any)
            }
        case let array as [Any]:
            return array.flatMap(flattenCursorRichText)
        default:
            return []
        }
    }

    private static func loadVSCodeChatSessionRoot(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["kind"] == nil {
            return (object["v"] as? [String: Any]) ?? object
        }

        let contents = String(decoding: data, as: UTF8.self)
        var root: [String: Any]?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let kind = (object["kind"] as? NSNumber)?.intValue
            switch kind {
            case 0:
                root = (object["v"] as? [String: Any]) ?? object
            case 1:
                guard let path = decodeVSCodeChatSessionPath(from: object["k"]) else { continue }
                root = (setVSCodeChatSessionValue(
                    in: root ?? [:],
                    path: path,
                    value: object["v"] ?? NSNull()
                ) as? [String: Any]) ?? root
            case 2:
                guard let path = decodeVSCodeChatSessionPath(from: object["k"]) else { continue }
                let values: [Any]
                if let array = object["v"] as? [Any] {
                    values = array
                } else if let value = object["v"] {
                    values = [value]
                } else {
                    values = []
                }
                root = (appendVSCodeChatSessionValues(
                    in: root ?? [:],
                    path: path,
                    values: values
                ) as? [String: Any]) ?? root
            default:
                if root == nil {
                    root = (object["v"] as? [String: Any]) ?? object
                }
            }
        }

        guard let root else {
            throw TranscriptLoadingError.transcriptUnreadable(url.path)
        }
        return root
    }

    private static func extractVSCodeChatRequestText(from request: [String: Any]) -> String? {
        guard let message = request["message"] as? [String: Any] else {
            return nil
        }

        if let text = message["text"] as? String {
            return TextSanitizer.clean(displayVSCodeMarkdownFragment(text))
        }

        if let parts = message["parts"] as? [[String: Any]] {
            let combined = parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return displayVSCodeMarkdownFragment(text)
                }
                return nestedString(in: part, path: ["value", "text"]).map(displayVSCodeMarkdownFragment)
            }.joined(separator: "\n\n")
            return TextSanitizer.clean(combined)
        }

        return nil
    }

    private static func extractVSCodeChatResponseText(from rawResponse: Any?) -> String? {
        guard let responseItems = rawResponse as? [Any] else {
            return nil
        }

        let fragments = responseItems.compactMap { item -> String? in
            guard let item = item as? [String: Any] else {
                return nil
            }

            if let kind = item["kind"] as? String {
                switch kind {
                case "markdownContent":
                    return nestedString(in: item, path: ["content", "value"]).map(displayVSCodeMarkdownFragment)
                case "warningMessage":
                    return TextSanitizer.clean(displayVSCodeMarkdownFragment(item["warningMessage"] as? String ?? ""))
                default:
                    return nil
                }
            }

            return (item["value"] as? String).map(displayVSCodeMarkdownFragment)
        }

        guard !fragments.isEmpty else {
            return nil
        }

        return TextSanitizer.clean(joinTextFragments(fragments))
    }

    private static func displayVSCodeMarkdownFragment(_ text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else {
            return SearchTextMatcher.visibleText(from: text)
        }
        return text
    }

    private static func joinTextFragments(_ fragments: [String]) -> String {
        guard var combined = fragments.first else { return "" }
        for fragment in fragments.dropFirst() {
            guard !fragment.isEmpty else { continue }
            if let lastCharacter = combined.last,
               let firstCharacter = fragment.first,
               !lastCharacter.isWhitespace,
               !firstCharacter.isWhitespace {
                combined += " "
            }
            combined += fragment
        }
        return combined
    }

    private static func dateFromEpochMilliseconds(_ rawValue: Any?) -> Date? {
        switch rawValue {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        case let string as String:
            guard let milliseconds = Double(string) else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1000)
        default:
            return nil
        }
    }

    private static func decodeVSCodeChatSessionPath(from rawPath: Any?) -> [VSCodeChatSessionPathComponent]? {
        guard let rawSegments = rawPath as? [Any] else {
            return nil
        }

        let segments = rawSegments.compactMap { rawSegment -> VSCodeChatSessionPathComponent? in
            switch rawSegment {
            case let key as String:
                return .key(key)
            case let index as NSNumber:
                return .index(index.intValue)
            default:
                return nil
            }
        }

        return segments.count == rawSegments.count ? segments : nil
    }

    private static func setVSCodeChatSessionValue(
        in current: Any,
        path: [VSCodeChatSessionPathComponent],
        value: Any
    ) -> Any {
        guard let component = path.first else {
            return value
        }

        switch component {
        case .key(let key):
            var dictionary = current as? [String: Any] ?? [:]
            if path.count == 1 {
                dictionary[key] = value
            } else {
                dictionary[key] = setVSCodeChatSessionValue(
                    in: sanitizedVSCodeChatSessionValue(dictionary[key], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    value: value
                )
            }
            return dictionary
        case .index(let index):
            var array = current as? [Any] ?? []
            while array.count <= index {
                array.append(NSNull())
            }
            if path.count == 1 {
                array[index] = value
            } else {
                array[index] = setVSCodeChatSessionValue(
                    in: sanitizedVSCodeChatSessionValue(array[index], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    value: value
                )
            }
            return array
        }
    }

    private static func appendVSCodeChatSessionValues(
        in current: Any,
        path: [VSCodeChatSessionPathComponent],
        values: [Any]
    ) -> Any {
        guard let component = path.first else {
            var array = current as? [Any] ?? []
            array.append(contentsOf: values)
            return array
        }

        switch component {
        case .key(let key):
            var dictionary = current as? [String: Any] ?? [:]
            if path.count == 1 {
                var array = dictionary[key] as? [Any] ?? []
                array.append(contentsOf: values)
                dictionary[key] = array
            } else {
                dictionary[key] = appendVSCodeChatSessionValues(
                    in: sanitizedVSCodeChatSessionValue(dictionary[key], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    values: values
                )
            }
            return dictionary
        case .index(let index):
            var array = current as? [Any] ?? []
            while array.count <= index {
                array.append(NSNull())
            }
            if path.count == 1 {
                var childArray = array[index] as? [Any] ?? []
                childArray.append(contentsOf: values)
                array[index] = childArray
            } else {
                array[index] = appendVSCodeChatSessionValues(
                    in: sanitizedVSCodeChatSessionValue(array[index], nextPath: Array(path.dropFirst())),
                    path: Array(path.dropFirst()),
                    values: values
                )
            }
            return array
        }
    }

    private static func sanitizedVSCodeChatSessionValue(
        _ value: Any?,
        nextPath: [VSCodeChatSessionPathComponent]
    ) -> Any {
        if let value, !(value is NSNull) {
            return value
        }

        guard let nextComponent = nextPath.first else {
            return [:]
        }

        switch nextComponent {
        case .key:
            return [String: Any]()
        case .index:
            return [Any]()
        }
    }

    private static func normalizeModelIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        if rawValue.hasPrefix("copilot/") {
            return String(rawValue.dropFirst("copilot/".count))
        }
        return rawValue
    }

    private static func nestedString(in object: [String: Any], path: [String]) -> String? {
        var current: Any? = object
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current as? String
    }

    private static func eventTranscriptEntry(
        type: String,
        payload: [String: Any]?,
        timestamp: Date?,
        entryID: String,
        toolNamesByCallID: [String: String]
    ) -> TranscriptEntry? {
        switch type {
        case "user.message":
            let body = TextSanitizer.clean(payload?["content"] as? String)
            return body.map {
                TranscriptEntry(id: entryID, role: .user, title: "User", body: $0, timestamp: timestamp)
            }
        case "assistant.message":
            let body = TextSanitizer.clean(payload?["content"] as? String)
            return body.map {
                TranscriptEntry(id: entryID, role: .assistant, title: "Assistant", body: $0, timestamp: timestamp)
            }
        case "session.start":
            let producer = payload?["producer"] as? String
            let version = payload?["copilotVersion"] as? String
            let body = [producer, version.map { "Version \($0)" }]
                .compactMap { $0 }
                .joined(separator: " • ")
            return TranscriptEntry(
                id: entryID,
                role: .system,
                title: "Session Started",
                body: body.isEmpty ? nil : body,
                timestamp: timestamp
            )
        case "session.model_change":
            let model = normalizeModelIdentifier(payload?["newModel"] as? String) ?? "Unknown model"
            return TranscriptEntry(
                id: entryID,
                role: .system,
                title: "Model Changed",
                body: model,
                timestamp: timestamp
            )
        case "session.info":
            let infoType = prettifyEventLabel(payload?["infoType"] as? String ?? "Info")
            let body = searchableEventText(
                type: type,
                payload: payload,
                toolNamesByCallID: toolNamesByCallID
            )
            return TranscriptEntry(
                id: entryID,
                role: .system,
                title: infoType,
                body: body,
                timestamp: timestamp
            )
        case "tool.execution_start":
            let toolName = payload?["toolName"] as? String ?? "Tool"
            let body = searchableEventText(
                type: type,
                payload: payload,
                toolNamesByCallID: toolNamesByCallID
            )
            return TranscriptEntry(
                id: entryID,
                role: .tool,
                title: "Started \(toolName)",
                body: body,
                timestamp: timestamp
            )
        case "tool.execution_complete":
            let toolCallId = payload?["toolCallId"] as? String
            let toolName = toolCallId.flatMap { toolNamesByCallID[$0] } ?? "Tool"
            let success = payload?["success"] as? Bool ?? true
            let body = searchableEventText(
                type: type,
                payload: payload,
                toolNamesByCallID: toolNamesByCallID
            )
            return TranscriptEntry(
                id: entryID,
                role: .tool,
                title: success ? "Completed \(toolName)" : "Failed \(toolName)",
                body: body,
                timestamp: timestamp
            )
        default:
            return nil
        }
    }

    private static func searchableEventText(
        type: String,
        payload: [String: Any]?,
        toolNamesByCallID: [String: String]
    ) -> String? {
        switch type {
        case "user.message", "assistant.message":
            return TextSanitizer.compact(payload?["content"] as? String)
        case "session.model_change":
            return normalizeModelIdentifier(payload?["newModel"] as? String)
        case "session.info":
            return TextSanitizer.compact(payload?["message"] as? String)
        case "tool.execution_start":
            let toolName = payload?["toolName"] as? String
            let details = flattenedSearchText(from: payload?["arguments"])
            return combinedSearchText(parts: [toolName, details])
        case "tool.execution_complete":
            let toolCallId = payload?["toolCallId"] as? String
            let toolName = toolCallId.flatMap { toolNamesByCallID[$0] }
            let details = combinedSearchText(
                parts: [
                    flattenedSearchText(from: payload?["result"]),
                    TextSanitizer.compact(payload?["error"] as? String)
                ]
            )
            return combinedSearchText(parts: [toolName, details])
        default:
            return nil
        }
    }

    private static func eventTimestamp(in object: [String: Any], payload: [String: Any]?) -> Date? {
        ISO8601DateCoding.parse(object["timestamp"] as? String)
            ?? ISO8601DateCoding.parse(payload?["startTime"] as? String)
    }

    private static func prettifyEventLabel(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func toolArgumentsSummary(_ value: Any?) -> String? {
        if let rawString = value as? String {
            return TextSanitizer.summarize(rawString, limit: 220)
        }

        guard let dictionary = value as? [String: Any] else { return nil }
        let preferredKeys = ["description", "question", "prompt", "command", "query", "pattern", "path", "url", "intent"]
        for key in preferredKeys {
            if let text = TextSanitizer.summarize(dictionary[key] as? String, limit: 220) {
                return text
            }
        }

        if let agentName = dictionary["agentName"] as? String {
            let detail = TextSanitizer.summarize(dictionary["description"] as? String, limit: 180)
            return [agentName, detail].compactMap { $0 }.joined(separator: " • ")
        }

        if let skill = dictionary["skill"] as? String {
            return skill
        }

        return nil
    }

    private static func toolCompletionSummary(_ payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let success = payload["success"] as? Bool ?? true
        if !success {
            if let error = TextSanitizer.compact(payload["error"] as? String) {
                return error
            }
            if let failure = nestedString(in: payload, path: ["result", "error"]) {
                return TextSanitizer.compact(failure)
            }
        }

        if let detail = nestedString(in: payload, path: ["result", "content"]),
           detail.count <= 140 {
            return TextSanitizer.compact(detail)
        }

        if let detail = nestedString(in: payload, path: ["result", "detailedContent"]),
           detail.count <= 140 {
            return TextSanitizer.compact(detail)
        }

        return nil
    }

    private static func flattenedSearchText(from value: Any?) -> String? {
        let flattened = flattenedSearchStrings(from: value)
        guard !flattened.isEmpty else { return nil }
        return combinedSearchText(parts: flattened.map { Optional($0) })
    }

    private static func flattenedSearchStrings(from value: Any?) -> [String] {
        switch value {
        case let string as String:
            return TextSanitizer.compact(SearchTextMatcher.visibleText(from: string)).map { [$0] } ?? []
        case let array as [Any]:
            return array.flatMap(flattenedSearchStrings)
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().flatMap { key in
                flattenedSearchStrings(from: dictionary[key])
            }
        default:
            return []
        }
    }

    private static func combinedSearchText(parts: [String?]) -> String? {
        var normalizedParts: [String] = []
        for part in parts {
            guard let cleaned = TextSanitizer.compact(part),
                  !cleaned.isEmpty else {
                continue
            }
            normalizedParts.append(cleaned)
        }
        guard !normalizedParts.isEmpty else {
            return nil
        }
        return normalizedParts.joined(separator: "\n")
    }
}

func fileDates(for url: URL) -> (created: Date?, modified: Date?) {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (
        attributes?[.creationDate] as? Date,
        attributes?[.modificationDate] as? Date
    )
}

func fileFingerprint(for path: String?) -> String {
    guard let path else { return "missing" }
    let url = URL(fileURLWithPath: path)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let modified = (attributes?[.modificationDate] as? Date).map { ISO8601DateCoding.string($0) ?? "unknown-date" } ?? "missing-date"
    let size = (attributes?[.size] as? NSNumber)?.stringValue ?? "missing-size"
    return "\(path)|\(modified)|\(size)"
}

func stringFingerprint(for value: String?) -> String {
    "value:\(value ?? "missing")"
}

func combinedFingerprint(paths: [String?], values: [String?] = []) -> String {
    (paths.map(fileFingerprint) + values.map(stringFingerprint(for:))).joined(separator: "||")
}

func loadJSONDictionary(from url: URL) throws -> [String: Any]? {
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func withSQLiteDatabase<T>(
    at databaseURL: URL,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    try withSQLiteContentionRetry {
        var database: OpaquePointer?
        // Use READWRITE so SQLite can create the SHM file required by WAL-mode databases.
        // READONLY fails when WAL/SHM files are absent (e.g. Cursor's state.vscdb after clean exit).
        let openResult = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK else {
            let details = sqliteErrorDetails(
                for: database,
                defaultCode: openResult,
                fallbackMessage: "Unknown SQLite open error for \(databaseURL.lastPathComponent)"
            )
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteStoreError.openFailed(code: details.code, message: details.message)
        }
        defer { sqlite3_close(database) }

        guard let database else {
            throw SQLiteStoreError.openFailed(
                code: SQLITE_CANTOPEN,
                message: "Unknown SQLite open error for \(databaseURL.lastPathComponent)"
            )
        }

        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, SQLiteContentionPolicy.externalReadBusyTimeoutMilliseconds)

        return try body(database)
    }
}

func loadSQLiteItemValue(from databaseURL: URL, key: String) throws -> String? {
    try loadSQLiteValue(from: databaseURL, table: "ItemTable", key: key)
}

func loadSQLiteItemValues(from databaseURL: URL, keyLike pattern: String) throws -> [String: String] {
    try loadSQLiteValues(from: databaseURL, table: "ItemTable", keyLike: pattern)
}

func loadSQLiteKeys(from databaseURL: URL, table: String, keyLike pattern: String) throws -> [String] {
    try withSQLiteDatabase(at: databaseURL) { database in
        let sql = """
        SELECT key
        FROM \(table)
        WHERE key LIKE ?
        ORDER BY key ASC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let details = sqliteErrorDetails(for: database, fallbackMessage: "Unknown SQLite prepare error")
            throw SQLiteStoreError.prepareFailed(code: details.code, message: details.message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT_UTILITIES)

        var keys: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                guard let key = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else {
                    continue
                }
                keys.append(key)
            case SQLITE_DONE:
                return keys
            default:
                let details = sqliteErrorDetails(for: database, fallbackMessage: "Unknown SQLite step error")
                throw SQLiteStoreError.stepFailed(code: details.code, message: details.message)
            }
        }
    }
}

func loadSQLiteValue(from databaseURL: URL, table: String, key: String) throws -> String? {
    try withSQLiteDatabase(at: databaseURL) { database in
        let sql = "SELECT value FROM \(table) WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let details = sqliteErrorDetails(for: database, fallbackMessage: "Unknown SQLite prepare error")
            throw SQLiteStoreError.prepareFailed(code: details.code, message: details.message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT_UTILITIES)
        let stepResult = sqlite3_step(statement)
        switch stepResult {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        case SQLITE_DONE:
            return nil
        default:
            let details = sqliteErrorDetails(for: database, fallbackMessage: "Unknown SQLite step error")
            throw SQLiteStoreError.stepFailed(code: details.code, message: details.message)
        }
    }
}

func loadSQLiteValues(from databaseURL: URL, table: String, keyLike pattern: String) throws -> [String: String] {
    try withSQLiteDatabase(at: databaseURL) { database in
        let sql = """
        SELECT key, value
        FROM \(table)
        WHERE key LIKE ?
        ORDER BY key ASC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let details = sqliteErrorDetails(for: database, fallbackMessage: "Unknown SQLite prepare error")
            throw SQLiteStoreError.prepareFailed(code: details.code, message: details.message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, pattern, -1, SQLITE_TRANSIENT_UTILITIES)

        var values: [String: String] = [:]
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                guard let key = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                      let value = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                    continue
                }
                values[key] = value
            case SQLITE_DONE:
                return values
            default:
                let details = sqliteErrorDetails(for: database, fallbackMessage: "Unknown SQLite step error")
                throw SQLiteStoreError.stepFailed(code: details.code, message: details.message)
            }
        }
    }
}
