import Foundation

/// 线路持久化 DTO（HudunLine 定义在 API 库中，不便直接加 Codable）。
private struct HudunLineRecord: Codable {
    var id: Int
    var name: String
    var typeName: String
    var groupName: String
    var flagName: String
    var ip: String
    var imageURL: String?
    var vipState: Int
    var isBlocked: Bool
    var tier: String

    init(_ line: HudunLine) {
        id = line.id; name = line.name; typeName = line.typeName
        groupName = line.groupName; flagName = line.flagName; ip = line.ip
        imageURL = line.imageURL; vipState = line.vipState
        isBlocked = line.isBlocked; tier = line.tier
    }

    var line: HudunLine {
        HudunLine(id: id, name: name, typeName: typeName, groupName: groupName,
                  flagName: flagName, ip: ip, imageURL: imageURL,
                  vipState: vipState, isBlocked: isBlocked, tier: tier)
    }
}

private struct HudunSnapshot: Codable {
    var records: [HudunLineRecord]
    var cachedAt: Date
}

/// 线路快照持久化（文档 §1「数据层快照」——缓存展示用，取配置仍现取现用）。
enum HudunLineCache {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hudun_lines.json")
    }

    static func load() -> [HudunLine] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(HudunSnapshot.self, from: data) else {
            return []
        }
        return snapshot.records.map(\.line)
    }

    static func save(_ lines: [HudunLine]) {
        let snapshot = HudunSnapshot(records: lines.map(HudunLineRecord.init), cachedAt: Date())
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// 选中线路记忆（UserDefaults 存 id，重进后回显勾选态）。
enum HudunSelectionMemory {
    private static let key = "hudun.selectedLine.id"

    static var savedLineID: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: key)
            return value == 0 ? nil : value
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
