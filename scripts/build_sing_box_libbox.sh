#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/.build/sing-box-libbox-src}"
SING_BOX_DIR="$WORK_DIR/sing-box"
APPLE_DIR="$WORK_DIR/sing-box-for-apple"
DEST_DIR="$PROJECT_DIR/third_party/sing-box"
DEST_FRAMEWORK="$DEST_DIR/Libbox.xcframework"
GO_BIN="$(go env GOPATH)/bin"
export PATH="$GO_BIN:$PATH"

log() {
  echo "[libbox] $*"
}

mkdir -p "$WORK_DIR" "$DEST_DIR"

if [[ ! -d "$SING_BOX_DIR/.git" ]]; then
  log "Cloning sing-box core"
  git clone --depth 1 https://github.com/SagerNet/sing-box.git "$SING_BOX_DIR"
fi

if [[ ! -d "$APPLE_DIR/.git" ]]; then
  log "Cloning sing-box-for-apple"
  git clone --depth 1 https://github.com/SagerNet/sing-box-for-apple.git "$APPLE_DIR"
fi

log "Building Libbox.xcframework for Apple platforms"
cd "$SING_BOX_DIR"
if [[ ! -x "$GO_BIN/gobind" || ! -x "$GO_BIN/gomobile" ]]; then
  log "Installing gomobile/gobind"
  go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
  go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
fi
"$GO_BIN/gomobile" init
go run ./cmd/internal/build_libbox -target apple

if [[ ! -d "$APPLE_DIR/Libbox.xcframework" ]]; then
  echo "Libbox.xcframework was not produced at $APPLE_DIR/Libbox.xcframework" >&2
  exit 1
fi

rm -rf "$DEST_FRAMEWORK"
/usr/bin/ditto --norsrc "$APPLE_DIR/Libbox.xcframework" "$DEST_FRAMEWORK"
log "Installed $DEST_FRAMEWORK"
log "Regenerate the Xcode project with scripts/xcodegen_generate.sh before building."
