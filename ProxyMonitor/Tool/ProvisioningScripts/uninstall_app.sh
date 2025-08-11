#!/bin/zsh
set -euo pipefail

LABEL="test.ProxyMonitor"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
APP="/Applications/ProxyMonitor.app"
LOG_DIR="/Library/Logs/ProxyMonitor"

services=("${(@f)$(
  /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | sed 's/^\* //'
)}")

for svc in "${services[@]}"; do
  /usr/sbin/networksetup -setwebproxystate            "$svc" off || true
  /usr/sbin/networksetup -setsecurewebproxystate      "$svc" off || true
  /usr/sbin/networksetup -setsocksfirewallproxystate  "$svc" off || true
done

[ -f "$PLIST" ] && rm -f "$PLIST"
[ -d "$LOG_DIR" ] && rm -rf "$LOG_DIR"
[ -d "$APP" ] && rm -rf "$APP"
exit 0
