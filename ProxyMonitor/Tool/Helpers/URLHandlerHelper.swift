import Foundation
import Network

final class URLHandlerHelper {
    // Extract the first line from raw bytes (up to CRLF)
    static func firstLine(from firstBytes: Data) -> String? {
        guard let s = String(data: firstBytes, encoding: .utf8) else { return nil }
        return s.components(separatedBy: Constants.crlf).first
    }
    
    // Bidirectional pipe with inactivity timeout and safe shutdown on a single state queue
    static func pipe(
        _ a: NWConnection,
        _ b: NWConnection,
        inactivity: TimeInterval = Constants.connectionInactiveTime,
        onClose: (() -> Void)? = nil
    ) {
        let stateQ = DispatchQueue(label: "proxy.pipe.state.\(UUID().uuidString)")
        var closed = false
        
        let timer = DispatchSource.makeTimerSource(queue: stateQ)
        func scheduleKick() {
            timer.schedule(deadline: .now() + inactivity)
        }
        func finish(_ reason: String) {
            stateQ.async {
                guard !closed else { return }
                closed = true
                timer.cancel()
                a.cancel()
                b.cancel()
                onClose?()
            }
        }
        timer.setEventHandler { finish("idle-timeout \(Int(inactivity))s") }
        timer.resume()
        scheduleKick()
        
        func pump(_ from: NWConnection, _ to: NWConnection, dir: String) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { d, _, eof, err in
                if let err = err {
                    finish("recv-error \(err)")
                    return
                }
                if let d = d, !d.isEmpty {
                    stateQ.async { scheduleKick() }
                    to.send(content: d, completion: .contentProcessed { _ in
                        pump(from, to, dir: dir)
                    })
                } else if eof {
                    finish("eof \(dir)")
                } else {
                    pump(from, to, dir: dir)
                }
            }
        }
        
        pump(a, b, dir: "client->server")
        pump(b, a, dir: "server->client")
    }
    
    // Split "host:port" supporting IPv6 literals like "[2001:db8::1]:443"
    static func splitHostPort(_ hp: String, defaultPort: Int) -> (host: String, port: Int) {
        // IPv6 literal in brackets
        if hp.hasPrefix("["),
           let rb = hp.firstIndex(of: "]") {
            let start = hp.index(after: hp.startIndex)
            let host = String(hp[start..<rb]) // strip brackets
            let rest = hp[hp.index(after: rb)...]
            if let colon = rest.firstIndex(of: ":"),
               let p = Int(rest[rest.index(after: colon)...]) {
                return (host, p)
            }
            return (host, defaultPort)
        }
        // IPv4 / hostname with optional ":port"
        if let i = hp.lastIndex(of: ":"), let p = Int(hp[hp.index(after: i)...]) {
            return (String(hp[..<i]), p)
        }
        return (hp, defaultPort)
    }
    
    // Extract host and port from HTTP headers or from the URI (fallback)
    static func extractHostPort(fromHeaderData d: Data, uri: String) -> (String, Int) {
        if let s = String(data: d, encoding: .utf8) {
            for line in s.components(separatedBy: Constants.crlf) {
                if line.lowercased().hasPrefix("host:") {
                    let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let i = raw.lastIndex(of: ":"), let p = Int(raw[raw.index(after: i)...]) {
                        let host = String(raw[..<i])
                        return (host, p)
                    }
                    return (String(raw), Constants.httpPort)
                }
            }
        }
        if let u = URL(string: uri), let h = u.host {
            let port = u.port ?? (u.scheme?.lowercased() == "https" ? Constants.httpsPort : Constants.httpPort)
            return (h, port)
        }
        return (Constants.localHostName, Constants.httpPort)
    }
}
