<p align="center"><img src="icon.svg" width="128" alt="markmore icon"></p>

# markmore

**Markdown, beautifully rendered — straight from your terminal.**

`markmore README.md` opens a native macOS window with your markdown the way it's meant to look — GitHub styling, syntax-highlighted code, mermaid diagrams, live reload.

```sh
markmore README.md        # renders RIGHT HERE in your terminal (default)
markmore                  # current folder — README or an index
markmore -w README.md     # open the native window instead
git log | markmore        # preview stdin
markmore --snap file.md   # terminal render as one full-fidelity image
```

**In the terminal** (the default): styled, wrapped, selectable text — and in kitty, ghostty, WezTerm, or iTerm2, block math, mermaid diagrams, and images appear *inline as real typeset graphics* on a transparent background. Links are clickable (OSC 8). In plain terminals you still get clean ANSI text.

**In the window** (`-w`): live reload, file tree, history tabs, table of contents, find, zoom, typography presets, hex view, print-to-PDF. The window detaches — your prompt comes right back.

## Features

- **Live reload** — re-renders on save (handles editors' atomic saves), keeps your scroll position
- **Real GitHub rendering** — [github-markdown-css](https://github.com/sindresorhus/github-markdown-css) + [highlight.js](https://highlightjs.org) GitHub themes; follows system light/dark with a View-menu override
- **Math** — `$inline$` and `$$display$$` typeset with [KaTeX](https://katex.org), fully offline. Try [samples/math.md](samples/math.md).
- **Typography that cares** — View ▸ Typography presets (Book, Classic, Mono) or the native font panel (`⌘T`); hyphenation, ligatures, and `⌘P` prints a properly typeset PDF
- **Mermaid** — ```` ```mermaid ```` fences render as diagrams, theme-aware
- **Browse a repo's docs** — relative `.md` and folder links open in-window; `⌘[` back, `⌘]` forward; history tabs appear at your second doc; `⌘⇧T` floats a table of contents
- **Native file tree** — `⌘B`: real disclosure triangles, Finder icons, live-refreshes as files change, root folder on top. Off by default. We are not Obsidian — nothing is ever written into your folders.
- **Opens anything** — source files render syntax-highlighted, images render as images, and binaries get a classic `hexdump -C` view (`⌘⇧H` forces hex on any file). Try it on [samples/magic.bin](samples/magic.bin).
- **Find** (`⌘F`), **zoom** (`⌘=`/`⌘-`), word count + reading time in the titlebar, YAML front matter as a tidy collapsible block
- Everything vendored into a single self-contained binary — works offline, no runtime dependencies

`⌘W` close · `⌘Q` quit · `⌘R` reload · `⌘?` full reference in-app

## Install

```sh
brew install jasonmimick/markmore/markmore
```

Builds from source on your Mac with `swiftc` (ships with Xcode Command Line Tools) — no Gatekeeper warnings, nothing unsigned downloaded.

Or from a clone:

```sh
./build.sh   # installs markmore.app to ~/Applications + wrapper to ~/.local/bin
```

## Using an AI coding agent?

markmore ships as a skill for the major agent CLIs — your agent learns to offer rendered previews of the markdown it writes:

- **Claude Code**: `/plugin marketplace add jasonmimick/markmore` then `/plugin install markmore@markmore`
- **Codex CLI** (and other `.agents/skills` agents): the skill is bundled in this repo at `.agents/skills/markmore/`
- **Kiro**: add this repo as a Power (`POWER.md` included)

## Why

Every markdown previewer is either $14, an Electron app, a terminal approximation, or trapped inside an editor. This one is a command: type it, see the document, hit `Cmd+W`, back to work.

## Credits

- [marked](https://github.com/markedjs/marked), [github-markdown-css](https://github.com/sindresorhus/github-markdown-css), [highlight.js](https://github.com/highlightjs/highlight.js), [mermaid](https://github.com/mermaid-js/mermaid) — vendored at build time
- Icon based on the [Markdown Mark](https://github.com/dcurtis/markdown-mark) (CC0) by Dustin Curtis

MIT © Jason Mimick
