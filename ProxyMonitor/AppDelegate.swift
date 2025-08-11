import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var proxy: ProxyService?
    private var termSources: [DispatchSourceSignal] = []
    
    // Constants for signal handling
    private enum Signals {
        static let terminationSignals = [SIGTERM, SIGINT, SIGHUP]
    }
    
    func startApplication() {
        // Ensure the app runs as root
        guard getuid() == Constants.rootUid else {
            Logger.logError("Must run as root")
            NSApp.terminate(self)
            return
        }
        // Start the proxy service
        startProxy()
        
        // Set up signal handlers for graceful shutdown
        setupTerminationHandlers()
    }
    
    // Starts the proxy service on the default port
    private func startProxy() {
        proxy = ProxyService()
        guard let proxy = proxy else {
            Logger.logError("Failed to initialize ProxyService")
            NSApp.terminate(self)
            return
        }
        proxy.start(port: Constants.defaultLocalPort)
        Logger.logInformation("Proxy started on \(Constants.defaultLocalAddress):\(Constants.defaultLocalPort)")
    }
    
    // Configures handlers for termination signals
    private func setupTerminationHandlers() {
        // Ignore default signal behavior
        Signals.terminationSignals.forEach { signal($0, SIG_IGN) }
        
        // Set up signal sources
        for sig in Signals.terminationSignals {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler { [weak self] in
                Logger.logInformation("Received signal \(sig), stopping proxy and running uninstall")
                self?.proxy?.stop()
                self?.runUninstallDetached()
            }
            src.resume()
            termSources.append(src)
        }
    }
    
    // Runs the uninstall script in a detached process
    private func runUninstallDetached() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("scripts/uninstall_app.sh"),
                  FileManager.default.fileExists(atPath: url.path) else {
                Logger.logError("Uninstall script not found at \(String(describing: Bundle.main.resourceURL))/scripts/uninstall_app.sh")
                return
            }
            
            let result = CommandRunnerService.run("/bin/zsh \"\(url.path)\"")
            if result.status != Constants.successStatus {
                Logger.logError("uninstall_app.sh failed: \(result.err)")
            } else {
                Logger.logInformation("uninstall_app.sh executed successfully")
            }
        }
    }
}

@main
class ProxyMonitorMain {
    public static func main() {
        let proxyMonitorApplication = AppDelegate()
        proxyMonitorApplication.startApplication()
        
        dispatchMain()
    }
}
