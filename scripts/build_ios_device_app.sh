#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="${SCHEME:-RealAiVPNiOS}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TEAM_ID="${TEAM_ID:-9FP39GTDT5}"
XCODE_DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild}"
IPHONEOS_SDKROOT="${IPHONEOS_SDKROOT:-$XCODE_DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk}"
CLANG_BIN="${CLANG_BIN:-$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang}"
DEVICE_ID="${DEVICE_ID:-}"
INSTALL_ON_DEVICE="${INSTALL_ON_DEVICE:-0}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$PROJECT_DIR/.build/xcode-ios-device}"
APP_VERSION="${APP_VERSION:-0.98.5}"
BUILD_STAMP="${BUILD_STAMP:-$(date '+%H%M%S%d%m%Y')}"
BUILD_DISPLAY_STAMP="${BUILD_DISPLAY_STAMP:-$(date '+%H%M.%d.%y')}"
BUILD_LABEL="${BUILD_LABEL:-${APP_VERSION} (${BUILD_DISPLAY_STAMP})}"
log() {
  echo "[ios-build] $*"
}

log "Build label: $BUILD_LABEL"

log "Generating Xcode project"
"$PROJECT_DIR/scripts/xcodegen_generate.sh"

log "Building iOS app for a real device destination"
"$XCODEBUILD_BIN" \
  -project RealAiVPN.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_ROOT" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_STAMP" \
  REAL_AI_VPN_BUILD_LABEL="$BUILD_LABEL" \
  build

log "Built iOS products at: $DERIVED_DATA_ROOT/Build/Products/${CONFIGURATION}-iphoneos"
if [[ "$INSTALL_ON_DEVICE" == "1" ]]; then
  if [[ -z "$DEVICE_ID" ]]; then
    echo "INSTALL_ON_DEVICE=1 requires DEVICE_ID=<iPhone device id>" >&2
    exit 1
  fi
  APP_PATH="$DERIVED_DATA_ROOT/Build/Products/${CONFIGURATION}-iphoneos/Real Ai Router.app"
  log "Installing on device: $DEVICE_ID"
  "$XCODE_DEVELOPER_DIR/usr/bin/devicectl" device install app --device "$DEVICE_ID" "$APP_PATH"
  if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
    "$XCODE_DEVELOPER_DIR/usr/bin/devicectl" device process launch --device "$DEVICE_ID" com.codex.RealAiVPN.iOS
  fi
else
  log "No simulator was launched and nothing was installed on a phone."
fi
