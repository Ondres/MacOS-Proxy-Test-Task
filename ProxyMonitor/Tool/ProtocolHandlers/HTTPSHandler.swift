import Foundation
import Network

final class HTTPSHandler: BaseConnectionHandler {
    override func canHandle(firstBytes: Data) -> Bool {
        guard let first = URLHandlerHelper.firstLine(from: firstBytes) else { return false }
        return first.uppercased().hasPrefix(Constants.HTTPMethod.connect.rawValue)
    }
    
    override func handle(client: NWConnection, firstBytes: Data) {
        // Set client state update handler
        client.stateUpdateHandler = { [weak self] st in
            switch st {
            case .cancelled:
                self?.releaseOrigin(for: client)
            case .failed(let err):
                Logger.logError("HTTPS: client state=failed \(err)")
            default:
                break
            }
        }
        
        // Read full CONNECT request
        readFullConnect(client: client, initial: firstBytes)
    }
    
    // Reads full CONNECT request
    private func readFullConnect(client: NWConnection, initial: Data) {
        var buffer = initial
        let sep = Data("\r\n\r\n".utf8)
        
        if finishIfReady(buffer: buffer, sep: sep, completion: { headerData, tlsRemainder in
            self.processHeaderData(client: client, headerData: headerData, tlsRemainder: tlsRemainder)
        }) {
            return
        }
        
        Logger.logInformation("HTTPS: waiting for more header bytes…")
        receiveMoreForConnect(client: client, buffer: buffer, sep: sep)
    }
    
    // Processes header data after full CONNECT is read
    private func processHeaderData(client: NWConnection, headerData: Data, tlsRemainder: Data) {
        guard let header = String(data: headerData, encoding: .utf8),
              let firstLine = header.components(separatedBy: Constants.crlf).first else {
            Logger.logError("HTTPS: invalid header (utf8/first line)")
            client.cancel()
            return
        }
        
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            Logger.logError("HTTPS: bad request line parts=\(parts.count)")
            client.cancel()
            return
        }
        
        let hp = String(parts[1])
        let (host, port) = URLHandlerHelper.splitHostPort(hp, defaultPort: Constants.httpsPort)
        
        if let url = URL(string: "https://\(host)") {
            Logger.logURL(url)
        }
        
        let ok = Constants.connectionEstablishedMessage.data(using: .utf8)!
        client.send(content: ok, completion: .contentProcessed { _ in
            let parameters = NWParameters.tcp
            parameters.preferNoProxies = true
            
            let origin = NWConnection(host: .init(host),
                                      port: .init(rawValue: UInt16(port))!,
                                      using: parameters)
            
            self.retainOrigin(origin, for: client)
            origin.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting(let err):
                    Logger.logError("HTTPS: origin state=waiting error=\(err). \(host) \(port). \(firstLine)")
                case .ready:
                    if !tlsRemainder.isEmpty {
                        origin.send(content: tlsRemainder, completion: .contentProcessed { _ in
                            URLHandlerHelper.pipe(client, origin) {
                                self?.releaseOrigin(for: client)
                            }
                        })
                    } else {
                        URLHandlerHelper.pipe(client, origin) {
                            self?.releaseOrigin(for: client)
                        }
                    }
                case .failed(let err):
                    Logger.logError("HTTPS: origin state=failed error=\(err). \(host) \(port)")
                    client.cancel()
                    origin.cancel()
                    self?.releaseOrigin(for: client)
                case .cancelled:
                    client.cancel()
                    self?.releaseOrigin(for: client)
                default:
                    break
                }
            }
            
            origin.start(queue: .global())
        })
    }
    
    // Checks if the buffer contains the full header
    private func finishIfReady(buffer: Data, sep: Data, completion: @escaping (Data, Data) -> Void) -> Bool {
        if let r = buffer.range(of: sep) {
            let head = buffer.subdata(in: 0..<r.upperBound)
            let rem = (r.upperBound < buffer.endIndex)
            ? buffer.subdata(in: r.upperBound..<buffer.endIndex) : Data()
            completion(head, rem)
            return true
        }
        return false
    }
    
    // Receives more data for CONNECT request
    private func receiveMoreForConnect(client: NWConnection, buffer: Data, sep: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: Constants.maxDataLenght) { d, _, eof, err in
            if let err = err {
                Logger.logError("HTTPS: receive error \(err)")
                client.cancel()
                return
            }
            if eof {
                Logger.logError("HTTPS: EOF before full header")
                client.cancel()
                return
            }
            guard let d = d, !d.isEmpty else {
                self.receiveMoreForConnect(client: client, buffer: buffer, sep: sep)
                return
            }
            var newBuffer = buffer
            newBuffer.append(d)
            if !self.finishIfReady(buffer: newBuffer, sep: sep, completion: { headerData, tlsRemainder in
                self.processHeaderData(client: client, headerData: headerData, tlsRemainder: tlsRemainder)
            }) {
                self.receiveMoreForConnect(client: client, buffer: newBuffer, sep: sep)
            }
        }
    }
}

