import Foundation
import Network
import Darwin.POSIX.netinet

struct SOCKS5Address {
    let host: String
    let port: Int
}

final class SOCKSHandler: BaseConnectionHandler {
    // MARK: - SOCKS5 field offsets & lengths
    private let greetingMethodsOffset = 2         // METHODS start
    private let requestAddressOffset = 4          // DST.ADDR start
    private let ipv4OctetCount = 4
    private let ipv6ByteCount = 16
    private let portByteCount = 2
    private let maxDomainLenght = 255
    
    private let requestBaseHeaderLength = 4       // VER,CMD,RSV,ATYP
    private let bitsPerByte = 8
    private let version: UInt8 = 0x05
    private let connectCommand: UInt8 = 0x01
    private let reserved: UInt8 = 0x00
    private let noAuthMethod: UInt8 = 0x00
    private let noAcceptableMethod: UInt8 = 0xFF
    private let generalFailureStatus: UInt8 = 0x01
    private let successStatus: UInt8 = 0x00
    private let greetingResponseSuccess = Data([0x05, 0x00]) // version, noAuthMethod
    private let greetingResponseFailure = Data([0x05, 0xFF]) // version, noAcceptableMethod
    
    private let minConnectRequestLength = 7 // ATYP + min DST.ADDR (1 byte) + DST.PORT (2 bytes)
    private let addressTypeIPv4: UInt8 = 0x01
    private let addressTypeDomain: UInt8 = 0x03
    private let addressTypeIPv6: UInt8 = 0x04
    
    private let bufferVersionIndex = 0
    private let bufferConnectCommandIndex = 1
    private let bufferMinimumCount = 2
    private let bufferAddressTypeIndex = 3
    
    override func canHandle(firstBytes: Data) -> Bool {
        return firstBytes.first == version // Checks if the first byte is 0x05, indicating SOCKS5 protocol (RFC 1928)
    }
    
    override func handle(client: NWConnection, firstBytes: Data) {
        // Set client state handler
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled:
                self?.releaseOrigin(for: client)
            case .failed(let err):
                Logger.logError("SOCKS5: Client state failed: \(err)")
            default:
                break
            }
        }
        
        // Process SOCKS5 greeting
        readGreeting(client: client, initial: firstBytes)
    }
    
    // Reads and processes SOCKS5 greeting
    private func readGreeting(client: NWConnection, initial: Data) {
        var buffer = initial
        
        // Validate greeting format: VER, NMETHODS, METHODS...
        guard buffer.count >= bufferMinimumCount, buffer[bufferVersionIndex] == version else {
            Logger.logError("SOCKS5: Invalid greeting")
            client.cancel()
            return
        }
        
        let nmethods = Int(buffer[bufferConnectCommandIndex])
        let expectedLength = bufferMinimumCount + nmethods
        
        if buffer.count >= expectedLength {
            processGreeting(client: client, buffer: buffer, nmethods: nmethods)
        } else {
            receiveMoreGreeting(client: client, buffer: buffer, expectedLength: expectedLength)
        }
    }
    
    // Processes greeting data when enough bytes are received
    private func processGreeting(client: NWConnection, buffer: Data, nmethods: Int) {
        let start = greetingMethodsOffset
        let end   = greetingMethodsOffset + nmethods
        guard buffer.count >= end else { return }
        let methods = buffer.subdata(in: start..<end)
        
        if methods.contains(noAuthMethod) {
            client.send(content: greetingResponseSuccess, completion: .contentProcessed { error in
                if let error = error {
                    Logger.logError("SOCKS5: Failed to send greeting response: \(error)")
                    client.cancel()
                    return
                }
                // Proceed to read CONNECT request
                self.readRequest(client: client)
            })
        } else {
            Logger.logError("SOCKS5: No supported authentication method")
            client.send(content: greetingResponseFailure, completion: .contentProcessed { _ in
                client.cancel()
            })
        }
    }
    
    // Receives more greeting bytes if needed
    private func receiveMoreGreeting(client: NWConnection, buffer: Data, expectedLength: Int) {
        client.receive(minimumIncompleteLength: 1, maximumLength: expectedLength - buffer.count) { data, _, eof, error in
            if let error = error {
                Logger.logError("SOCKS5: Greeting receive error: \(error)")
                client.cancel()
                return
            }
            if eof {
                Logger.logError("SOCKS5: EOF during greeting")
                client.cancel()
                return
            }
            guard let data = data, !data.isEmpty else {
                self.receiveMoreGreeting(client: client, buffer: buffer, expectedLength: expectedLength)
                return
            }
            var newBuffer = buffer
            newBuffer.append(data)
            if newBuffer.count >= expectedLength {
                self.processGreeting(client: client, buffer: newBuffer, nmethods: Int(newBuffer[1]))
            } else {
                self.receiveMoreGreeting(client: client, buffer: newBuffer, expectedLength: expectedLength)
            }
        }
    }
    
    // Reads CONNECT request
    private func readRequest(client: NWConnection) {
        var buffer = Data()
        
        client.receive(minimumIncompleteLength: 1, maximumLength: maxDomainLenght + portByteCount) { data, _, eof, error in
            if let error = error {
                Logger.logError("SOCKS5: Request receive error: \(error)")
                client.cancel()
                return
            }
            if eof {
                Logger.logError("SOCKS5: EOF during request")
                client.cancel()
                return
            }
            guard let data = data, !data.isEmpty else {
                self.readRequest(client: client)
                return
            }
            buffer.append(data)
            self.processRequest(client: client, buffer: buffer)
        }
    }
    
    // Processes CONNECT request
    private func processRequest(client: NWConnection, buffer: Data) {
        guard buffer.count >= minConnectRequestLength,
              buffer[bufferVersionIndex] == version,
              buffer[bufferConnectCommandIndex] == connectCommand else {
            Logger.logError("SOCKS5: Invalid CONNECT request format or command")
            self.sendReply(to: client, status: generalFailureStatus)
            client.cancel()
            return
        }
        
        let addressType = buffer[bufferAddressTypeIndex]
        let address: SOCKS5Address?
        switch addressType {
        case addressTypeIPv4:
            address = processIPv4Address(buffer: buffer)
        case addressTypeDomain:
            address = processDomainAddress(buffer: buffer)
        case addressTypeIPv6:
            address = processIPv6Address(buffer: buffer)
        default:
            Logger.logError("SOCKS5: Unsupported address type \(addressType)")
            self.sendReply(to: client, status: generalFailureStatus)
            client.cancel()
            return
        }
        
        self.handleAddress(client: client, address: address)
    }
    
    // Handles parsed address and sets up origin connection
    private func handleAddress(client: NWConnection, address: SOCKS5Address?) {
        guard let address = address else {
            Logger.logError("SOCKS5: Invalid CONNECT request")
            self.sendReply(to: client, status: generalFailureStatus)
            client.cancel()
            return
        }
        
        if let url = URL(string: "socks5://\(address.host):\(address.port)/") {
            Logger.logURL(url)
        } else {
            Logger.logInformation("SOCKS5: CONNECT \(address.host):\(address.port)")
        }
        
        // Create origin connection
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true // Avoid proxy loop
        
        let origin = NWConnection(host: .init(address.host),
                                  port: .init(rawValue: UInt16(address.port))!,
                                  using: parameters)
        
        self.retainOrigin(origin, for: client)
        origin.stateUpdateHandler = { state in
            switch state {
            case .waiting(let err):
                Logger.logError("SOCKS5: Origin state waiting error: \(err). \(address.host):\(address.port)")
                self.sendReply(to: client, status: self.generalFailureStatus)
                client.cancel()
                origin.cancel()
                self.releaseOrigin(for: client)
            case .ready:
                self.sendReply(to: client, status: self.successStatus) { error in
                    if let error = error {
                        Logger.logError("SOCKS5: Failed to send reply: \(error)")
                        client.cancel()
                        origin.cancel()
                        self.releaseOrigin(for: client)
                        return
                    }
                    // Start data piping
                    URLHandlerHelper.pipe(client, origin) {
                        self.releaseOrigin(for: client)
                    }
                }
            case .failed(let err):
                Logger.logError("SOCKS5: Origin state failed error: \(err). \(address.host):\(address.port)")
                self.sendReply(to: client, status: self.generalFailureStatus)
                client.cancel()
                origin.cancel()
                self.releaseOrigin(for: client)
            case .cancelled:
                client.cancel()
                self.releaseOrigin(for: client)
            default:
                break
            }
        }
        
        origin.start(queue: .global())
    }
    
    private func processDomainAddress(buffer: Data) -> SOCKS5Address? {
        let domainLenOffset = requestAddressOffset
        guard buffer.count > domainLenOffset else { return nil }

        let len = Int(buffer[domainLenOffset])
        let requiredLength = requestBaseHeaderLength + 1 + len + portByteCount
        guard buffer.count >= requiredLength else { return nil }

        let addrStart = domainLenOffset + 1
        let addrEnd   = addrStart + len
        let addr      = buffer.subdata(in: addrStart..<addrEnd)

        guard let host = String(data: addr, encoding: .utf8) else {
            Logger.logError("SOCKS5: invalid domain encoding")
            return nil
        }

        let portOffset = addrEnd
        let port = (Int(buffer[portOffset]) << bitsPerByte) | Int(buffer[portOffset + 1])

        return SOCKS5Address(host: host, port: port)
    }
    
    private func processIPv4Address(buffer: Data) -> SOCKS5Address? {
        let requiredLength = requestBaseHeaderLength + ipv4OctetCount + portByteCount
        guard buffer.count >= requiredLength else { return nil }
        
        let addrStart = requestAddressOffset
        let addrEnd   = addrStart + ipv4OctetCount
        let addr      = buffer.subdata(in: addrStart..<addrEnd)
        
        let host = addr.map { String($0) }.joined(separator: ".")
        let portOffset = addrEnd
        let port = (Int(buffer[portOffset]) << bitsPerByte) | Int(buffer[portOffset + 1])
        
        return SOCKS5Address(host: host, port: port)
    }
    
    private func processIPv6Address(buffer: Data) -> SOCKS5Address? {
        let requiredLength = requestBaseHeaderLength + ipv6ByteCount + portByteCount
        guard buffer.count >= requiredLength else { return nil }
        
        let addrStart = requestAddressOffset
        let addrEnd   = addrStart + ipv6ByteCount
        let addr      = buffer.subdata(in: addrStart..<addrEnd)
        
        let host: String = addr.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var cstr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, ptr, &cstr, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: cstr)
        }
        
        let portOffset = addrEnd
        let port = (Int(buffer[portOffset]) << bitsPerByte) | Int(buffer[portOffset + 1])
        
        return SOCKS5Address(host: host, port: port)
    }
    
    private func sendReply(to client: NWConnection, status: UInt8, completion: @escaping (Error?) -> Void = { _ in }) {
        // Reply format: VER, REP, RSV, ATYP, BND.ADDR, BND.PORT (dummy 0.0.0.0:0)
        var reply = Data([version, status, reserved, addressTypeIPv4,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        client.send(content: reply, completion: .contentProcessed(completion))
    }
}
