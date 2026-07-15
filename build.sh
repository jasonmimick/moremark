#!/bin/bash
# ./build.sh              build + install to ~/Applications and ~/.local/bin
# ./build.sh --build-only assemble ./markmore.app in cwd only (used by Homebrew)
set -euo pipefail
cd "$(dirname "$0")"

vendor() { [ -f "$2" ] || curl -fsSL "$1" -o "$2"; }
vendor https://cdn.jsdelivr.net/npm/marked/marked.min.js marked.min.js
vendor https://cdn.jsdelivr.net/npm/github-markdown-css/github-markdown.css github-markdown.css
vendor https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js highlight.min.js
vendor https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github.min.css hljs-github.css
vendor https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css hljs-github-dark.css
vendor https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js mermaid.min.js
vendor https://cdn.jsdelivr.net/npm/katex/dist/katex.min.js katex.min.js
vendor https://cdn.jsdelivr.net/npm/katex/dist/contrib/auto-render.min.js katex-auto.min.js
vendor https://cdn.jsdelivr.net/npm/katex/dist/katex.min.css katex.min.css
if [ ! -f katex-inline.css ]; then
  python3 - <<'PYEOF'
import re, base64, urllib.request
css = open('katex.min.css').read()
for f in sorted(set(re.findall(r'url\((fonts/[^)]+\.woff2)\)', css))):
    data = urllib.request.urlopen(f"https://cdn.jsdelivr.net/npm/katex/dist/{f}").read()
    css = css.replace(f"url({f})", "url(data:font/woff2;base64," + base64.b64encode(data).decode() + ")")
open('katex-inline.css', 'w').write(css)
PYEOF
fi

b64() { base64 -i "$1" | tr -d '\n'; }
cat > Resources.swift <<EOF
let markedJSBase64 = "$(b64 marked.min.js)"
let ghCSSBase64 = "$(b64 github-markdown.css)"
let hljsJSBase64 = "$(b64 highlight.min.js)"
let hljsLightCSSBase64 = "$(b64 hljs-github.css)"
let hljsDarkCSSBase64 = "$(b64 hljs-github-dark.css)"
let mermaidJSBase64 = "$(b64 mermaid.min.js)"
let katexJSBase64 = "$(b64 katex.min.js)"
let katexAutoJSBase64 = "$(b64 katex-auto.min.js)"
let katexCSSBase64 = "$(b64 katex-inline.css)"
EOF

swiftc -O -o markmore-bin main.swift Resources.swift terminal.swift

if [ ! -f markmore.icns ]; then
  swift genicon.swift
  iconutil -c icns markmore.iconset -o markmore.icns
fi

APP="markmore.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp markmore-bin "$APP/Contents/MacOS/markmore"
cp Info.plist "$APP/Contents/Info.plist"
cp markmore.icns "$APP/Contents/Resources/markmore.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [ "${1:-}" = "--build-only" ]; then
  echo "built: ./$APP"
  exit 0
fi

rm -rf "$HOME/Applications/markmore.app"
mkdir -p "$HOME/Applications"
cp -R "$APP" "$HOME/Applications/markmore.app"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/markmore" <<'EOF'
#!/bin/bash
exec "$HOME/Applications/markmore.app/Contents/MacOS/markmore" "$@"
EOF
chmod +x "$HOME/.local/bin/markmore"
echo "installed: ~/Applications/markmore.app + ~/.local/bin/markmore"
