#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app_dir="$project_dir/build/Codex Usage.app"
contents_dir="$app_dir/Contents"
resources_dir="$contents_dir/Resources"
iconset_dir="$project_dir/build/AppIcon.iconset"
mkdir -p "$contents_dir/MacOS" "$resources_dir" "$iconset_dir"

xcrun swift "$project_dir/make_icon.swift" "$project_dir/build/AppIcon-1024.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$project_dir/build/AppIcon-1024.png" \
    --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$project_dir/build/AppIcon-1024.png" \
    --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"

cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
xcrun swiftc -O -parse-as-library \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  "$project_dir/CodexUsageMenu.swift" \
  "$project_dir/AutoPressController.swift" \
  -o "$contents_dir/MacOS/CodexUsageMenu"
codesign --force --sign - "$app_dir"
echo "$app_dir"
