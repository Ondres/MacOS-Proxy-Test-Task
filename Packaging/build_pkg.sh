#!/bin/zsh
set -euo pipefail

PKG_VERSION="${1:-1.0.0}"
PKG_ID="test.ProxyMonitor.pkg"
ROOT="Packaging/payload-root"
SCRIPTS="Packaging/scripts"
OUT="ProxyMonitor-${PKG_VERSION}.pkg"
PLIST_PATH="${ROOT}/Library/LaunchDaemons/test.ProxyMonitor.plist"
POSTINSTALL="${SCRIPTS}/postinstall"

[ -d "$ROOT/Applications/ProxyMonitor.app" ] || { echo "ERR: ProxyMonitor.app not found in ${ROOT}/Applications"; exit 1; }
[ -f "$PLIST_PATH" ] || { echo "ERR: plist not found: ${PLIST_PATH}"; exit 1; }
[ -f "$POSTINSTALL" ] || { echo "ERR: postinstall not found: ${POSTINSTALL}"; exit 1; }

sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"
chmod +x "$POSTINSTALL"

pkgbuild \
  --root "$ROOT" \
  --scripts "$SCRIPTS" \
  --identifier "$PKG_ID" \
  --version "$PKG_VERSION" \
  --install-location "/" \
  "$OUT"

echo "Built: $OUT"
