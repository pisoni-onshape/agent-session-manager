import Foundation

public actor TranscriptDocumentCache {
    private struct CachedTranscript {
        let fingerprint: String
        let document: TranscriptDocument
    }

    private var documentsBySessionID: [String: CachedTranscript] = [:]

    public init() {}

    public func document(for record: SessionRecord) throws -> TranscriptDocument {
        if let cached = documentsBySessionID[record.id],
           cached.fingerprint == record.fingerprint {
            return cached.document
        }

        let document = try TranscriptPreviewExtractor.loadTranscript(for: record)
        documentsBySessionID[record.id] = CachedTranscript(
            fingerprint: record.fingerprint,
            document: document
        )
        // Warm the Markdown parse caches for the chat messages shown by default so the
        // transcript viewer renders and scrolls without parsing rows on the main thread.
        MarkdownRendering.warmCaches(for: document.entries.compactMap { $0.isChatMessage ? $0.body : nil })
        return document
    }

    public func search(records: [SessionRecord], query: String) throws -> [SessionSearchMatch] {
        try records.compactMap { record in
            try document(for: record).sessionSearchMatch(for: query)
        }
    }
}
