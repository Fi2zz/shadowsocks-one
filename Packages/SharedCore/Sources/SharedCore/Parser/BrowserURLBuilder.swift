import Foundation

public enum BrowserURLBuilder {
    private static let searchBase = "https://www.bing.com/search"

    public static func makeURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if containsWhitespace(trimmed) {
            return searchURL(for: trimmed)
        }
        return makeNavigationURL(from: trimmed)
    }

    private static func containsWhitespace(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: searchBase)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    private static func makeNavigationURL(from trimmed: String) -> URL? {
        if trimmed.contains("://") {
            return explicitSchemeURL(from: trimmed)
        }
        guard trimmed.contains(".") else {
            return searchURL(for: trimmed)
        }
        return URL(string: "https://\(trimmed)")
    }

    private static func explicitSchemeURL(from trimmed: String) -> URL? {
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}
