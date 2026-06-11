#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

"$PROJECT_DIR/scripts/prepare_third_party.sh"

if [[ -d "$PROJECT_DIR/third_party/sing-box/Libbox.xcframework" ]]; then
  echo "[xcodegen] Generating project with Libbox.xcframework"
else
  echo "[xcodegen] Generating project; run scripts/build_sing_box_libbox.sh before building Packet Tunnel targets"
fi
xcodegen generate

if [[ -d "$PROJECT_DIR/third_party/sing-box/Libbox.xcframework" ]]; then
  # XcodeGen adds -ObjC for framework dependencies. Libbox is a static
  # xcframework; -ObjC force-loads unused Cronet/macOS objects that are not
  # extension-safe. sing-box-for-apple links Libbox without -ObjC.
  /usr/bin/perl -0pi -e 's/\n\t\t\t\t\t"-ObjC",//g' "$PROJECT_DIR/RealAiVPN.xcodeproj/project.pbxproj"
fi
