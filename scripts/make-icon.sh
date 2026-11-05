#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_ICON_DIR="$(mktemp -d -t lid-icon)"
trap 'rm -rf "$TASK_ICON_DIR"' EXIT
mkdir -p "$TASK_ICON_DIR/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" assets/AppIcon.png --out "$TASK_ICON_DIR/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" assets/AppIcon.png --out "$TASK_ICON_DIR/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TASK_ICON_DIR/AppIcon.iconset" -o assets/AppIcon.icns
