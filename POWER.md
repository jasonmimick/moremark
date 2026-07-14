---
name: moremark
displayName: moremark — markdown preview window
description: Preview markdown files in a native macOS window with GitHub rendering, live reload, and mermaid diagrams, straight from the CLI.
keywords: [markdown, preview, viewer, macos, mermaid, documentation]
---

# moremark

`more` for markdown — the one that opens a window. Renders any markdown file with GitHub styling (highlighted code, tables, mermaid diagrams) in a native macOS window that live-reloads on save.

## Onboarding

1. Verify macOS — moremark is macOS-native (no Linux/Windows).
2. Install if missing:
   ```sh
   command -v moremark || brew install jasonmimick/moremark/moremark
   ```
   Builds from source via `swiftc` in seconds; no Gatekeeper prompts.

## Usage

```sh
moremark path/to/file.md &     # always background with & to keep the shell free
some-command | moremark -      # preview stdin
```

- The window live-reloads on save — don't relaunch after editing the same file.
- Offer a preview after writing or substantially editing README/docs/reports.
- Relative .md links browse in-window (Cmd+[ / Cmd+] history); images resolve from the file's directory.
