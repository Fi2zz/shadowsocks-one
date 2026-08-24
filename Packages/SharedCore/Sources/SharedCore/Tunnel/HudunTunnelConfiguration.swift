import Foundation

/// 护盾线路 renew 产物 → 隧道扩展启动参数。
public struct HudunTunnelLaunchConfiguration: Codable, Equatable {
    public var endpointHost: String
    public var endpointPort: UInt16
    public var peerPublicKeyBase64: String
    public var tunnelAddress: String
    public var dnsServers: [String]
    public var mtu: UInt16
    public var keepAliveInterval: UInt16
    public var lineID: Int
    public var lineName: String
    public var expiresAt: Date?

    public init(endpointHost: String, endpointPort: UInt16,
                peerPublicKeyBase64: String, tunnelAddress: String,
                dnsServers: [String], mtu: UInt16,
                keepAliveInterval: UInt16 = 25,
                lineID: Int = 0, lineName: String = "",
                expiresAt: Date? = nil) {
        self.endpointHost = endpointHost
        self.endpointPort = endpointPort
        self.peerPublicKeyBase64 = peerPublicKeyBase64
        self.tunnelAddress = tunnelAddress
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.keepAliveInterval = keepAliveInterval
        self.lineID = lineID
        self.lineName = lineName
        self.expiresAt = expiresAt
    }
}

/// 活动隧道模式：决定扩展走 Shadowsocks 还是 WireGuard 数据面。
public enum ActiveTunnelMode: String, Codable {
    case shadowsocks
    case wireguard
}
