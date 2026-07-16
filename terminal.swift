// Hybrid terminal mode (-t): markdown renders as selectable ANSI text; block
// math, mermaid diagrams, and images rasterize (transparent bg) and sit inline
// via the kitty graphics protocol. The full-snapshot mode remains at -t --snap.

import Cocoa
import WebKit
import JavaScriptCore

enum TermPiece {
    case text(String)
    case snippet(Int)
}

struct TermPalette {
    let dark: Bool
    var reset: String { "\u{1b}[0m" }
    var bold: String { "\u{1b}[1m" }
    var italic: String { "\u{1b}[3m" }
    var strike: String { "\u{1b}[9m" }
    var underline: String { "\u{1b}[4m" }
    var dim: String { dark ? "\u{1b}[38;5;245m" : "\u{1b}[38;5;244m" }
    var code: String { dark ? "\u{1b}[38;5;179m" : "\u{1b}[38;5;130m" }
    var link: String { dark ? "\u{1b}[38;5;75m" : "\u{1b}[38;5;26m" }
    var accent: String { dark ? "\u{1b}[38;5;43m" : "\u{1b}[38;5;29m" }
    var rule: String { dark ? "\u{1b}[38;5;240m" : "\u{1b}[38;5;250m" }
}

// One styled word: ANSI-wrapped text plus its visible width, so wrapping math works.
private struct Atom {
    let styled: String
    let width: Int
    let hardBreak: Bool
    let noSpaceBefore: Bool
    init(styled: String, width: Int, hardBreak: Bool = false, noSpaceBefore: Bool = false) {
        self.styled = styled; self.width = width
        self.hardBreak = hardBreak; self.noSpaceBefore = noSpaceBefore
    }
}

final class HybridRenderer {
    let cols: Int
    let p: TermPalette
    let graphics: Bool
    var pieces: [TermPiece] = []
    var snippets: [String] = []   // html for each rasterized block

    init(cols: Int, dark: Bool, graphics: Bool) {
        self.cols = max(40, cols)
        self.p = TermPalette(dark: dark)
        self.graphics = graphics
    }

    // MARK: entry

    func render(_ markdown: String) -> ([TermPiece], [String]) {
        var md = markdown
        // front matter → dim block
        if let m = md.range(of: "^---\n[\\s\\S]*?\n---\n?", options: .regularExpression) {
            let fm = String(md[m]).trimmingCharacters(in: .whitespacesAndNewlines)
            md.removeSubrange(m)
            appendText(p.dim + fm + p.reset + "\n\n")
        }
        // $$block math$$ → placeholder paragraphs (raw TeX code block sans graphics)
        while let m = md.range(of: "\\$\\$[\\s\\S]+?\\$\\$", options: .regularExpression) {
            let tex = String(md[m])
            if graphics {
                let idx = snippets.count
                snippets.append("<div class=\"math\">\(htmlEscape(tex))</div>")
                md.replaceSubrange(m, with: "\n\n@@MMSNIP\(idx)@@\n\n")
            } else {
                let inner = tex.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
                md.replaceSubrange(m, with: "\n\n```\n\(inner)\n```\n\n")
            }
        }
        guard let tokens = lex(md) else {
            appendText(md)
            return (pieces, snippets)
        }
        renderBlocks(tokens, indent: "")
        return (pieces, snippets)
    }

    func lex(_ md: String) -> [[String: Any]]? {
        guard let ctx = JSContext() else { return nil }
        ctx.evaluateScript(resource(markedJSBase64))
        ctx.setObject(md, forKeyedSubscript: "___md" as NSString)
        guard let json = ctx.evaluateScript("JSON.stringify(marked.lexer(___md))")?.toString(),
              let data = json.data(using: .utf8),
              let tokens = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return tokens
    }

    // MARK: blocks

    func renderBlocks(_ tokens: [[String: Any]], indent: String) {
        for tok in tokens {
            switch tok["type"] as? String ?? "" {
            case "heading":
                let depth = tok["depth"] as? Int ?? 1
                let inner = wrapAtoms(inlineAtoms(tok["tokens"] as? [[String: Any]] ?? []),
                                      indent: indent, style: p.bold + (depth == 1 ? p.underline : (depth == 2 ? p.accent : "")))
                appendText("\n" + inner + "\n\n")
            case "paragraph", "text":
                let inline = tok["tokens"] as? [[String: Any]] ?? []
                let plain = plainText(inline).trimmingCharacters(in: .whitespaces)
                if let m = plain.range(of: "^@@MMSNIP(\\d+)@@$", options: .regularExpression),
                   let n = Int(plain[m].dropFirst(8).dropLast(2)) {
                    pieces.append(.snippet(n))
                    continue
                }
                if inline.count == 1, let img = inline.first,
                   img["type"] as? String == "image" {
                    blockImage(img)
                    continue
                }
                appendText(wrapAtoms(inlineAtoms(inline), indent: indent) + "\n\n")
            case "code":
                let lang = tok["lang"] as? String ?? ""
                let text = tok["text"] as? String ?? ""
                if lang == "mermaid", graphics {
                    let idx = snippets.count
                    snippets.append("<div class=\"mermaid\">\(htmlEscape(text))</div>")
                    pieces.append(.snippet(idx))
                } else {
                    let body = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { indent + "  " + p.code + String($0) + p.reset }
                        .joined(separator: "\n")
                    appendText(body + "\n\n")
                }
            case "blockquote":
                let sub = HybridRenderer(cols: cols - 2, dark: p.dark, graphics: graphics)
                sub.snippets = snippets
                sub.renderBlocks(tok["tokens"] as? [[String: Any]] ?? [], indent: "")
                snippets = sub.snippets
                for piece in sub.pieces {
                    switch piece {
                    case .text(let t):
                        let quoted = t.split(separator: "\n", omittingEmptySubsequences: false)
                            .map { $0.isEmpty ? "" : indent + p.dim + "│ " + p.reset + $0 }
                            .joined(separator: "\n")
                        appendText(quoted)
                    case .snippet(let n):
                        pieces.append(.snippet(n))
                    }
                }
                appendText("\n")
            case "list":
                renderList(tok, indent: indent)
            case "table":
                renderTable(tok, indent: indent)
            case "hr":
                appendText(indent + p.rule + String(repeating: "─", count: max(10, cols - indent.count)) + p.reset + "\n\n")
            case "space":
                break
            case "html":
                let raw = (tok["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { appendText(indent + p.dim + raw + p.reset + "\n\n") }
            default:
                if let text = tok["text"] as? String {
                    appendText(wrapAtoms([Atom(styled: text, width: text.count)], indent: indent) + "\n\n")
                }
            }
        }
    }

    func renderList(_ tok: [String: Any], indent: String) {
        let ordered = tok["ordered"] as? Bool ?? false
        let items = tok["items"] as? [[String: Any]] ?? []
        for (i, item) in items.enumerated() {
            var bullet = ordered ? "\(i + 1). " : "• "
            if let task = item["task"] as? Bool, task {
                bullet = (item["checked"] as? Bool ?? false) ? "☑ " : "☐ "
            }
            let subIndent = indent + String(repeating: " ", count: bullet.count)
            let sub = HybridRenderer(cols: cols, dark: p.dark, graphics: graphics)
            sub.snippets = snippets
            sub.renderBlocks(item["tokens"] as? [[String: Any]] ?? [], indent: subIndent)
            snippets = sub.snippets
            var first = true
            for piece in sub.pieces {
                switch piece {
                case .text(let t):
                    var body = t
                    while body.hasSuffix("\n\n") { body.removeLast() }
                    if first, body.hasPrefix(subIndent) {
                        body = indent + p.accent + bullet + p.reset + String(body.dropFirst(subIndent.count))
                        first = false
                    }
                    appendText(body + "\n")
                case .snippet(let n):
                    pieces.append(.snippet(n))
                }
            }
        }
        appendText("\n")
    }

    func renderTable(_ tok: [String: Any], indent: String) {
        let header = (tok["header"] as? [[String: Any]] ?? []).map { cellPlain($0) }
        let rows = (tok["rows"] as? [[[String: Any]]] ?? []).map { $0.map { cellPlain($0) } }
        guard !header.isEmpty else { return }
        var widths = header.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        let budget = cols - indent.count - (3 * widths.count)
        let total = widths.reduce(0, +)
        if total > budget {
            widths = widths.map { max(6, $0 * budget / max(total, 1)) }
        }
        func line(_ cells: [String], style: String = "") -> String {
            var out = indent
            for (i, w) in widths.enumerated() {
                var cell = i < cells.count ? cells[i] : ""
                if cell.count > w { cell = String(cell.prefix(max(1, w - 1))) + "…" }
                out += p.dim + "│ " + p.reset + style + cell.padding(toLength: w, withPad: " ", startingAt: 0) + p.reset + " "
            }
            return out + p.dim + "│" + p.reset
        }
        appendText(line(header, style: p.bold) + "\n")
        appendText(indent + p.dim + widths.map { String(repeating: "─", count: $0 + 2) }
            .joined(separator: "┼").replacingOccurrences(of: "┼", with: "┼") + p.reset + "\n")
        for row in rows { appendText(line(row) + "\n") }
        appendText("\n")
    }

    func blockImage(_ tok: [String: Any]) {
        let href = tok["href"] as? String ?? ""
        if !href.hasPrefix("http"), !href.isEmpty, graphics {
            let idx = snippets.count
            snippets.append("<img src=\"\(htmlEscape(href))\">")
            pieces.append(.snippet(idx))
        } else {
            let alt = tok["text"] as? String ?? "image"
            appendText(p.dim + "[image: \(alt)] " + href + p.reset + "\n\n")
        }
    }

    // MARK: inline

    private func inlineAtoms(_ tokens: [[String: Any]], style: String = "") -> [Atom] {
        var atoms: [Atom] = []
        for tok in tokens {
            let type = tok["type"] as? String ?? ""
            switch type {
            case "strong":
                atoms += inlineAtoms(tok["tokens"] as? [[String: Any]] ?? [], style: style + p.bold)
            case "em":
                atoms += inlineAtoms(tok["tokens"] as? [[String: Any]] ?? [], style: style + p.italic)
            case "del":
                atoms += inlineAtoms(tok["tokens"] as? [[String: Any]] ?? [], style: style + p.strike)
            case "codespan":
                let text = tok["text"] as? String ?? ""
                for word in splitWords(text) {
                    atoms.append(Atom(styled: style + p.code + word + p.reset, width: word.count))
                }
            case "link":
                let href = tok["href"] as? String ?? ""
                let inner = inlineAtoms(tok["tokens"] as? [[String: Any]] ?? [], style: style + p.link + p.underline)
                for a in inner {
                    let osc = "\u{1b}]8;;\(href)\u{1b}\\" + a.styled + "\u{1b}]8;;\u{1b}\\"
                    atoms.append(Atom(styled: osc, width: a.width))
                }
            case "image":
                let alt = tok["text"] as? String ?? "image"
                atoms.append(Atom(styled: style + p.dim + "[\(alt)]" + p.reset, width: alt.count + 2))
            case "br":
                atoms.append(Atom(styled: "", width: 0, hardBreak: true))
            default:
                let text = (tok["text"] as? String ?? "")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                let startsPunct = text.first.map { ",.;:!?)]}»".contains($0) } ?? false
                for (i, word) in splitWords(text).enumerated() {
                    atoms.append(Atom(styled: style.isEmpty ? word : style + word + p.reset,
                                      width: word.count,
                                      noSpaceBefore: i == 0 && startsPunct))
                }
            }
        }
        return atoms
    }

    private func splitWords(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    private func wrapAtoms(_ atoms: [Atom], indent: String, style: String = "") -> String {
        var lines: [String] = []
        var line = indent
        var width = indent.count
        for atom in atoms {
            if atom.hardBreak {
                lines.append(line)
                line = indent; width = indent.count
                continue
            }
            let needSpace = width > indent.count && !atom.noSpaceBefore
            let sep = needSpace ? 1 : 0
            if width + sep + atom.width > cols, width > indent.count {
                lines.append(line)
                line = indent; width = indent.count
            }
            if width > indent.count, needSpace { line += " "; width += 1 }
            line += style.isEmpty ? atom.styled : style + atom.styled
            width += atom.width
        }
        if width > indent.count { lines.append(line) }
        let suffix = style.isEmpty ? "" : p.reset
        return lines.map { $0 + suffix }.joined(separator: "\n")
    }

    private func plainText(_ tokens: [[String: Any]]) -> String {
        tokens.map { tok in
            if let t = tok["text"] as? String, tok["tokens"] == nil { return t }
            if let sub = tok["tokens"] as? [[String: Any]] { return plainText(sub) }
            return tok["text"] as? String ?? ""
        }.joined()
    }

    private func cellPlain(_ cell: [String: Any]) -> String {
        if let sub = cell["tokens"] as? [[String: Any]] { return plainText(sub) }
        return cell["text"] as? String ?? ""
    }

    private func appendText(_ s: String) {
        if case .text(let existing) = pieces.last {
            pieces[pieces.count - 1] = .text(existing + s)
        } else {
            pieces.append(.text(s))
        }
    }
}

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - snippet rasterizer

// Renders all math/mermaid/image blocks in one offscreen page on a transparent
// background, then crops each block out of a single normalized snapshot.
final class SnippetRasterizer: NSObject, WKNavigationDelegate {
    let snippets: [String]
    let cssWidth: CGFloat
    let dark: Bool
    let baseDir: URL
    var window: NSWindow!
    var webView: WKWebView!
    var completion: (([Data?]) -> Void)?

    init(snippets: [String], cssWidth: CGFloat, dark: Bool, baseDir: URL) {
        self.snippets = snippets
        self.cssWidth = cssWidth
        self.dark = dark
        self.baseDir = baseDir
    }

    func start(_ completion: @escaping ([Data?]) -> Void) {
        self.completion = completion
        let fg = dark ? "#e6edf3" : "#1f2328"
        let baseHref = URL(fileURLWithPath: baseDir.path, isDirectory: true).absoluteString
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><base href="\(baseHref)">
        <style>\(resource(katexCSSBase64))</style>
        <style>body { margin: 0; padding: 0; background: transparent; color: \(fg);
          font: 16px -apple-system, sans-serif; }
        .snip { width: \(Int(cssWidth))px; padding: 6px 2px; box-sizing: border-box; }
        .snip img { max-width: 100%; }
        .mermaid { display: flex; justify-content: flex-start; }</style>
        <script>\(resource(katexJSBase64))</script>
        <script>\(resource(katexAutoJSBase64))</script>
        <script>\(resource(mermaidJSBase64))</script>
        </head><body>
        """
        for (i, snip) in snippets.enumerated() {
            html += "<div class=\"snip\" id=\"s\(i)\">\(snip)</div>\n"
        }
        html += """
        <script>
        renderMathInElement(document.body, { delimiters: [
          { left: '$$', right: '$$', display: true }], throwOnError: false });
        var mn = document.querySelectorAll('.mermaid');
        if (mn.length) {
          mermaid.initialize({ startOnLoad: false, theme: \(dark ? "'dark'" : "'default'") });
          mermaid.run({ nodes: mn }).catch(function () {});
        }
        </script></body></html>
        """
        let frame = NSRect(x: -32000, y: -32000, width: cssWidth * 2, height: 1400)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size))
        webView.navigationDelegate = self
        webView.pageZoom = 2.0
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView
        window.orderFrontRegardless()

        let pageFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("markmore-snips-\(getpid()).html")
        try? html.write(to: pageFile, atomically: true, encoding: .utf8)
        webView.loadFileURL(pageFile, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.measure() }
    }

    func measure() {
        let js = """
        JSON.stringify(Array.from(document.querySelectorAll('.snip')).map(function (d) {
          var r = d.getBoundingClientRect();
          return [r.x, r.y, r.width, r.height];
        }).concat([[0, 0, 0, document.body.scrollHeight]]))
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let rects = try? JSONSerialization.jsonObject(with: data) as? [[Double]],
                  rects.count == self.snippets.count + 1 else {
                self.completion?(self.snippets.map { _ in nil })
                exit(0)
            }
            let docHeight = CGFloat(rects.last![3])
            let size = NSSize(width: self.cssWidth * 2, height: min(docHeight, 20000) * 2 + 8)
            self.window.setContentSize(size)
            self.webView.frame = NSRect(origin: .zero, size: size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.snapshot(rects.dropLast().map { $0 })
            }
        }
    }

    func snapshot(_ rects: [[Double]]) {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.completion?(self.snippets.map { _ in nil })
                return
            }
            // Scale from image pixels to CSS px (layout is at pageZoom 2).
            let pxPerCSS = CGFloat(cg.width) / (self.cssWidth)
            var out: [Data?] = []
            for r in rects {
                let x = CGFloat(r[0]) * pxPerCSS
                let y = CGFloat(r[1]) * pxPerCSS
                let w = CGFloat(r[2]) * pxPerCSS
                let h = CGFloat(r[3]) * pxPerCSS
                guard w > 2, h > 2, let crop = cg.cropping(to: CGRect(x: x, y: y, width: w, height: h)) else {
                    out.append(nil)
                    continue
                }
                // Normalize to 2x CSS so kitty shows it at the intended size.
                let targetW = Int(CGFloat(r[2]) * 2)
                let targetH = Int(CGFloat(r[3]) * 2)
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: targetW, pixelsHigh: targetH,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let ctx2 = NSGraphicsContext(bitmapImageRep: rep) else {
                    out.append(nil)
                    continue
                }
                NSGraphicsContext.saveGraphicsState()
                ctx2.imageInterpolation = .high
                NSGraphicsContext.current = ctx2
                NSImage(cgImage: crop, size: .zero).draw(
                    in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                    from: .zero, operation: .copy, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
                out.append(rep.representation(using: .png, properties: [:]))
            }
            self.completion?(out)
        }
    }
}

// MARK: - hybrid terminal delegate

func termMarkdownContent() -> String {
    if let s = stdinMD { return s }
    guard let cur = initialFile else { return "" }
    if isDir(cur) { return indexMarkdown(for: cur) }
    if markdownExts.contains(cur.pathExtension.lowercased()),
       let s = try? String(contentsOf: cur, encoding: .utf8) { return s }
    die("markmore -t renders markdown and folders (open other files in the window mode)", code: 65)
}

func termIsDark() -> Bool {
    let fgbg = ProcessInfo.processInfo.environment["COLORFGBG"] ?? ""
    return !(fgbg.hasSuffix(";15") || fgbg.hasSuffix(";7"))
}

final class TermHybridDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let dark = termIsDark()
        var cols = 80
        var cssWidth: CGFloat = 640
        var wsz = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &wsz) == 0 {
            if wsz.ws_col > 10 { cols = Int(wsz.ws_col) }
            if wsz.ws_xpixel > 200 { cssWidth = min(760, CGFloat(wsz.ws_xpixel) / 2 - 12) }
        }
        cols = min(cols, 110)

        let renderer = HybridRenderer(cols: cols, dark: dark, graphics: termProtocol != nil)
        let (pieces, snippets) = renderer.render(termMarkdownContent())

        func emit(_ images: [Data?]) {
            let out = FileHandle.standardOutput
            for piece in pieces {
                switch piece {
                case .text(let t):
                    out.write(t.data(using: .utf8)!)
                case .snippet(let n):
                    if n < images.count, let png = images[n] {
                        emitImage(png)
                        out.write("\n".data(using: .utf8)!)
                    } else {
                        out.write("[block failed to render]\n".data(using: .utf8)!)
                    }
                }
            }
            if isatty(STDOUT_FILENO) != 0 {
                let p = TermPalette(dark: dark)
                out.write((p.dim + "── markmore -w opens the window" + p.reset + "\n").data(using: .utf8)!)
            }
            exit(0)
        }

        if snippets.isEmpty {
            emit([])
        } else {
            let baseDir = initialFile.map { isDir($0) ? $0 : $0.deletingLastPathComponent() }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let raster = SnippetRasterizer(snippets: snippets, cssWidth: cssWidth, dark: dark, baseDir: baseDir)
            objc_setAssociatedObject(self, "raster", raster, .OBJC_ASSOCIATION_RETAIN)
            raster.start { images in emit(images) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                die("markmore -t: render timed out", code: 70)
            }
        }
    }
}
