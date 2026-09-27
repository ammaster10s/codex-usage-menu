# Contributing

Issues and pull requests are welcome. Keep changes focused and describe the behavior they change.

1. Build on macOS with `./build.sh`.
2. Run `"build/Codex Usage.app/Contents/MacOS/CodexUsageMenu" --check` while signed in to the Codex CLI.
3. Open the app and inspect the menu bar and popover. `--preview` opens the popover content in a normal window for UI work.
4. For Auto Press changes, verify input and stopping in a harmless text field with Accessibility access granted. Do not test indefinite runs without a way to stop them.

The project uses AppKit and SwiftUI only. Please avoid adding dependencies for behavior the macOS frameworks already provide. Keep account credentials and personal usage data out of issues, logs, screenshots, and commits.

The app-server response can evolve. When changing quota parsing, consult the current [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) and handle missing fields gracefully.
