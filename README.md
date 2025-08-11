# ProxyMonitor — macOS HTTP/HTTPS/SOCKS5 proxy (no UI)

A background macOS app in Swift that registers itself as the **system HTTP, HTTPS, and SOCKS5 proxy** and logs all visited URLs to a file. No UI. Delivered as a `.pkg`.
**Install is fully automatic:** the installer’s `postinstall` loads the LaunchDaemon, starts the proxy, and enables system proxies.
**Uninstall is one command:** unloading the daemon triggers cleanup.

---

## Installation

1. Run the `.pkg`.
2. The `postinstall` script will:

   * copy `ProxyMonitor.app` to `/Applications`,
   * place `/Library/LaunchDaemons/test.ProxyMonitor.plist`,
   * load the daemon, start the proxy, and enable **HTTP/HTTPS/SOCKS5** system proxies to `127.0.0.1:8888` for all network services.

**Verify:**

```bash
scutil --proxy
sudo launchctl print system/test.ProxyMonitor | grep -E 'state|program|last exit'
tail -n 100 /Library/Logs/ProxyMonitor/ProxyMonitor.log
```

---

## Uninstallation

Unload the daemon — this triggers `uninstall_app.sh`, which disables proxies and removes the app, plist, and logs:

```bash
sudo launchctl unload /Library/LaunchDaemons/test.ProxyMonitor.plist
```

Alternatively, run the script directly:

```bash
sudo "/Applications/ProxyMonitor.app/Contents/Resources/scripts/uninstall_app.sh"
```

---

## Quick tests (one per protocol)

```bash
# HTTP via our proxy
curl -v --proxy http://127.0.0.1:8888 http://example.com

# HTTPS via our proxy (CONNECT tunnel)
curl -v --proxy http://127.0.0.1:8888 https://example.com

# SOCKS5 via our proxy
curl -v --socks5-hostname 127.0.0.1:8888 https://example.com
```

You should see entries in `/Library/Logs/ProxyMonitor/ProxyMonitor.log`.

---

## Configuration

Defaults (change in sources, then rebuild/repackage):

* Bind host/port: `127.0.0.1:8888`
* Log file: `/Library/Logs/ProxyMonitor/ProxyMonitor.log`
* LaunchDaemon label: `test.ProxyMonitor`
* Connection inactivity timeout (auto-closes idle tunnels)

On install, `postinstall` enables **HTTP**, **HTTPS**, and **SOCKS5** proxies to `127.0.0.1:8888` for **all** network services using `networksetup`.

---

## How it works

* Runs as a **LaunchDaemon** (root), no UI (background-only).
* Listens on `127.0.0.1:8888` (TCP).
* **HTTP:** rewrites absolute-form request line to origin-form and forwards to the origin server.
* **HTTPS:** handles `CONNECT`, returns `200 Connection Established`, then tunnels bytes (TLS remains end-to-end; the host is logged).
* **SOCKS5:** full greeting + `CONNECT` with IPv4/IPv6/domain targets, then tunnels like HTTPS `CONNECT`.
* Upstreams are created with `NWParameters.tcp` and `preferNoProxies = true` to avoid proxy loops through the system proxy.
* A shared piping helper provides bidirectional copy with an **idle timeout** to close inactive tunnels.
* Graceful shutdown closes the listener and cancels all live client connections and upstreams on termination/unload.

---

## Installer scripts and tools used

**Scripts in the project (three):**

* `Packaging/build_pkg.sh` — builds the installer via Apple’s `pkgbuild`/`productbuild`.
* `Packaging/scripts/postinstall` — loads the LaunchDaemon (`launchctl`), starts the proxy, and enables **HTTP/HTTPS/SOCKS5** proxies for all services using `networksetup`.
* `ProxyMonitor.app/Contents/Resources/scripts/uninstall_app.sh` — disables proxies, unloads and removes the daemon, deletes the app and logs.

**System tools invoked by scripts:**

* `launchctl` — load/unload the LaunchDaemon.
* `networksetup` — enable/disable **HTTP**, **HTTPS**, and **SOCKS5** system proxies.
* Standard utilities — `mkdir`, `chmod`, `chown`, `tee` for setup and logging.

---

## Logs & troubleshooting

* URL log: `/Library/Logs/ProxyMonitor/ProxyMonitor.log`
* Installer/postinstall error log: `/Library/Logs/ProxyMonitor/installErrors.log`
* (If configured in plist) daemon stdout/stderr:
  `/Library/Logs/ProxyMonitor/stdout.log`, `/Library/Logs/ProxyMonitor/stderr.log`

**Common fixes:**

* `postinstall` must be named exactly `postinstall` (no extension) and be executable (`chmod 755`).
* LaunchDaemon plist must be owned by `root:wheel` and `chmod 644`.
* `ProgramArguments` must point to `/Applications/ProxyMonitor.app/Contents/MacOS/ProxyMonitor`.
* No NIB/Storyboard in `Info.plist`; background-only; App Sandbox off.
* Ensure upstreams bypass the system proxy (use `preferNoProxies`) to avoid loops.
* Idle timeout prevents descriptor leaks; file-descriptor limits can be raised in the LaunchDaemon plist if needed.

---

## Documentation

### External APIs / libraries used (and why)

* **Network.framework** (`NWListener`, `NWConnection`, `NWParameters.tcp`, `preferNoProxies`) — native, modern TCP API on macOS. Used to accept client connections, create upstream sockets, and tunnel bytes. `preferNoProxies` prevents proxy loops through the system proxy.
* **launchd / LaunchDaemons** — reliable background execution as root and auto-start at boot (`/Library/LaunchDaemons/test.ProxyMonitor.plist`).
* **`/usr/sbin/networksetup`** — official Apple CLI for enabling/disabling **HTTP**, **HTTPS**, and **SOCKS5** system proxies for all network services during install/uninstall.
* **Installer toolchain: `pkgbuild` / `productbuild`** — standard macOS packaging tools (invoked by `Packaging/build_pkg.sh`) to produce the distributable `.pkg`.
* **AppKit / Cocoa (minimal)** — background-only app lifecycle via `NSApplicationDelegate` (no UI, `LSBackgroundOnly=YES`).
* **Foundation / GCD** — timers, file I/O, logging, and `DispatchSourceSignal` for graceful termination handling.

*No third-party dependencies are used; everything is first-party for simpler review/signing and maximum compatibility.*

### Code structure (overview of important modules)

* **Entry point:** `ProxyMonitorMain` — boots the app delegate and starts the run loop.
* **Lifecycle:** `AppDelegate` — starts `ProxyService`, installs signal handlers (SIGTERM/SIGINT/SIGHUP), performs graceful shutdown and triggers uninstall when appropriate.
* **Networking core:**

  * `Server` — TCP listener on `127.0.0.1:8888`, dedicated queue per connection, invokes `onAccept`.
  * `ProxyService` — peeks the first bytes, selects handler (HTTP/HTTPS/SOCKS5), tracks live clients, closes everything cleanly on `stop()`.
  * `ConnectionHandlerProtocol` — minimal interface all protocol handlers implement.
  * `BaseConnectionHandler` — shared state/helpers for handlers (retains upstreams, thread safety). All handlers inherit from this base class.
  * `HTTPHandler` / `HTTPSHandler` / `SOCKSHandler` — protocol logic:

    * HTTP: rewrite absolute-form → origin-form, forward to origin,
    * HTTPS: parse `CONNECT`, reply `200`, tunnel bytes,
    * SOCKS5: greeting + `CONNECT` (IPv4/IPv6/domain), then tunnel.
* **Shared helpers:** `URLHandlerHelper` — bidirectional pipe with inactivity timeout; `firstLine`, `splitHostPort`, `extractHostPort`.
* **Logging:** `Logger` — writes URL and diagnostic lines to `/Library/Logs/ProxyMonitor/ProxyMonitor.log`.
* **Installer assets & scripts:**
  `Packaging/build_pkg.sh`, `Packaging/scripts/postinstall`,
  `ProxyMonitor.app/Contents/Resources/scripts/uninstall_app.sh`.
