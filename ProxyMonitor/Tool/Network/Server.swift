import Foundation
import Network

final class Server {
    var onAccept: ((NWConnection) -> Void)?

    private var listener: NWListener?
    // Concurrent queue for the listener to avoid head-of-line blocking across connections
    private let listenQueue = DispatchQueue(label: "test.ProxyMonitor.server", attributes: .concurrent)

    func start(port: UInt16) throws {
        guard listener == nil else { return }

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let l = try NWListener(using: .tcp, on: nwPort)

        l.newConnectionHandler = { [weak self] conn in
            // Dedicated queue per connection to isolate receive/send callbacks
            let cq = DispatchQueue(label: "proxy.conn.\(UUID().uuidString)")
            conn.start(queue: cq)
            self?.onAccept?(conn)
        }

        l.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Logger.logInformation("Server: listening on port \(nwPort.rawValue)")
            case .failed(let err):
                Logger.logError("Server: failed \(err)")
            case .cancelled:
                Logger.logInformation("Server: cancelled")
            default:
                break
            }
        }

        l.start(queue: listenQueue)
        listener = l
    }

    func stop() {
        // Stop accepting new connections
        listener?.cancel()
        listener = nil
    }
}
