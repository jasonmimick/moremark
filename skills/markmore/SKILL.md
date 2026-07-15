---
name: markmore
description: Preview markdown files in a native macOS window with GitHub rendering, live reload, and mermaid diagrams. Use when the user asks to preview, view, render, or "show" a markdown file — or after writing/substantially editing a README, doc, report, or any .md file, to offer a rendered preview. macOS only.
---

# markmore — markdown preview in a native window

`markmore` renders a markdown file the way GitHub would — syntax-highlighted code, tables, task lists, mermaid diagrams — in a native macOS window that live-reloads on every save.

## Ensure installed (macOS only)

```sh
command -v markmore || brew install jasonmimick/markmore/markmore
```

The brew formula builds from source in seconds; no Gatekeeper prompts.

## Usage

```sh
markmore -w path/to/file.md    # ALWAYS use -w from agents: opens the native window
                               # for the user and detaches (prompt returns immediately)
markmore -w docs/              # browse a folder (README or generated index)
```

Without `-w`, markmore renders ANSI text + graphics INTO the terminal — never do
that from an agent shell; it floods the transcript. Always pass `-w`.

## Behavior notes

- **Live reload**: the window tracks the file. After you edit the same file again, do NOT relaunch — the open window updates itself on save.
- Relative links and images resolve from the file's directory; linked docs browse in-window (Cmd+[ / Cmd+] history).
- Non-markdown files work too: source renders syntax-highlighted, images render, binaries hex-dump (Cmd+Shift+H forces hex).
- Math: $inline$ and $$display$$ typeset with KaTeX, offline. YAML front matter renders as a collapsible block.
- Cmd+B native file tree, Cmd+Shift+T table of contents, Cmd+F find, Cmd+P print/PDF.
- Window closes with Cmd+W. The process detaches from the shell automatically — never append `&`.

## When to offer

- After creating or substantially rewriting a markdown file, offer once: e.g. "Want it rendered? `markmore README.md`" — or just open it if the user previously said yes in this session.
- If the user says "show me" / "preview" / "render" about a .md file, open it immediately.
- Not on Linux/Windows — markmore is macOS-native.
