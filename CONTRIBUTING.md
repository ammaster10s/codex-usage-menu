# Contributing

Keep changes focused and preserve the standalone app's menu bar icon and behavior.

1. Build with `./build.sh`.
2. Run `"build/Codex Usage.app/Contents/MacOS/CodexUsageMenu" --check` while signed in to Codex.
3. Run `--check-input`, `--check-token-parser`, and `--check-token-costs` for checks that do not post input or read private session content.
4. Run `--check-tokens` for a real local-history scan and verify a second scan uses the incremental index.
5. Inspect all three tabs, mouse/keyboard selection, expanded options, errors, and the footer. Inspect the full usage log, both grouping modes, period/model filters, CSV export, unpriced models, and subscription comparison. `--preview` opens the popover in a development window; `--preview-log` opens the full log.
6. Test automation only in a harmless local target with Accessibility granted and a small finite repeat count. Verify canceling the delay, exact completion, reopening the menu to stop, and **⌘⌥S**. Never begin an unlimited test without a stop path.

Use native AppKit and SwiftUI. Avoid dependencies where system frameworks are sufficient. Keep account credentials, prompts, replies, and personal token/allowance records out of issues, logs, screenshots, and commits.

For allowance parsing, consult the current [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) and handle missing fields gracefully. Daily token parsing must avoid double counting duplicates, fork history, cumulative snapshots, cached input, and reasoning output. Use synthetic fixtures for changes to this logic.

Model attribution must follow recorded context, handle switches, and preserve totals when enriching old caches. Review prices against official OpenAI documentation, record the review date, match model identifiers explicitly, and leave unknown prices unavailable. Keep estimates labelled as a current API comparison. Do not add reasoning twice or describe a gross cache-read discount as confirmed net savings.
