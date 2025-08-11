import Foundation
import Network

final class HTTPHandler: BaseConnectionHandler {    
    // Checks if the data is an HTTP request (not CONNECT)
    override func canHandle(firstBytes: Data) -> Bool {
        guard let first = URLHandlerHelper.firstLine(from: firstBytes) else { return false }
        let up = first.uppercased()
        return !up.hasPrefix(Constants.HTTPMethod.connect.rawValue) && (
            up.hasPrefix(Constants.HTTPMethod.get.rawValue) ||
            up.hasPrefix(Constants.HTTPMethod.post.rawValue) ||
            up.hasPrefix(Constants.HTTPMethod.head.rawValue) ||
            up.hasPrefix(Constants.HTTPMethod.put.rawValue) ||
            up.hasPrefix(Constants.HTTPMethod.delete.rawValue) ||
            up.hasPrefix(Constants.HTTPMethod.options.rawValue) ||
            up.hasPrefix(Constants.HTTPMethod.patch.rawValue)
        )
    }
    
    // Handles HTTP request by parsing, logging, and piping data
    override func handle(client: NWConnection, firstBytes: Data) {
        // Set client state update handler
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled:
                self?.releaseOrigin(for: client)
            case .failed(let err):
                Logger.logError("HTTP: client state=failed \(err)")
            default:
                break
            }
        }
        
        // Parse and process the request
        guard let firstLine = URLHandlerHelper.firstLine(from: firstBytes) else {
            Logger.logError("HTTP: invalid first line")
            client.cancel()
            return
        }
        processRequest(client: client, firstLine: firstLine, firstBytes: firstBytes)
    }
    
    // Processes the HTTP request
    private func processRequest(client: NWConnection, firstLine: String, firstBytes: Data) {
        let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count > 1 else {
            Logger.logError("HTTP: bad request line parts=\(parts.count)")
            client.cancel()
            return
        }
        
        let method = String(parts[0])
        let uri = String(parts[1])
        let (host, port) = URLHandlerHelper.extractHostPort(fromHeaderData: firstBytes, uri: uri)
        
        // Log the URL
        logURL(uri: uri, host: host, port: port, method: method)
        
        // Set up server connection
        setupServerConnection(client: client, host: host, port: port, firstBytes: firstBytes)
    }
    
    // Logs the URL or request details
    private func logURL(uri: String, host: String, port: Int, method: String) {
        if let absURL = URL(string: uri), absURL.scheme != nil, absURL.host != nil {
            Logger.logURL(absURL)
        } else {
            var comps = URLComponents()
            comps.scheme = Constants.httpScheme
            comps.host = host
            if port != Constants.httpPort {
                comps.port = port
            }
            comps.percentEncodedPath = uri.hasPrefix("/") ? uri : "/" + uri
            if let url = comps.url {
                Logger.logURL(url)
            } else if let url = URL(string: "http://\(host)\(uri.hasPrefix("/") ? uri : "/\(uri)")") {
                Logger.logURL(url)
            } else {
                Logger.logError("HTTP: invalid URL for \(method) \(uri) (Host: \(host):\(port))")
            }
        }
    }
    
    // Sets up and starts server connection
    private func setupServerConnection(client: NWConnection, host: String, port: Int, firstBytes: Data) {
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true // Avoid proxy loop
        
        let server = NWConnection(host: .init(host),
                                  port: .init(rawValue: UInt16(port))!,
                                  using: parameters)
        
        retainOrigin(server, for: client)
        server.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let err):
                Logger.logError("HTTP: server state=waiting error=\(err). \(host):\(port)")
                client.cancel()
                server.cancel()
                self?.releaseOrigin(for: client)
            case .ready:
                server.send(content: firstBytes, completion: .contentProcessed { err in
                    if let err = err {
                        Logger.logError("HTTP: failed to send request: \(err)")
                        client.cancel()
                        server.cancel()
                        self?.releaseOrigin(for: client)
                        return
                    }
                    URLHandlerHelper.pipe(client, server) {
                        self?.releaseOrigin(for: client)
                    }
                })
            case .failed(let err):
                Logger.logError("HTTP: server state=failed error=\(err). \(host):\(port)")
                client.cancel()
                server.cancel()
                self?.releaseOrigin(for: client)
            case .cancelled:
                client.cancel()
                self?.releaseOrigin(for: client)
            default:
                break
            }
        }
        
        server.start(queue: .global())
    }
}
