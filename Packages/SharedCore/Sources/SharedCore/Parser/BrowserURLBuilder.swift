import Foundation

public enum BrowserURLBuilder {
    public static func makeURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}
