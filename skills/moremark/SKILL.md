---
name: moremark
description: Preview markdown files in a native macOS window with GitHub rendering, live reload, and mermaid diagrams. Use when the user asks to preview, view, render, or "show" a markdown file — or after writing/substantially editing a README, doc, report, or any .md file, to offer a rendered preview. macOS only.
---

# moremark — markdown preview in a native window

`moremark` renders a markdown file the way GitHub would — syntax-highlighted code, tables, task lists, mermaid diagrams — in a native macOS window that live-reloads on every save.

## Ensure installed (macOS only)

```sh
command -v moremark || brew install jasonmimick/moremark/moremark
```

The brew formula builds from source in seconds; no Gatekeeper prompts.

## Usage

```sh
moremark path/to/file.md &     # ALWAYS background with & so the shell isn't blocked
some-command | moremark -      # preview stdin
```

## Behavior notes

- **Live reload**: the window tracks the file. After you edit the same file again, do NOT relaunch — the open window updates itself on save.
- Relative `.md` links and images resolve from the file's directory; the user can browse linked docs in-window (Cmd+[ / Cmd+] history).
- Window closes with Cmd+W; the backgrounded process exits with it.

## When to offer

- After creating or substantially rewriting a markdown file, offer once: e.g. "Want it rendered? `moremark README.md`" — or just open it if the user previously said yes in this session.
- If the user says "show me" / "preview" / "render" about a .md file, open it immediately.
- Not on Linux/Windows — moremark is macOS-native.
