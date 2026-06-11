#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="${SCHEME:-RealAiVPNiOS}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TEAM_ID="${TEAM_ID:-9FP39GTDT5}"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$PROJECT_DIR/.build/xcode-ios-device}"
APP_VERSION="${APP_VERSION:-0.93}"
BUILD_STAMP="${BUILD_STAMP:-$(date '+%H%M%S%d%m%Y')}"
BUILD_DISPLAY_STAMP="${BUILD_DISPLAY_STAMP:-$(date '+%H%M:%d%m:%y')}"
BUILD_LABEL="${BUILD_LABEL:-${APP_VERSION} (${BUILD_DISPLAY_STAMP})}"
TOP_LEVEL_GO_OUT="$PROJECT_DIR/Sources/WireGuardKitGo/out"
IOS_GO_OUT="$PROJECT_DIR/third_party/amneziawg-apple/Sources/WireGuardKitGo/out-iphoneos"
MACOS_LIB_BACKUP="$PROJECT_DIR/.build/libwg-go.macos.backup.a"

log() {
  echo "[ios-build] $*"
}

restore_macos_backend() {
  if [[ -f "$MACOS_LIB_BACKUP" ]]; then
    mkdir -p "$TOP_LEVEL_GO_OUT"
    cp "$MACOS_LIB_BACKUP" "$TOP_LEVEL_GO_OUT/libwg-go.a"
  fi
  rm -rf "$IOS_GO_OUT"
}

trap restore_macos_backend EXIT

if [[ -f "$TOP_LEVEL_GO_OUT/libwg-go.a" ]]; then
  mkdir -p "$(dirname "$MACOS_LIB_BACKUP")"
  cp "$TOP_LEVEL_GO_OUT/libwg-go.a" "$MACOS_LIB_BACKUP"
fi

log "Preparing AmneziaWG userspace backend for iPhone"
log "Build label: $BUILD_LABEL"
"$PROJECT_DIR/scripts/prepare_third_party.sh"
make -C "$PROJECT_DIR/third_party/amneziawg-apple/Sources/WireGuardKitGo" \
  ARCHS=arm64 \
  PLATFORM_NAME=iphoneos \
  SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  DEPLOYMENT_TARGET_CLANG_FLAG_NAME=miphoneos-version-min \
  DEPLOYMENT_TARGET_CLANG_ENV_NAME=IPHONEOS_DEPLOYMENT_TARGET \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  CONFIGURATION_BUILD_DIR="$IOS_GO_OUT" \
  CONFIGURATION_TEMP_DIR="$PROJECT_DIR/.build/amneziawg-go-ios-tmp" \
  build version-header

mkdir -p "$TOP_LEVEL_GO_OUT"
cp "$IOS_GO_OUT/libwg-go.a" \
  "$TOP_LEVEL_GO_OUT/libwg-go.a"
cp "$IOS_GO_OUT/wireguard-go-version.h" \
  "$TOP_LEVEL_GO_OUT/wireguard-go-version.h"

log "Generating Xcode project"
"$PROJECT_DIR/scripts/xcodegen_generate.sh"

log "Building iOS app for a real device destination"
xcodebuild \
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
log "No simulator was launched and nothing was installed on a phone."
