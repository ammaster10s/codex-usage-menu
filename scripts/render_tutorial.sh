#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
render_dir=$(mktemp -d "${TMPDIR:-/tmp/}codex-usage-tutorial.XXXXXX")
trap 'rm -rf "$render_dir"' EXIT

# Render the shipped SwiftUI views offscreen with synthetic data. The temporary
# copy only exposes/seeds view state; it never launches the app or reads history.
awk '/^@main$/ { exit } { print }' "$project_dir/CodexUsageMenu.swift" \
  | sed -e 's/@State private var /@State var /g' \
        -e 's/var mode: AutoInputMode = .mouse/var mode: AutoInputMode = .keyboard/' \
        -e 's/var showOptions = false/var showOptions = true/' \
  > "$render_dir/Tutorial.swift"
cat "$project_dir/TokenUsageLog.swift" >> "$render_dir/Tutorial.swift"
cat "$project_dir/scripts/TutorialRenderer.swift" >> "$render_dir/Tutorial.swift"

xcrun swiftc -O -parse-as-library \
  -framework AppKit -framework ApplicationServices -framework Carbon \
  "$render_dir/Tutorial.swift" \
  "$project_dir/AutoClickController.swift" \
  "$project_dir/AutoPressController.swift" \
  "$project_dir/DailyTokenUsage.swift" \
  "$project_dir/TokenCostEstimate.swift" \
  -o "$render_dir/render-tutorial"
"$render_dir/render-tutorial" "$project_dir"
