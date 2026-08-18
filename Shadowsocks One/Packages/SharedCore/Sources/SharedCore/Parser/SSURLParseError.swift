public enum SSURLParseError: Error, Equatable, Sendable {
    case invalidScheme
    case malformedURL
    case missingHost
    case missingPort
    case invalidPort
    case invalidUserInfo
    case unsupportedCipher(String)
    case invalidBase64
    case emptyPassword
}
