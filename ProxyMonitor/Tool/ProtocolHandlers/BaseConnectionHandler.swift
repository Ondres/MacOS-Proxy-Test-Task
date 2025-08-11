import Foundation
import Network

class BaseConnectionHandler: NSObject, ConnectionHandlerProtocol {
    var origins: [ObjectIdentifier: NWConnection] = [:]
    let lock = NSLock()

    // Create upstream TCP connection that bypasses system proxy (prevents proxy loops)
    func makeOrigin(host: String, port: UInt16) -> NWConnection {
        let params = NWParameters.tcp
        params.preferNoProxies = true
        return NWConnection(host: .init(host), port: .init(rawValue: port)!, using: params)
    }
    // Retain/release helpers
    func retainOrigin(_ origin: NWConnection, for client: NWConnection) {
        lock.lock()
        origins[ObjectIdentifier(client)] = origin
        lock.unlock()
    }
    func releaseOrigin(for client: NWConnection) {
        lock.lock()
        _ = origins.removeValue(forKey: ObjectIdentifier(client))
        lock.unlock()
    }

    // Protocol stubs to override
    func canHandle(firstBytes: Data) -> Bool { fatalError("Override in subclass") }
    func handle(client: NWConnection, firstBytes: Data) { fatalError("Override in subclass") }
}
