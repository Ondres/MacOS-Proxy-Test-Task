import Foundation

final class Logger {
    private static let logDateFormat = "yyyy-MM-dd HH:mm:ss"
    private static let logDirectoryPath = "/Library/Logs/ProxyMonitor"
    private static let logFileName = "ProxyMonitor.log"
    private static let errorLogPrefix = "[ERROR]"
    private static let infoLogPrefix = "[INFO]"
    private static let urlLogPrefix = "[URL]"
    
    private static let logDirectory: URL = {
        let dir = URL(fileURLWithPath: logDirectoryPath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()
    
    private static let logFile: URL = {
        logDirectory.appendingPathComponent(logFileName)
    }()
    
    static func logError(_ message: String) {
        write("\(timestamp()) \(errorLogPrefix) \(message)")
    }
    
    static func logInformation(_ message: String) {
        write("\(timestamp()) \(infoLogPrefix) \(message)")
    }
    
    static func logURL(_ url: URL) {
        let scheme = url.scheme ?? "-"
        let host = url.host ?? "-"
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        
        let formatted = "\(timestamp()) \(urlLogPrefix) [\(scheme)] [\(host)] \(path)\(query)"
        write(formatted)
    }
    
    private static func write(_ text: String) {
        let line = text + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logFile, options: .atomic)
            }
        }
    }
    
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = logDateFormat
        return formatter.string(from: Date())
    }
}
