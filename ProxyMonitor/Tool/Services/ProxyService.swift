import Foundation
import Network

final class ProxyService {
    private let server: Server
    private let handlers: [BaseConnectionHandler]

    // Track live client connections to allow graceful shutdown
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let clientsLock = NSLock()

    init() {
        self.server = Server()
        self.handlers = [
            HTTPHandler(),
            HTTPSHandler(),
            SOCKSHandler()
        ]

        // Register per-connection tracking and dispatch handling
        self.server.onAccept = { [weak self] conn in
            self?.register(conn)
            self?.handleNewConnection(conn)
        }
    }

    func start(port: UInt16) {
        do {
            try self.server.start(port: port)
        } catch {
            Logger.logError("Failed to start server: \(error)")
        }
    }
    
    func stop() {
        // 1) Stop accepting new connections
        server.stop()

        // 2) Cancel all live client connections
        clientsLock.lock()
        let allClients = clients.values
        clients.removeAll()
        clientsLock.unlock()
        allClients.forEach { $0.cancel() }

        // 3) Additionally, cancel all upstreams held by handlers (extra safety)
        handlers.forEach { handler in
            handler.lock.lock()
            let upstreams = handler.origins.values
            handler.origins.removeAll()
            handler.lock.unlock()
            upstreams.forEach { $0.cancel() }
        }
    }

    // MARK: - Connection tracking

    private func register(_ c: NWConnection) {
        let key = ObjectIdentifier(c)
        clientsLock.lock(); clients[key] = c; clientsLock.unlock()

        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled:
                self?.unregister(c)
            default:
                break
            }
        }
    }

    private func unregister(_ c: NWConnection) {
        clientsLock.lock()
        _ = clients.removeValue(forKey: ObjectIdentifier(c))
        clientsLock.unlock()
    }

    private func handleNewConnection(_ client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: Constants.maxDataLenght) { [weak self] data, _, _, _ in
            guard let self = self else { return }
            guard let data = data, !data.isEmpty else {
                client.cancel()
                return
            }

            if let handler = self.handlers.first(where: { $0.canHandle(firstBytes: data) }) {
                handler.handle(client: client, firstBytes: data)
            } else {
                Logger.logError("No handler found for incoming connection")
                client.cancel()
            }
        }
    }
}
