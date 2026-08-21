import Foundation

public struct BrowserHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let visitedAt: Date

    public init(id: UUID = UUID(), url: URL, title: String, visitedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}
