import Foundation

public protocol ShadowsocksProbing: Sendable {
    func probe(using config: ConnectionConfig, target: ConnectionProbeTarget) async throws
}
