#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_DIR="$PROJECT_DIR/third_party/wireguard-apple"
PATCH_FILE="$PROJECT_DIR/patches/wireguard-killswitch.patch"

if [[ ! -d "$SUBMODULE_DIR/.git" && ! -f "$SUBMODULE_DIR/.git" ]]; then
  echo "[third-party] Missing wireguard-apple submodule. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "[third-party] WireGuard Kill Switch patch already applied"
  exit 0
fi

echo "[third-party] Applying WireGuard Kill Switch patch"
git -C "$SUBMODULE_DIR" apply --check "$PATCH_FILE"
git -C "$SUBMODULE_DIR" apply "$PATCH_FILE"
