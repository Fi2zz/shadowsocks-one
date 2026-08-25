import Foundation

public struct BrowserBookmarkEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let createdAt: Date

    public init(id: UUID = UUID(), url: URL, title: String, createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }
}
