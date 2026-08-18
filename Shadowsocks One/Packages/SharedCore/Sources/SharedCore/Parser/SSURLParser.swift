import Foundation

public protocol SSURLParsing {
    func parse(_ raw: String) throws -> ServerProfile
}

public struct SSURLParser: SSURLParsing {
    public init() {}

    public func parse(_ raw: String) throws -> ServerProfile {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ss://") else {
            throw SSURLParseError.invalidScheme
        }

        let rawBody = String(trimmed.dropFirst(5))
        let fragmentParts = rawBody.split(separator: "#", maxSplits: 1).map(String.init)
        let body = fragmentParts[0]
        let remark = fragmentParts.count == 2 ? fragmentParts[1].removingPercentEncoding : nil

        if body.contains("@") {
            return try parseSIP002(body: body, remark: remark)
        }

        return try parseLegacy(body: body, remark: remark)
    }

    private func parseSIP002(body: String, remark: String?) throws -> ServerProfile {
        guard let components = URLComponents(string: "ss://\(body)") else {
            throw SSURLParseError.malformedURL
        }
        guard let host = components.host, !host.isEmpty else {
            throw SSURLParseError.missingHost
        }
        guard let portValue = components.port else {
            throw SSURLParseError.missingPort
        }
        guard let port = UInt16(exactly: portValue) else {
            throw SSURLParseError.invalidPort
        }
        guard let user = components.user else {
            throw SSURLParseError.invalidUserInfo
        }

        let rawUserInfo: String
        if let password = components.password {
            rawUserInfo = "\(user):\(password)"
        } else {
            rawUserInfo = user
        }

        let userInfo = decodeUserInfo(rawUserInfo)
        let userParts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard userParts.count == 2 else {
            throw SSURLParseError.invalidUserInfo
        }

        let method = try mapCipher(String(userParts[0]))
        let password = String(userParts[1])
        guard !password.isEmpty else {
            throw SSURLParseError.emptyPassword
        }

        let pluginValue = components.queryItems?.first(where: { $0.name == "plugin" })?.value
        let pluginParts = pluginValue?.split(separator: ";", maxSplits: 1).map(String.init) ?? []

        return ServerProfile(
            host: host,
            port: port,
            method: method,
            password: password,
            remark: remark,
            plugin: pluginParts.first,
            pluginOptions: pluginParts.count == 2 ? pluginParts[1] : nil
        )
    }

    private func parseLegacy(body: String, remark: String?) throws -> ServerProfile {
        let decoded = try decodeBase64(body)
        guard let atIndex = decoded.lastIndex(of: "@") else {
            throw SSURLParseError.invalidUserInfo
        }

        let userInfo = String(decoded[..<atIndex])
        let hostPort = String(decoded[decoded.index(after: atIndex)...])
        let userParts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard userParts.count == 2 else {
            throw SSURLParseError.invalidUserInfo
        }
        guard let portSeparator = hostPort.lastIndex(of: ":") else {
            throw SSURLParseError.missingPort
        }

        let host = String(hostPort[..<portSeparator])
        let portString = String(hostPort[hostPort.index(after: portSeparator)...])
        guard !host.isEmpty else {
            throw SSURLParseError.missingHost
        }
        guard let port = UInt16(portString) else {
            throw SSURLParseError.invalidPort
        }

        let method = try mapCipher(String(userParts[0]))
        let password = String(userParts[1])
        guard !password.isEmpty else {
            throw SSURLParseError.emptyPassword
        }

        return ServerProfile(
            host: host,
            port: port,
            method: method,
            password: password,
            remark: remark
        )
    }

    private func decodeUserInfo(_ raw: String) -> String {
        if raw.contains(":") {
            return raw.removingPercentEncoding ?? raw
        }

        return (try? decodeBase64(raw)) ?? raw.removingPercentEncoding ?? raw
    }

    private func decodeBase64(_ raw: String) throws -> String {
        let normalized = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized.padding(
            toLength: ((normalized.count + 3) / 4) * 4,
            withPad: "=",
            startingAt: 0
        )

        guard let data = Data(base64Encoded: padded),
              let decoded = String(data: data, encoding: .utf8) else {
            throw SSURLParseError.invalidBase64
        }

        return decoded
    }

    private func mapCipher(_ raw: String) throws -> CipherMethod {
        guard let method = CipherMethod(rawValue: raw.lowercased()) else {
            throw SSURLParseError.unsupportedCipher(raw)
        }

        return method
    }
}
