// moremark — more for markdown: native macOS previewer for the CLI.
// Usage: moremark <file.md | folder>   or   ... | moremark -
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

// Full file tree for the sidebar.
func treeNodes(_ dir: URL, depth: Int = 0, budget: inout Int) -> [[String: Any]] {
    guard depth < 4, budget > 0 else { return [] }
    let items = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    var dirs: [URL] = [], files: [URL] = []
    for item in items {
        if isDir(item) { dirs.append(item) } else { files.append(item) }
    }
    dirs.sort { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    files.sort { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    var nodes: [[String: Any]] = []
    for d in dirs where budget > 0 {
        budget -= 1
        let children = treeNodes(d, depth: depth + 1, budget: &budget)
        nodes.append(["name": d.lastPathComponent + "/", "path": d.path, "children": children])
    }
    for f in files where budget > 0 {
        budget -= 1
        nodes.append(["name": f.lastPathComponent, "path": f.path])
    }
    return nodes
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
moremark — more for markdown: the one that opens a window.

usage:
  moremark                   open the current folder (README.md if present)
  moremark <file.md>         preview a markdown file (live-reloads on save)
  moremark <folder>          browse a folder — README or a generated index
  moremark <any file>        source renders highlighted; binaries hex-dump
  ... | moremark             preview stdin

in the window:
  ⌘B      toggle file tree           ⌘[  back
  ⌘⇧H     hex dump (any file)        ⌘]  forward
  ⌘R      reload                     ⌘W  close
  ⌘?      this help                  ⌘Q  quit

Relative links and folders open in-window; visit a second doc and history
tabs appear. External links open in your browser. Your prompt returns
immediately — the window detaches from the shell.

docs: https://github.com/jasonmimick/moremark
"""

let helpMarkdown = """
# moremark help

`more` for markdown — the one that opens a window.

## Command line

| command | does |
|---|---|
| `moremark` | open the current folder — `README.md` if present, else an index |
| `moremark file.md` | preview a markdown file, live-reloading on save |
| `moremark folder/` | browse a folder |
| `moremark any.file` | source renders syntax-highlighted; binaries hex-dump |
| `... \\| moremark` | preview stdin (piped input is auto-detected) |

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
- Re-run the welcome card anytime: **moremark ▸ Welcome to moremark**.

MIT · [github.com/jasonmimick/moremark](https://github.com/jasonmimick/moremark)
"""

var cliArgs = CommandLine.arguments
if cliArgs.count == 1 {
    // Bare `moremark`: piped input becomes stdin mode, a terminal means "here".
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
        die("moremark: no such file: \(url.path)", code: 66)
    }
    initialFile = resolveTarget(url)
} else {
    die("usage: moremark [file.md | folder]   or   ... | moremark", code: 64)
}

// Detach from the shell: after validating args, re-exec ourselves in the
// background and return the user to their prompt immediately.
if ProcessInfo.processInfo.environment["MOREMARK_FOREGROUND"] == nil {
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let child = Process()
    child.executableURL = exe
    if let md = stdinMD {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("moremark-stdin-\(getpid()).md")
        try? md.write(to: tmp, atomically: true, encoding: .utf8)
        child.arguments = ["--stdin-file", tmp.path]
    } else {
        child.arguments = Array(CommandLine.arguments.dropFirst())
    }
    var env = ProcessInfo.processInfo.environment
    env["MOREMARK_FOREGROUND"] = "1"
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
    .markdown-body { max-width: 980px; margin: 0 auto; padding: 45px; }
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
    #sidebar { display: none; position: fixed; top: 0; bottom: 0; left: 0; width: 220px; z-index: 8;
      overflow-y: auto; padding: 12px 8px; box-sizing: border-box;
      background: #f6f8fa; border-right: 1px solid #d1d9e0;
      font: 12px -apple-system, BlinkMacSystemFont, sans-serif; }
    .ti { padding: 3px 8px; border-radius: 6px; color: #59636e; cursor: default;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ti:hover { background: rgba(0,0,0,0.05); }
    .ti.active { background: #ddf4ff; color: #0969da; }
    .ti.dir { font-weight: 600; }
    .tc { padding-left: 12px; }
    body.tabs-on #sidebar { top: 32px; }
    @media (prefers-color-scheme: dark) {
      #tabbar { background: #161b22; border-color: #3d444d; }
      .tab { color: #9198a1; }
      .tab.active { background: #0d1117; color: #f0f6fc; border-color: #3d444d; border-bottom-color: #0d1117; }
      #sidebar { background: #161b22; border-color: #3d444d; }
      .ti { color: #9198a1; }
      .ti:hover { background: rgba(255,255,255,0.06); }
      .ti.active { background: #121d2f; color: #4493f8; }
    }
    body.tabs-on { padding-top: 32px; }
    body.side-on { padding-left: 220px; }
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
    </head><body><nav id="tabbar"></nav><nav id="sidebar"></nav>
    <article id="content" class="markdown-body"></article>
    <div id="welcome"><div class="wcard">
      <div class="wlogo">M↓</div>
      <h1>moremark</h1>
      <p class="wtag">more for markdown — the one that opens a window.</p>
      <div class="wfam">
        <span class="wchip">cat</span><span class="warr">→</span>
        <span class="wchip">more</span><span class="warr">→</span>
        <span class="wchip">less</span><span class="warr">→</span>
        <span class="wchip wme">moremark</span>
      </div>
      <div class="wtips">
        <div><kbd>⌘B</kbd> file tree</div>
        <div><kbd>⌘⇧H</kbd> hex dump</div>
        <div><kbd>⌘[</kbd> <kbd>⌘]</kbd> back / forward</div>
        <div><kbd>⌘W</kbd> back to work</div>
      </div>
      <p class="wlive">edits live-reload — leave the window open while you write ✏️<br>
      full reference: <b>Help ▸ moremark Help</b> <kbd>⌘?</kbd> · replay this card: <b>moremark ▸ Welcome</b></p>
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
    function __tree(nodes, active, show) {
      var side = document.getElementById('sidebar');
      if (!show || !nodes.length) {
        side.style.display = 'none';
        document.body.classList.remove('side-on');
        return;
      }
      side.style.display = 'block';
      document.body.classList.add('side-on');
      side.innerHTML = '';
      function build(list, container) {
        list.forEach(function (n) {
          var el = document.createElement('div');
          el.className = 'ti' + (n.children ? ' dir' : '') + (n.path === active ? ' active' : '');
          el.textContent = n.name;
          el.title = n.name;
          el.addEventListener('click', function () {
            window.webkit.messageHandlers.tabs.postMessage({ action: 'go', path: n.path });
          });
          container.appendChild(el);
          if (n.children) {
            var kids = document.createElement('div');
            kids.className = 'tc';
            build(n.children, kids);
            container.appendChild(kids);
          }
        });
      }
      build(nodes, side);
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

// WKWebView eats Cmd+[ / Cmd+] for its own page history — hand them back
// to the main menu so our Back/Forward (with proper state) run instead.
final class PreviewWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers, ["[", "]"].contains(chars) {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
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

    // Sidebar root stays anchored to where moremark was opened.
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

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("moremark")

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

    func loadPage() {
        pageLoaded = false
        if let cur = currentFile {
            if !visited.contains(cur) { visited.append(cur) }
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
            .appendingPathComponent("moremark-\(getpid())-\(pageCounter).html")
        if let old = currentPageFile { try? FileManager.default.removeItem(at: old) }
        currentPageFile = pageFile
        try? pageHTML(baseHref: baseHref).write(to: pageFile, atomically: true, encoding: .utf8)
        webView.loadFileURL(pageFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        watch()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        render()
        pushTabs()
        pushTree()
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

    @objc func showHelp() {
        let helpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("moremark Help.md")
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

    func pushTree() {
        guard pageLoaded else { return }
        let show = UserDefaults.standard.bool(forKey: "sidebar")
        var nodes: [[String: Any]] = []
        if show, let root = treeRoot {
            var budget = 500
            nodes = treeNodes(root, budget: &budget)
        }
        let active = currentFile?.path ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: [nodes]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "__tree(\(json)[0], \(jsString(active)), \(show))", completionHandler: nil)
    }

    @objc func toggleFileTree() {
        let show = !UserDefaults.standard.bool(forKey: "sidebar")
        UserDefaults.standard.set(show, forKey: "sidebar")
        pushTree()
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

    // MARK: about + appearance

    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let credits = NSMutableAttributedString(
            string: "more for markdown — the one that opens a window.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        credits.append(NSAttributedString(
            string: "github.com/jasonmimick/moremark",
            attributes: [.link: URL(string: "https://github.com/jasonmimick/moremark")!,
                         .font: NSFont.systemFont(ofSize: 11)]))
        credits.append(NSAttributedString(
            string: "\nMIT © Jason Mimick",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "moremark",
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
            item.state = UserDefaults.standard.bool(forKey: "sidebar") ? .on : .off
            return treeRoot != nil
        case #selector(toggleHex):
            item.state = hexMode ? .on : .off
            return currentFile.map { !isDir($0) } ?? (stdinMD != nil)
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
appMenu.addItem(withTitle: "About moremark", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
appMenu.addItem(withTitle: "Welcome to moremark", action: #selector(AppDelegate.showWelcome), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Hide moremark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit moremark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let fileMenuItem = NSMenuItem(); mainMenu.addItem(fileMenuItem)
let fileMenu = NSMenu(title: "File")
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
helpMenu.addItem(NSMenuItem(title: "moremark Help", action: #selector(AppDelegate.showHelp), keyEquivalent: "?"))
helpMenuItem.submenu = helpMenu
app.helpMenu = helpMenu

app.mainMenu = mainMenu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
