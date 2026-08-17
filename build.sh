#!/bin/bash
# Regenerates the Xcode project and builds the Aether Mail iOS / iPadOS app.
#
# Usage:
#   ./build.sh                 # build for the iOS Simulator (no signing needed)
#   ./build.sh --device        # build for a physical iPhone/iPad (needs the team)
#   ./build.sh --install       # build for the Simulator, then install + launch it
#
# The mail engine lives in the shared EmailKit package (../Aether-Courier/EmailKit).
set -euo pipefail

cd "$(dirname "$0")"
DD="${MAIL_DERIVED_DATA:-$(mktemp -d)/mail-dd}"
SIM_NAME="${MAIL_SIM:-Aether-Mail Dev}"
SIM_DEVICE_TYPE="${MAIL_SIM_DEVICE:-iPhone 17 Pro}"
BUNDLE_ID="com.aether.mail"

ensure_simulator() {
  if xcrun simctl list devices | grep -q "^ *$SIM_NAME ("; then
    return
  fi
  local runtime
  runtime=$(xcrun simctl list runtimes -j \
    | python3 -c "import json,sys; rs=json.load(sys.stdin)['runtimes']; print([r['identifier'] for r in rs if r['isAvailable'] and 'iOS' in r['name']][0])")
  echo "Creating dedicated simulator '$SIM_NAME' ($SIM_DEVICE_TYPE)…"
  xcrun simctl create "$SIM_NAME" "$SIM_DEVICE_TYPE" "$runtime" >/dev/null
}

MODE="simulator"
case "${1:-}" in
  --device)  MODE="device" ;;
  --install) MODE="install" ;;
esac

xcodegen generate

# Inject the Google OAuth redirect scheme (com.googleusercontent.apps.<id>) into
# the generated Info.plist from the gitignored OAuthClients.plist — it embeds the
# client ID, so it must NOT be committed. Absent plist = Google OAuth just off.
OAUTH_PLIST="Aether-Mail/OAuthClients.plist"
INFO_PLIST="Aether-Mail/Info.plist"
if [ -f "$OAUTH_PLIST" ] && [ -f "$INFO_PLIST" ]; then
  GID="$(/usr/libexec/PlistBuddy -c 'Print :google' "$OAUTH_PLIST" 2>/dev/null || true)"
  if [ -n "$GID" ]; then
    REV="com.googleusercontent.apps.${GID%.apps.googleusercontent.com}"
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes: string $REV" "$INFO_PLIST" >/dev/null 2>&1 \
      && echo "→ injected Google OAuth URL scheme"
  fi
fi

if [ "$MODE" = "device" ]; then
  xcodebuild \
    -project Aether-Mail.xcodeproj \
    -scheme Aether-Mail \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    build
  echo "Built for device: $DD/Build/Products/Debug-iphoneos/"
  echo "Install it by running the Aether-Mail scheme from Xcode with your iPhone connected."
  exit 0
fi

ensure_simulator

xcodebuild \
  -project Aether-Mail.xcodeproj \
  -scheme Aether-Mail \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$DD" \
  build

BUILT="$DD/Build/Products/Debug-iphonesimulator/Aether Mail.app"
echo "App: $BUILT"

if [ "$MODE" = "install" ]; then
  xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
  xcrun simctl install "$SIM_NAME" "$BUILT"
  xcrun simctl launch "$SIM_NAME" "$BUNDLE_ID"
  echo "✔ Installed and launched on $SIM_NAME"
fi
