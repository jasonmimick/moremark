---
name: markmore
displayName: markmore — markdown preview window
description: Preview markdown files in a native macOS window with GitHub rendering, live reload, and mermaid diagrams, straight from the CLI.
keywords: [markdown, preview, viewer, macos, mermaid, documentation]
---

# markmore

`more` for markdown — the one that opens a window. Renders any markdown file with GitHub styling (highlighted code, tables, mermaid diagrams) in a native macOS window that live-reloads on save.

## Onboarding

1. Verify macOS — markmore is macOS-native (no Linux/Windows).
2. Install if missing:
   ```sh
   command -v markmore || brew install jasonmimick/markmore/markmore
   ```
   Builds from source via `swiftc` in seconds; no Gatekeeper prompts.

## Usage

```sh
markmore -w path/to/file.md    # ALWAYS -w from agents: native window for the user
                               # (without -w it renders text into the terminal)
some-command | markmore -      # preview stdin
```

- The window live-reloads on save — don't relaunch after editing the same file.
- Offer a preview after writing or substantially editing README/docs/reports.
- Relative .md links browse in-window (Cmd+[ / Cmd+] history); images resolve from the file's directory.
- KaTeX math ($...$/$$...$$), mermaid, file tree (Cmd+B), TOC (Cmd+Shift+T), find (Cmd+F), print/PDF (Cmd+P).
