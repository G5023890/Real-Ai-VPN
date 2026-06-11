#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_DIR="$PROJECT_DIR/third_party/amneziawg-apple"
PATCH_FILE="$PROJECT_DIR/patches/amneziawg-killswitch.patch"

if [[ ! -d "$SUBMODULE_DIR/.git" && ! -f "$SUBMODULE_DIR/.git" ]]; then
  echo "[third-party] Missing amneziawg-apple submodule. Run: git submodule update --init --recursive" >&2
  exit 1
fi

if git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "[third-party] AmneziaWG Kill Switch patch already applied"
  exit 0
fi

echo "[third-party] Applying AmneziaWG Kill Switch patch"
git -C "$SUBMODULE_DIR" apply --check "$PATCH_FILE"
git -C "$SUBMODULE_DIR" apply "$PATCH_FILE"
