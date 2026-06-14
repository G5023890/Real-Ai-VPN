#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="${APP_NAME:-Real Ai Router}"
BUNDLE_ID="${BUNDLE_ID:-com.codex.RealAiVPN}"
SCHEME="${SCHEME:-RealAiVPN}"
CONFIGURATION="${CONFIGURATION:-Debug}"
INSTALL_DIR="${INSTALL_DIR:-/Applications/${APP_NAME}.app}"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
APP_DIST_PATH="${APP_DIST_PATH:-$DIST_DIR/${APP_NAME}.app}"
ENTITLEMENTS="${ENTITLEMENTS:-$PROJECT_DIR/Config/RealAiVPN.entitlements}"
TEAM_ID="${TEAM_ID:-9FP39GTDT5}"
XCODE_DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild}"
MACOS_SDKROOT="${MACOS_SDKROOT:-$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SKIP_SIGN="${SKIP_SIGN:-0}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
APP_VERSION="${APP_VERSION:-0.95}"
BUILD_STAMP="${BUILD_STAMP:-$(date '+%H%M%S%d%m%Y')}"
BUILD_DISPLAY_STAMP="${BUILD_DISPLAY_STAMP:-$(date '+%H%M.%d.%y')}"
BUILD_LABEL="${BUILD_LABEL:-${APP_VERSION} (${BUILD_DISPLAY_STAMP})}"
RESOLVED_SIGN_IDENTITY=""
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/real-ai-vpn-derived.XXXXXX")}"

cleanup() {
  rm -rf "$DERIVED_DATA_ROOT"
}
trap cleanup EXIT

log() {
  echo "[build] $*"
}

resolve_sign_identity() {
  if [[ "$SKIP_SIGN" == "1" ]]; then
    return 0
  fi

  if [[ -n "$SIGN_IDENTITY" ]]; then
    RESOLVED_SIGN_IDENTITY="$SIGN_IDENTITY"
    return 0
  fi

  local identities_output first_available
  identities_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  first_available="$(printf '%s\n' "$identities_output" | awk '/Apple Development: .*RW87CRAFCB/ { print $2; exit }')"
  if [[ -z "$first_available" ]]; then
    first_available="$(printf '%s\n' "$identities_output" | awk '/Apple Development: / { print $2; exit }')"
  fi

  if [[ -n "$first_available" ]]; then
    RESOLVED_SIGN_IDENTITY="$first_available"
  fi
}

sign_bundle() {
  local bundle="$1"

  xattr -cr "$bundle" || true
  chmod -R u+rwX "$bundle" || true

  if [[ "$SKIP_SIGN" == "1" ]]; then
    log "Skipping codesign (SKIP_SIGN=1)"
    return 0
  fi

  if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
    log "Signing with identity: $RESOLVED_SIGN_IDENTITY"
    codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$RESOLVED_SIGN_IDENTITY" "$bundle"
  else
    log "No Apple Development identity found; using ad-hoc signature"
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$bundle"
  fi

  codesign --verify --deep --strict "$bundle"
}

launch_app() {
  local app_bin="$INSTALL_DIR/Contents/MacOS/$APP_NAME"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.3

  if open -a "$INSTALL_DIR" >/dev/null 2>&1; then
    sleep 1
    return 0
  fi

  nohup "$app_bin" >/tmp/real-ai-vpn.run.log 2>&1 &
}

resolve_sign_identity
if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
  log "Resolved signing identity: $RESOLVED_SIGN_IDENTITY"
fi
log "Build label: $BUILD_LABEL"

mkdir -p "$DIST_DIR"

"$PROJECT_DIR/scripts/prepare_third_party.sh"

log "Building AmneziaWG userspace backend"
make -C "$PROJECT_DIR/third_party/amneziawg-apple/Sources/WireGuardKitGo" \
  ARCHS=arm64 \
  PLATFORM_NAME=macosx \
  SDKROOT="$MACOS_SDKROOT" \
  CONFIGURATION_BUILD_DIR="$PROJECT_DIR/third_party/amneziawg-apple/Sources/WireGuardKitGo/out" \
  CONFIGURATION_TEMP_DIR="$PROJECT_DIR/.build/amneziawg-go-tmp" \
  build version-header
mkdir -p "$PROJECT_DIR/Sources/WireGuardKitGo/out"
cp "$PROJECT_DIR/third_party/amneziawg-apple/Sources/WireGuardKitGo/out/libwg-go.a" "$PROJECT_DIR/Sources/WireGuardKitGo/out/libwg-go.a"
cp "$PROJECT_DIR/third_party/amneziawg-apple/Sources/WireGuardKitGo/out/wireguard-go-version.h" "$PROJECT_DIR/Sources/WireGuardKitGo/out/wireguard-go-version.h"

log "Generating Xcode project"
"$PROJECT_DIR/scripts/xcodegen_generate.sh"

log "Building app bundle with embedded Packet Tunnel Extension"
"$XCODEBUILD_BIN" \
  -project RealAiVPN.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination platform=macOS,arch=arm64 \
  -derivedDataPath "$DERIVED_DATA_ROOT" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_STAMP" \
  REAL_AI_VPN_BUILD_LABEL="$BUILD_LABEL" \
  build

BUILT_APP="$DERIVED_DATA_ROOT/Build/Products/$CONFIGURATION/${APP_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

rm -rf "$APP_DIST_PATH" "$INSTALL_DIR"
/usr/bin/ditto --norsrc "$BUILT_APP" "$APP_DIST_PATH"

/usr/bin/ditto --norsrc "$APP_DIST_PATH" "$INSTALL_DIR"

sign_bundle "$INSTALL_DIR"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$INSTALL_DIR" || true

log "Installed: $INSTALL_DIR"
codesign -dv --verbose=4 "$INSTALL_DIR" 2>&1 | sed -n '1,40p'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_DIR/Contents/Info.plist"

if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
  launch_app
fi
