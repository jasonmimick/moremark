// markmore — more for markdown: native macOS previewer for the CLI.
// Usage: markmore <file.md | folder>   or   ... | markmore -
// Live reload, in-window .md navigation (Cmd+[ / Cmd+]), history tabs,
// file tree (Cmd+B), Cmd+W to close. Detaches from the shell on launch.

import Cocoa
import WebKit

func die(_ msg: String, code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

let markdownExts: Set<String> = ["md", "markdown", "mdown", "mkd"]

func isDir(_ url: URL) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
}

// Opening a folder shows its README if it has one, else a generated index.
func resolveTarget(_ url: URL) -> URL {
    guard isDir(url) else { return url }
    if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path),
       let readme = items.first(where: { $0.lowercased() == "readme.md" }) {
        return url.appendingPathComponent(readme).standardizedFileURL
    }
    return url
}

let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp", "ico", "tiff"]

func indexMarkdown(for dir: URL) -> String {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    var dirs: [String] = [], files: [String] = []
    for item in items {
        if isDir(item) { dirs.append(item.lastPathComponent) }
        else { files.append(item.lastPathComponent) }
    }
    dirs.sort { $0.lowercased() < $1.lowercased() }
    files.sort { $0.lowercased() < $1.lowercased() }
    var md = "# \(dir.lastPathComponent)/\n\n"
    if dirs.isEmpty && files.isEmpty { return md + "_Empty folder._\n" }
    for d in dirs {
        let enc = d.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? d
        md += "- 🗂 [\(d)/](\(enc)/)\n"
    }
    for f in files {
        let enc = f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f
        md += "- [\(f)](\(enc))\n"
    }
    return md
}

// Lazy file-tree node for the NSOutlineView sidebar.
final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var loaded = false
    private var _children: [FileNode] = []

    init(url: URL) {
        self.url = url
        self.isDirectory = isDir(url)
    }

    var children: [FileNode] {
        if !loaded {
            loaded = true
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            _children = items.map { FileNode(url: $0.standardizedFileURL) }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.lowercased() < $1.url.lastPathComponent.lowercased()
            }
        }
        return _children
    }

    func invalidate() {
        loaded = false
        _children = []
    }
}

// Classic `hexdump -C` layout: offset, 16 bytes (split 8|8), ASCII gutter.
func hexDump(_ bytes: [UInt8]) -> String {
    var lines: [String] = []
    lines.reserveCapacity(bytes.count / 16 + 1)
    for start in stride(from: 0, to: bytes.count, by: 16) {
        let chunk = Array(bytes[start..<min(start + 16, bytes.count)])
        var hex = ""
        for i in 0..<16 {
            hex += i < chunk.count ? String(format: "%02x ", chunk[i]) : "   "
            if i == 7 { hex += " " }
        }
        let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
        lines.append(String(format: "%08x  ", start) + hex + " |" + ascii + "|")
    }
    return lines.joined(separator: "\n")
}

var initialFile: URL? = nil
var stdinMD: String? = nil

let cliHelp = """
markmore — more for markdown: the one that opens a window.

usage:
  markmore                   open the current folder (README.md if present)
  markmore <file.md>         preview a markdown file (live-reloads on save)
  markmore <folder>          browse a folder — README or a generated index
  markmore <any file>        source renders highlighted; binaries hex-dump
  ... | markmore             preview stdin

in the window:
  ⌘B      toggle file tree           ⌘[  back
  ⌘⇧H     hex dump (any file)        ⌘]  forward
  ⌘R      reload                     ⌘W  close
  ⌘?      this help                  ⌘Q  quit

Relative links and folders open in-window; visit a second doc and history
tabs appear. External links open in your browser. Your prompt returns
immediately — the window detaches from the shell.

docs: https://github.com/jasonmimick/markmore
"""

let helpMarkdown = """
# markmore help

`more` for markdown — the one that opens a window.

## Command line

| command | does |
|---|---|
| `markmore` | open the current folder — `README.md` if present, else an index |
| `markmore file.md` | preview a markdown file, live-reloading on save |
| `markmore folder/` | browse a folder |
| `markmore any.file` | source renders syntax-highlighted; binaries hex-dump |
| `... \\| markmore` | preview stdin (piped input is auto-detected) |

Your prompt returns immediately — the window detaches from the shell.

## Keyboard

| keys | action |
|---|---|
| `⌘B` | toggle the file tree |
| `⌘⇧H` | hex dump the current file (any file — old unix souls welcome) |
| `⌘[` / `⌘]` | back / forward (also the ‹ › titlebar buttons) |
| `⌘R` | re-render |
| `⌘W` | close window · `⌘Q` quit |
| `⌘?` | this page |

## Behavior

- **Live reload** — the window tracks the open file; edits re-render on save, keeping your scroll position. Never relaunch for the same file.
- **Links** — relative markdown/folder links open in-window; anchors scroll; external links open in your browser. Images resolve from the file's folder.
- **History tabs** — appear once you've visited two docs. Click to jump, `×` to forget.
- **Appearance** — follows system light/dark; override in **View** menu.
- Re-run the welcome card anytime: **markmore ▸ Welcome to markmore**.

MIT · [github.com/jasonmimick/markmore](https://github.com/jasonmimick/markmore)
"""

var cliArgs = CommandLine.arguments
if cliArgs.count == 1 {
    // Bare `markmore`: piped input becomes stdin mode, a terminal means "here".
    cliArgs.append(isatty(0) == 0 ? "-" : ".")
}
if ["-h", "--help"].contains(cliArgs[1]) {
    print(cliHelp)
    exit(0)
}
if cliArgs[1] == "--stdin-file", cliArgs.count == 3 {
    stdinMD = (try? String(contentsOfFile: cliArgs[2], encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(atPath: cliArgs[2])
} else if cliArgs[1] == "-" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    stdinMD = String(data: data, encoding: .utf8) ?? ""
} else if cliArgs.count == 2 {
    let url = URL(fileURLWithPath: (cliArgs[1] as NSString).expandingTildeInPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        die("markmore: no such file: \(url.path)", code: 66)
    }
    initialFile = resolveTarget(url)
} else {
    die("usage: markmore [file.md | folder]   or   ... | markmore", code: 64)
}

// Detach from the shell: after validating args, re-exec ourselves in the
// background and return the user to their prompt immediately.
if ProcessInfo.processInfo.environment["MARKMORE_FOREGROUND"] == nil {
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let child = Process()
    child.executableURL = exe
    if let md = stdinMD {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("markmore-stdin-\(getpid()).md")
        try? md.write(to: tmp, atomically: true, encoding: .utf8)
        child.arguments = ["--stdin-file", tmp.path]
    } else {
        child.arguments = Array(CommandLine.arguments.dropFirst())
    }
    var env = ProcessInfo.processInfo.environment
    env["MARKMORE_FOREGROUND"] = "1"
    child.environment = env
    do {
        try child.run()
        exit(0)
    } catch {
        // fall through and run in the foreground
    }
}
signal(SIGHUP, SIG_IGN)

func resource(_ b64: String) -> String {
    String(data: Data(base64Encoded: b64)!, encoding: .utf8)!
}

func pageHTML(baseHref: String) -> String {
    #"""
    <!doctype html><html><head><meta charset="utf-8">
    <base href="\#(baseHref)">
    <style>\#(resource(ghCSSBase64))</style>
    <style>\#(resource(hljsLightCSSBase64))</style>
    <style>@media (prefers-color-scheme: dark) { \#(resource(hljsDarkCSSBase64)) }</style>
    <style>
    body { margin: 0; background: #ffffff; }
    @media (prefers-color-scheme: dark) { body { background: #0d1117; } }
    .markdown-body { text-rendering: optimizeLegibility; font-variant-ligatures: common-ligatures;
      -webkit-hyphens: auto; hyphens: auto; }
    .markdown-body pre, .markdown-body code { hyphens: none; -webkit-hyphens: none; }
    .markdown-body { max-width: 980px; margin: 0 auto; padding: 45px;
      font-family: var(--mm-font, -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif);
      font-size: var(--mm-size, 16px); }
    @media (max-width: 767px) { .markdown-body { padding: 24px; } }
    .mermaid { display: flex; justify-content: center; margin-bottom: 16px; }
    #tabbar { display: none; position: fixed; top: 0; left: 0; right: 0; z-index: 9;
      gap: 2px; padding: 6px 8px 0; overflow-x: auto;
      background: #f6f8fa; border-bottom: 1px solid #d1d9e0;
      font: 12px -apple-system, BlinkMacSystemFont, sans-serif; }
    .tab { display: flex; align-items: center; gap: 6px; padding: 5px 10px; white-space: nowrap;
      color: #59636e; border: 1px solid transparent; border-radius: 6px 6px 0 0; cursor: default; }
    .tab.active { background: #ffffff; color: #1f2328; border-color: #d1d9e0; border-bottom-color: #ffffff; }
    .tab .x { opacity: 0.45; cursor: pointer; padding: 0 2px; }
    .tab .x:hover { opacity: 1; }
    @media (prefers-color-scheme: dark) {
      #tabbar { background: #161b22; border-color: #3d444d; }
      .tab { color: #9198a1; }
      .tab.active { background: #0d1117; color: #f0f6fc; border-color: #3d444d; border-bottom-color: #0d1117; }
    }
    body.tabs-on { padding-top: 32px; }
    #welcome { display: none; position: fixed; inset: 0; z-index: 20; align-items: center;
      justify-content: center; background: rgba(15, 23, 30, 0.35); backdrop-filter: blur(6px); }
    .wcard { position: relative; overflow: hidden; width: min(440px, 86vw); text-align: center;
      background: #ffffff; color: #1f2328; border-radius: 16px; padding: 34px 34px 56px;
      box-shadow: 0 24px 70px rgba(0,0,0,0.35);
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
      animation: wpop 0.35s cubic-bezier(0.2, 1.4, 0.4, 1); }
    @keyframes wpop { from { transform: scale(0.92) translateY(14px); opacity: 0; } }
    .wlogo { width: 64px; height: 64px; margin: 0 auto 12px; border-radius: 15px;
      background: linear-gradient(#149a82, #085a4d); color: #fff;
      font: 800 26px -apple-system; display: flex; align-items: center; justify-content: center; }
    .wcard h1 { margin: 0; font-size: 24px; border: 0; padding: 0; }
    .wtag { color: #59636e; margin: 4px 0 18px; }
    .wfam { display: flex; gap: 6px; justify-content: center; align-items: center; margin-bottom: 20px; }
    .wchip, .warr { opacity: 0; animation: win 0.4s ease forwards; }
    .wchip { font: 12px ui-monospace, monospace; padding: 3px 9px; border-radius: 999px;
      background: #f6f8fa; border: 1px solid #d1d9e0; }
    .wchip:nth-child(1) { animation-delay: 0.3s; } .warr:nth-child(2) { animation-delay: 0.5s; }
    .wchip:nth-child(3) { animation-delay: 0.7s; } .warr:nth-child(4) { animation-delay: 0.9s; }
    .wchip:nth-child(5) { animation-delay: 1.1s; } .warr:nth-child(6) { animation-delay: 1.3s; }
    .wchip.wme { animation-delay: 1.5s; background: #0e7c6b; border-color: #0e7c6b; color: #fff; }
    @keyframes win { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; } }
    .wtips { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 14px; text-align: left;
      margin: 0 auto 16px; width: fit-content; color: #59636e; font-size: 13px; }
    kbd { font: 11px ui-monospace, monospace; padding: 2px 6px; border-radius: 5px;
      background: #f6f8fa; border: 1px solid #d1d9e0; border-bottom-width: 2px; color: #1f2328; }
    .wlive { color: #59636e; font-size: 13px; margin: 0 0 18px; }
    #wgo { background: #0e7c6b; color: #fff; border: 0; border-radius: 8px; padding: 9px 22px;
      font: 600 14px -apple-system; cursor: pointer; }
    #wgo:hover { background: #149a82; }
    .wcat { position: absolute; bottom: 8px; left: 0; font-size: 20px;
      animation: wwalk 7s linear infinite alternate; }
    @keyframes wwalk {
      0% { transform: translateX(20px) scaleX(-1); }
      49% { transform: translateX(360px) scaleX(-1); }
      51% { transform: translateX(360px) scaleX(1); }
      100% { transform: translateX(20px) scaleX(1); }
    }
    @media (prefers-color-scheme: dark) {
      .wcard { background: #161b22; color: #f0f6fc; }
      .wtag, .wtips, .wlive { color: #9198a1; }
      .wchip { background: #21262d; border-color: #3d444d; color: #f0f6fc; }
      .wchip.wme { background: #0e7c6b; border-color: #0e7c6b; }
      kbd { background: #21262d; border-color: #3d444d; color: #f0f6fc; }
    }
    </style>
    <script>\#(resource(markedJSBase64))</script>
    <script>\#(resource(hljsJSBase64))</script>
    <script>\#(resource(mermaidJSBase64))</script>
    </head><body><nav id="tabbar"></nav>
    <article id="content" class="markdown-body"></article>
    <div id="welcome"><div class="wcard">
      <div class="wlogo">M↓</div>
      <h1>markmore</h1>
      <p class="wtag">markdown, beautifully rendered — straight from your terminal.</p>
      <div class="wtips">
        <div><kbd>⌘B</kbd> file tree</div>
        <div><kbd>⌘⇧H</kbd> hex dump</div>
        <div><kbd>⌘[</kbd> <kbd>⌘]</kbd> back / forward</div>
        <div><kbd>⌘W</kbd> back to work</div>
      </div>
      <p class="wlive">edits live-reload — leave the window open while you write ✏️<br>
      full reference: <b>Help ▸ markmore Help</b> <kbd>⌘?</kbd> · replay this card: <b>markmore ▸ Welcome</b></p>
      <button id="wgo">Let's go</button>
      <div class="wcat">🐈‍⬛</div>
    </div></div>
    <script>
    var darkMQ = window.matchMedia('(prefers-color-scheme: dark)');
    function __update(md) {
      window.__lastMd = md;
      var y = window.scrollY;
      var el = document.getElementById('content');
      el.innerHTML = marked.parse(md, { gfm: true });
      el.querySelectorAll('code.language-mermaid').forEach(function (c) {
        var d = document.createElement('div');
        d.className = 'mermaid';
        d.textContent = c.textContent;
        c.parentElement.replaceWith(d);
      });
      el.querySelectorAll('pre code').forEach(function (c) { hljs.highlightElement(c); });
      el.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(function (h) {
        if (!h.id) h.id = h.textContent.trim().toLowerCase()
          .replace(/[^\w\- ]+/g, '').replace(/\s+/g, '-');
      });
      var nodes = el.querySelectorAll('.mermaid');
      if (nodes.length) {
        mermaid.initialize({ startOnLoad: false, theme: darkMQ.matches ? 'dark' : 'default' });
        mermaid.run({ nodes: nodes }).catch(function () {});
      }
      window.scrollTo(0, y);
    }
    function __tabs(list, active) {
      var bar = document.getElementById('tabbar');
      if (list.length < 2) {
        bar.style.display = 'none';
        document.body.classList.remove('tabs-on');
        return;
      }
      bar.style.display = 'flex';
      document.body.classList.add('tabs-on');
      bar.innerHTML = '';
      list.forEach(function (t, i) {
        var el = document.createElement('div');
        el.className = 'tab' + (i === active ? ' active' : '');
        var label = document.createElement('span');
        label.textContent = t.name;
        el.appendChild(label);
        var x = document.createElement('span');
        x.className = 'x';
        x.textContent = '×';
        x.addEventListener('click', function (e) {
          e.stopPropagation();
          window.webkit.messageHandlers.tabs.postMessage({ action: 'close', path: t.path });
        });
        el.appendChild(x);
        el.addEventListener('click', function () {
          window.webkit.messageHandlers.tabs.postMessage({ action: 'go', path: t.path });
        });
        bar.appendChild(el);
      });
    }
    function __code(title, lang, text) {
      window.__lastMd = undefined;
      var y = window.scrollY;
      var el = document.getElementById('content');
      el.innerHTML = '';
      var h = document.createElement('h1');
      h.textContent = title;
      el.appendChild(h);
      var pre = document.createElement('pre');
      var code = document.createElement('code');
      if (lang) code.className = 'language-' + lang;
      code.textContent = text;
      pre.appendChild(code);
      el.appendChild(pre);
      if (lang && text.length < 200000) { try { hljs.highlightElement(code); } catch (e) {} }
      window.scrollTo(0, y);
    }
    function __welcome(show) {
      document.getElementById('welcome').style.display = show ? 'flex' : 'none';
    }
    document.getElementById('wgo').addEventListener('click', function () {
      __welcome(false);
      window.webkit.messageHandlers.tabs.postMessage({ action: 'welcomed', path: '' });
    });
    darkMQ.addEventListener('change', function () {
      if (window.__lastMd !== undefined) __update(window.__lastMd);
    });
    </script>
    </body></html>
    """#
}

// WKWebView eats Cmd+[ / Cmd+] for its own page history — intercept them
// and fire our Back/Forward actions directly instead.
final class PreviewWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers {
            if chars == "[" {
                NSApp.sendAction(#selector(AppDelegate.goBack), to: nil, from: self)
                return true
            }
            if chars == "]" {
                NSApp.sendAction(#selector(AppDelegate.goForward), to: nil, from: self)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

let recentsMenu = NSMenu(title: "Open Recent")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate,
                         NSOutlineViewDataSource, NSOutlineViewDelegate,
                         WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var source: DispatchSourceFileSystemObject?
    var pageLoaded = false

    var currentFile: URL? = initialFile
    var backStack: [URL] = []
    var forwardStack: [URL] = []
    var visited: [URL] = []
    var pendingFragment: String?
    var pageCounter = 0
    var currentPageFile: URL?
    var hexMode = false
    var backButton: NSButton!
    var forwardButton: NSButton!
    var splitView: NSSplitView!
    var sidebarScroll: NSScrollView!
    var outlineView: NSOutlineView!
    var rootNode: FileNode?
    var suppressSelection = false

    // Sidebar root stays anchored to where markmore was opened.
    let treeRoot: URL? = initialFile.map { isDir($0) ? $0 : $0.deletingLastPathComponent() }

    var currentBaseDir: URL {
        guard let cur = currentFile else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return isDir(cur) ? cur : cur.deletingLastPathComponent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "system")

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "tabs")
        webView = PreviewWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        let savedZoom = UserDefaults.standard.double(forKey: "zoom")
        if savedZoom > 0 { webView.pageZoom = savedZoom }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: .init("file"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked)
        sidebarScroll = NSScrollView()
        sidebarScroll.documentView = outlineView
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        sidebarScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebarScroll)
        splitView.addArrangedSubview(webView)
        splitView.setHoldingPriority(NSLayoutConstraint.Priority(261), forSubviewAt: 0)
        splitView.autosaveName = "markmoreSplit"

        if let root = treeRoot { rootNode = FileNode(url: root) }
        sidebarScroll.isHidden = !(UserDefaults.standard.bool(forKey: "sidebar") && rootNode != nil)
        if !sidebarScroll.isHidden, let root = rootNode { outlineView.expandItem(root) }

        window.contentView = splitView
        window.center()
        window.setFrameAutosaveName("markmore")

        func navButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                             target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.isBordered = true
            b.toolTip = tip
            return b
        }
        backButton = navButton("chevron.left", tip: "Back (⌘[)", action: #selector(goBack))
        forwardButton = navButton("chevron.right", tip: "Forward (⌘])", action: #selector(goForward))
        let stack = NSStackView(views: [backButton, forwardButton])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        // Titlebar accessories are invisible without an explicit frame.
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)

        window.makeKeyAndOrderFront(nil)

        // CLI-spawned processes need to steal focus after the window exists;
        // macOS 14+ often ignores the first attempt, so retry once async.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            self.window.makeKeyAndOrderFront(nil)
        }

        loadPage()
    }

    func noteRecent(_ url: URL) {
        guard !url.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        var recents = UserDefaults.standard.stringArray(forKey: "recents") ?? []
        recents.removeAll { $0 == url.path }
        recents.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(15)), forKey: "recents")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func loadPage() {
        pageLoaded = false
        if let cur = currentFile {
            if !visited.contains(cur) { visited.append(cur) }
            noteRecent(cur)
            window.title = cur.lastPathComponent + (isDir(cur) ? "/" : "")
            window.subtitle = (currentBaseDir.path as NSString).abbreviatingWithTildeInPath
        } else {
            window.title = "stdin"
            window.subtitle = ""
        }
        // loadHTMLString(baseURL:) can't read local subresources (images);
        // write the page to a temp file and grant read access instead.
        let baseHref = URL(fileURLWithPath: currentBaseDir.path, isDirectory: true).absoluteString
        pageCounter += 1
        let pageFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("markmore-\(getpid())-\(pageCounter).html")
        if let old = currentPageFile { try? FileManager.default.removeItem(at: old) }
        currentPageFile = pageFile
        try? pageHTML(baseHref: baseHref).write(to: pageFile, atomically: true, encoding: .utf8)
        webView.loadFileURL(pageFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        watch()
        revealInTree()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        applyTypography()
        render()
        pushTabs()
        if let frag = pendingFragment {
            pendingFragment = nil
            scrollTo(fragment: frag)
        }
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            webView.evaluateJavaScript("__welcome(true)", completionHandler: nil)
        }
    }

    @objc func showWelcome() {
        webView.evaluateJavaScript("__welcome(true)", completionHandler: nil)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = resolveTarget(URL(fileURLWithPath: path).standardizedFileURL)
        if url != currentFile { jump(to: url, push: true) }
    }

    @objc func clearRecents() {
        UserDefaults.standard.removeObject(forKey: "recents")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentsMenu else { return }
        menu.removeAllItems()
        let recents = (UserDefaults.standard.stringArray(forKey: "recents") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        for path in recents {
            let url = URL(fileURLWithPath: path)
            let title = (path as NSString).abbreviatingWithTildeInPath + (isDir(url) ? "/" : "")
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            menu.addItem(item)
        }
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: ""))
    }

    @objc func showHelp() {
        let helpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("markmore Help.md")
        try? helpMarkdown.write(to: helpFile, atomically: true, encoding: .utf8)
        if helpFile.standardizedFileURL != currentFile {
            jump(to: helpFile.standardizedFileURL, push: true)
        }
    }

    func scrollTo(fragment: String) {
        let js = "var t = document.getElementById(\(jsString(fragment))); if (t) t.scrollIntoView();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // In-page anchors scroll; relative .md/folder links navigate in-window;
    // the rest goes to the default handler (browser, editor, Finder).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "file" {
            // Fragment-only links resolve against <base>, i.e. the doc's dir.
            if let frag = url.fragment,
               url.path == currentBaseDir.path || url.path == currentPageFile?.path {
                scrollTo(fragment: frag)
                decisionHandler(.cancel)
                return
            }
            let target = URL(fileURLWithPath: url.path).standardizedFileURL
            if FileManager.default.fileExists(atPath: target.path) {
                pendingFragment = url.fragment
                navigate(to: resolveTarget(target))
                decisionHandler(.cancel)
                return
            }
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func navigate(to url: URL) {
        if let cur = currentFile { backStack.append(cur) }
        forwardStack.removeAll()
        currentFile = url.standardizedFileURL
        loadPage()
    }

    // Tab jump / tab-close switch: plain switch, optionally remembering where we were.
    func jump(to url: URL, push: Bool) {
        if push, let cur = currentFile, cur != url { backStack.append(cur) }
        pendingFragment = nil
        currentFile = url
        loadPage()
    }

    @objc func goBack() {
        guard let cur = currentFile, let prev = backStack.popLast() else { return }
        forwardStack.append(cur)
        currentFile = prev
        loadPage()
    }

    @objc func goForward() {
        guard let cur = currentFile, let next = forwardStack.popLast() else { return }
        backStack.append(cur)
        currentFile = next
        loadPage()
    }

    // MARK: history tabs + file tree

    func pushTabs() {
        guard pageLoaded else { return }
        let list = visited.map { ["name": $0.lastPathComponent + (isDir($0) ? "/" : ""), "path": $0.path] }
        let active = currentFile.flatMap { visited.firstIndex(of: $0) } ?? -1
        guard let data = try? JSONSerialization.data(withJSONObject: [list]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("__tabs(\(json)[0], \(active))", completionHandler: nil)
    }

    @objc func toggleFileTree() {
        guard rootNode != nil else { return }
        let show = sidebarScroll.isHidden
        UserDefaults.standard.set(show, forKey: "sidebar")
        if show {
            rootNode?.invalidate()
            outlineView.reloadData()
            if let root = rootNode { outlineView.expandItem(root) }
            sidebarScroll.isHidden = false
            if sidebarScroll.frame.width < 20 { splitView.setPosition(220, ofDividerAt: 0) }
            revealInTree()
        } else {
            sidebarScroll.isHidden = true
        }
    }

    func revealInTree() {
        guard !sidebarScroll.isHidden, let cur = currentFile else { return }
        suppressSelection = true
        let row = (0..<outlineView.numberOfRows).first {
            (outlineView.item(atRow: $0) as? FileNode)?.url == cur
        }
        if let row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
        suppressSelection = false
    }

    // The root folder is shown as a visible top-level node (expanded by default).
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return node.children.count }
        return rootNode == nil ? 0 : 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.children[index] }
        return rootNode!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("fileCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            icon.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.textField?.font = node === rootNode
            ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode,
              !node.isDirectory, node.url != currentFile else { return }
        jump(to: node.url, push: true)
    }

    @objc func outlineDoubleClicked() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode,
              node.isDirectory else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    @objc func toggleHex() {
        hexMode.toggle()
        render()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "tabs",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let path = body["path"] as? String else { return }
        let url = resolveTarget(URL(fileURLWithPath: path).standardizedFileURL)
        switch action {
        case "go":
            if url != currentFile { jump(to: url, push: true) }
        case "close":
            visited.removeAll { $0 == url }
            backStack.removeAll { $0 == url }
            forwardStack.removeAll { $0 == url }
            if url == currentFile {
                if let last = visited.last { jump(to: last, push: false) }
            } else {
                pushTabs()
            }
        case "welcomed":
            UserDefaults.standard.set(true, forKey: "welcomed")
        default: break
        }
    }

    func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(data: data, encoding: .utf8)! + "[0]"
    }

    func showMarkdown(_ md: String) {
        webView.evaluateJavaScript("__update(\(jsString(md)))", completionHandler: nil)
    }

    func showCode(_ title: String, lang: String, text: String) {
        webView.evaluateJavaScript(
            "__code(\(jsString(title)), \(jsString(lang)), \(jsString(text)))", completionHandler: nil)
    }

    func showHex(title: String, bytes: [UInt8], totalSize: Int) {
        var dump = hexDump(bytes)
        if totalSize > bytes.count {
            dump += "\n… truncated — showing first \(bytes.count) of \(totalSize) bytes"
        }
        showCode(title + " · hex", lang: "", text: dump)
    }

    @objc func render() {
        guard pageLoaded else { return }
        guard let cur = currentFile else {
            let md = stdinMD ?? ""
            if hexMode { showHex(title: "stdin", bytes: [UInt8](md.utf8), totalSize: md.utf8.count) }
            else { showMarkdown(md) }
            return
        }
        if isDir(cur) {
            showMarkdown(indexMarkdown(for: cur))
            return
        }
        let name = cur.lastPathComponent
        let ext = cur.pathExtension.lowercased()
        if hexMode {
            let fh = try? FileHandle(forReadingFrom: cur)
            let data = fh?.readData(ofLength: 65536) ?? Data()
            try? fh?.close()
            let total = (try? FileManager.default.attributesOfItem(atPath: cur.path)[.size] as? Int) ?? data.count
            showHex(title: name, bytes: [UInt8](data), totalSize: total ?? data.count)
            return
        }
        if markdownExts.contains(ext), let contents = try? String(contentsOf: cur, encoding: .utf8) {
            showMarkdown(contents)
            return
        }
        if imageExts.contains(ext) {
            let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            showMarkdown("# \(name)\n\n![](\(enc))")
            return
        }
        // Plain text if it decodes cleanly; otherwise fall back to a hex dump.
        let fh = try? FileHandle(forReadingFrom: cur)
        let data = fh?.readData(ofLength: 1_000_000) ?? Data()
        try? fh?.close()
        let total = ((try? FileManager.default.attributesOfItem(atPath: cur.path)[.size] as? Int) ?? data.count) ?? data.count
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            var body = text
            if total > data.count { body += "\n… truncated — showing first \(data.count) of \(total) bytes" }
            showCode(name, lang: ext, text: body)
        } else {
            showHex(title: name, bytes: [UInt8](data.prefix(65536)), totalSize: total)
        }
    }

    func scheduleRender() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(render), object: nil)
        perform(#selector(render), with: nil, afterDelay: 0.1)
    }

    // Editors save atomically (write temp + rename), which kills the watched fd —
    // re-arm on delete/rename, retrying briefly while the new file lands.
    // Watching a directory fd fires on entry add/remove, refreshing the index.
    func watch() {
        source?.cancel()
        source = nil
        guard let file = currentFile else { return }
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.watch() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.scheduleRender()
            if flags.contains(.delete) || flags.contains(.rename) { self.watch() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    // MARK: zoom + typography

    func setZoom(_ z: CGFloat) {
        webView.pageZoom = z
        UserDefaults.standard.set(Double(z), forKey: "zoom")
    }

    @objc func zoomIn() { setZoom(min(3.0, webView.pageZoom * 1.1)) }
    @objc func zoomOut() { setZoom(max(0.5, webView.pageZoom / 1.1)) }
    @objc func zoomReset() { setZoom(1.0) }

    func currentFont() -> NSFont {
        let size = UserDefaults.standard.double(forKey: "fontSize")
        if let name = UserDefaults.standard.string(forKey: "fontFamily"),
           let f = NSFont(name: name, size: size > 0 ? size : 16) { return f }
        return NSFont.systemFont(ofSize: size > 0 ? CGFloat(size) : 16)
    }

    @objc func chooseFont() {
        let fm = NSFontManager.shared
        fm.target = self
        fm.setSelectedFont(currentFont(), isMultiple: false)
        fm.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: Any?) {
        guard let fm = sender as? NSFontManager else { return }
        let f = fm.convert(currentFont())
        UserDefaults.standard.set(f.familyName ?? f.fontName, forKey: "fontFamily")
        UserDefaults.standard.set(Double(f.pointSize), forKey: "fontSize")
        UserDefaults.standard.set("custom", forKey: "typoPreset")
        applyTypography()
    }

    func setPreset(_ p: String) {
        UserDefaults.standard.set(p, forKey: "typoPreset")
        applyTypography()
    }

    @objc func presetSystem() { setPreset("system") }
    @objc func presetBook() { setPreset("book") }
    @objc func presetClassic() { setPreset("classic") }
    @objc func presetMono() { setPreset("mono") }

    func applyTypography() {
        guard pageLoaded else { return }
        let preset = UserDefaults.standard.string(forKey: "typoPreset") ?? "system"
        var fontCSS: String?
        switch preset {
        case "book": fontCSS = "ui-serif, 'New York', Georgia, serif"
        case "classic": fontCSS = "'Iowan Old Style', Palatino, Georgia, serif"
        case "mono": fontCSS = "ui-monospace, 'SF Mono', Menlo, monospace"
        case "custom":
            if let fam = UserDefaults.standard.string(forKey: "fontFamily"), !fam.hasPrefix(".") {
                fontCSS = "'\(fam)', -apple-system, sans-serif"
            }
        default: break
        }
        let size = UserDefaults.standard.double(forKey: "fontSize")
        var js = ""
        if let fontCSS {
            js += "document.documentElement.style.setProperty('--mm-font', \(jsString(fontCSS)));"
        } else {
            js += "document.documentElement.style.removeProperty('--mm-font');"
        }
        if preset == "custom", size > 0 {
            js += "document.documentElement.style.setProperty('--mm-size', '\(size)px');"
        } else {
            js += "document.documentElement.style.removeProperty('--mm-size');"
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: about + appearance

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let credits = NSMutableAttributedString(
            string: "more for markdown — the one that opens a window.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        credits.append(NSAttributedString(
            string: "github.com/jasonmimick/markmore",
            attributes: [.link: URL(string: "https://github.com/jasonmimick/markmore")!,
                         .font: NSFont.systemFont(ofSize: 11)]))
        credits.append(NSAttributedString(
            string: "\nMIT © Jason Mimick",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "markmore",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        UserDefaults.standard.set(mode, forKey: "appearance")
    }

    @objc func appearanceSystem() { applyAppearance("system") }
    @objc func appearanceLight() { applyAppearance("light") }
    @objc func appearanceDark() { applyAppearance("dark") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let mode = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        switch item.action {
        case #selector(appearanceSystem): item.state = mode == "system" ? .on : .off
        case #selector(appearanceLight): item.state = mode == "light" ? .on : .off
        case #selector(appearanceDark): item.state = mode == "dark" ? .on : .off
        case #selector(toggleFileTree):
            item.state = sidebarScroll?.isHidden == false ? .on : .off
            return rootNode != nil
        case #selector(toggleHex):
            item.state = hexMode ? .on : .off
            return currentFile.map { !isDir($0) } ?? (stdinMD != nil)
        case #selector(presetSystem), #selector(presetBook),
             #selector(presetClassic), #selector(presetMono):
            let preset = UserDefaults.standard.string(forKey: "typoPreset") ?? "system"
            let mine = ["presetSystem:": "system", "presetBook:": "book",
                        "presetClassic:": "classic", "presetMono:": "mono"]
            item.state = mine[item.action!.description] == preset ? .on : .off
        case #selector(goBack): return !backStack.isEmpty
        case #selector(goForward): return !forwardStack.isEmpty
        default: break
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let page = currentPageFile { try? FileManager.default.removeItem(at: page) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem(); mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About markmore", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
appMenu.addItem(withTitle: "Welcome to markmore", action: #selector(AppDelegate.showWelcome), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Hide markmore", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit markmore", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let fileMenuItem = NSMenuItem(); mainMenu.addItem(fileMenuItem)
let fileMenu = NSMenu(title: "File")
let recentsItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
recentsItem.submenu = recentsMenu
fileMenu.addItem(recentsItem)
fileMenu.addItem(.separator())
fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenuItem.submenu = fileMenu

let editMenuItem = NSMenuItem(); mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu

let viewMenuItem = NSMenuItem(); mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(NSMenuItem(title: "Toggle File Tree", action: #selector(AppDelegate.toggleFileTree), keyEquivalent: "b"))
viewMenu.addItem(NSMenuItem(title: "Hex Dump", action: #selector(AppDelegate.toggleHex), keyEquivalent: "H"))
viewMenu.addItem(withTitle: "Reload", action: #selector(AppDelegate.render), keyEquivalent: "r")
viewMenu.addItem(NSMenuItem.separator())
viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(AppDelegate.zoomIn), keyEquivalent: "="))
viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(AppDelegate.zoomOut), keyEquivalent: "-"))
viewMenu.addItem(NSMenuItem(title: "Actual Size", action: #selector(AppDelegate.zoomReset), keyEquivalent: "0"))
viewMenu.addItem(NSMenuItem.separator())
let typoItem = NSMenuItem(title: "Typography", action: nil, keyEquivalent: "")
let typoMenu = NSMenu(title: "Typography")
typoMenu.addItem(NSMenuItem(title: "System", action: #selector(AppDelegate.presetSystem), keyEquivalent: ""))
typoMenu.addItem(NSMenuItem(title: "Book", action: #selector(AppDelegate.presetBook), keyEquivalent: ""))
typoMenu.addItem(NSMenuItem(title: "Classic", action: #selector(AppDelegate.presetClassic), keyEquivalent: ""))
typoMenu.addItem(NSMenuItem(title: "Mono", action: #selector(AppDelegate.presetMono), keyEquivalent: ""))
typoMenu.addItem(NSMenuItem.separator())
typoMenu.addItem(NSMenuItem(title: "Choose Font…", action: #selector(AppDelegate.chooseFont), keyEquivalent: "t"))
typoItem.submenu = typoMenu
viewMenu.addItem(typoItem)
viewMenu.addItem(NSMenuItem.separator())
viewMenu.addItem(NSMenuItem(title: "System Appearance", action: #selector(AppDelegate.appearanceSystem), keyEquivalent: ""))
viewMenu.addItem(NSMenuItem(title: "Light", action: #selector(AppDelegate.appearanceLight), keyEquivalent: ""))
viewMenu.addItem(NSMenuItem(title: "Dark", action: #selector(AppDelegate.appearanceDark), keyEquivalent: ""))
viewMenuItem.submenu = viewMenu

let goMenuItem = NSMenuItem(); mainMenu.addItem(goMenuItem)
let goMenu = NSMenu(title: "Go")
goMenu.addItem(NSMenuItem(title: "Back", action: #selector(AppDelegate.goBack), keyEquivalent: "["))
goMenu.addItem(NSMenuItem(title: "Forward", action: #selector(AppDelegate.goForward), keyEquivalent: "]"))
goMenuItem.submenu = goMenu

let helpMenuItem = NSMenuItem(); mainMenu.addItem(helpMenuItem)
let helpMenu = NSMenu(title: "Help")
helpMenu.addItem(NSMenuItem(title: "markmore Help", action: #selector(AppDelegate.showHelp), keyEquivalent: "?"))
helpMenuItem.submenu = helpMenu
app.helpMenu = helpMenu

app.mainMenu = mainMenu
let delegate = AppDelegate()
recentsMenu.delegate = delegate
app.delegate = delegate
app.run()
