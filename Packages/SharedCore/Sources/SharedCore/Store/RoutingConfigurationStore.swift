import Foundation

public final class RoutingConfigurationStore {
    private let jsonURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(appGroupID: String) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        self.jsonURL = containerURL.appendingPathComponent("routing-configuration.json")
    }

    init(jsonURL: URL) {
        self.jsonURL = jsonURL
    }

    public func save(_ configuration: RoutingConfiguration) throws {
        let data = try encoder.encode(configuration)
        try data.write(to: jsonURL, options: .atomic)
    }

    public func load() throws -> RoutingConfiguration {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return .default
        }

        let data = try Data(contentsOf: jsonURL)
        return try decoder.decode(RoutingConfiguration.self, from: data)
    }
}
