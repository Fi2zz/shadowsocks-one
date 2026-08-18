import Foundation
import Network
@testable import SharedCore

actor LocalAEADEchoServer {
    private let listener: NWListener

    init(port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw CocoaError(.coderInvalidValue)
        }
        self.listener = try NWListener(using: .tcp, on: endpointPort)
    }

    func start() {
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                guard let data else { return }
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: .global())
    }

    func stop() {
        listener.cancel()
    }
}
