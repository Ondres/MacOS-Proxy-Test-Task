import Foundation

final class Constants {
    static let httpScheme = "http"
    static let httpsScheme = "https"
    
    static let httpPort: Int = 80
    static let httpsPort: Int = 443
    static let defaultLocalPort: UInt16 = 8888
    static let defaultLocalAddress: String = "127.0.0.1"
    
    static let crlf = "\r\n"
    
    enum HTTPMethod: String, CaseIterable {
        case connect = "CONNECT"
        case get     = "GET"
        case post    = "POST"
        case head    = "HEAD"
        case put     = "PUT"
        case delete  = "DELETE"
        case options = "OPTIONS"
        case patch   = "PATCH"
    }
    
    static let maxDataLenght = 32 * 1024
    
    static let localHostName = "localhost"
    static let connectionEstablishedMessage = "HTTP/1.1 200 Connection Established\r\n\r\n"
    
    static let connectionInactiveTime: TimeInterval = 15
    
    static let rootUid = 0
    static let successStatus = 0
}
