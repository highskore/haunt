#!/bin/bash
# Copies Ghostty's Swift wrapper (macos/Sources/Ghostty) and the app-target files it
# references from our pinned checkout into Vendor/, then applies haunt's patches.
# Adapted from Gutter's vendor.sh (github.com/akras14/gutter, MIT, (c) 2026 Alex Kras).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/deps-src/ghostty}/macos/Sources"
DEST="$ROOT/macos/Vendor"
[ -d "$SRC/Ghostty" ] || { echo "ghostty sources not found at $SRC" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/Ghostty" "$DEST/Support"
rsync -a "$SRC/Ghostty/" "$DEST/Ghostty/"

for f in \
  Helpers/KeyboardLayout.swift Helpers/Fullscreen.swift Helpers/Cursor.swift Helpers/Weak.swift \
  Helpers/URLHoverBanner.swift Helpers/UntrustedURL.swift Helpers/UntrustedURLAlert.swift \
  Helpers/Backport.swift Helpers/AppInfo.swift Helpers/Private/CGS.swift Helpers/Private/Dock.swift \
  Helpers/ObjCExceptionCatcher.h Helpers/ObjCExceptionCatcher.m \
  Helpers/Extensions/UserDefaults+Extension.swift Helpers/Extensions/NSPasteboard+Extension.swift \
  Helpers/Extensions/OSPasteboard+Extension.swift Helpers/Extensions/EventModifiers+Extension.swift \
  Helpers/Extensions/Transferable+Extension.swift Helpers/Extensions/NSScreen+Extension.swift \
  Helpers/Extensions/NSMenuItem+Extension.swift Helpers/Extensions/NSAppearance+Extension.swift \
  Helpers/Extensions/Optional+Extension.swift Helpers/Extensions/Array+Extension.swift \
  Helpers/Extensions/String+Extension.swift Helpers/Extensions/NSWindow+Extension.swift \
  Helpers/Extensions/NSApplication+Extension.swift Helpers/Extensions/NSView+Extension.swift \
  Helpers/Extensions/OSColor+Extension.swift Helpers/Extensions/KeyboardShortcut+Extension.swift Helpers/Extensions/NSWorkspace+Extension.swift \
  "Features/Secure Input/SecureInputOverlay.swift" "Features/Secure Input/SecureInput.swift" \
  Features/Splits/SplitTree.swift Features/Splits/SplitView.swift Features/Splits/SplitView.Divider.swift \
  Features/QuickTerminal/QuickTerminalPosition.swift Features/QuickTerminal/QuickTerminalScreen.swift \
  Features/QuickTerminal/QuickTerminalSize.swift Features/QuickTerminal/QuickTerminalSpaceBehavior.swift
do
  cp "$SRC/$f" "$DEST/Support/"
done

# Upstream relies on Xcode's batch-mode import leaking into this file.
{ echo "import Foundation"; cat "$SRC/Ghostty/Ghostty.Error.swift"; } > "$DEST/Ghostty/Ghostty.Error.swift"

# haunt patch: route OSC 777 / OSC 9 notifications to the app before Ghostty posts one.
uv run --no-project python -I - "$DEST/Ghostty/Ghostty.App.swift" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """                guard let body = String(cString: n.body!, encoding: .utf8) else { return }
                showDesktopNotification(surfaceView, title: title, body: body)
"""
new = """                guard let body = String(cString: n.body!, encoding: .utf8) else { return }
                // haunt patch: the embedder consumes agent events.
                if let hook = Ghostty.App.desktopNotificationHook, hook(surfaceView, title, body) { return }
                showDesktopNotification(surfaceView, title: title, body: body)
"""
assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)
anchor = "        /// Optional delegate\n"
assert s.count(anchor) == 1
s = s.replace(anchor, "        /// haunt patch: return true to swallow the notification.\n        static var desktopNotificationHook: ((SurfaceView, String, String) -> Bool)?\n\n" + anchor)
p.write_text(s)
print("patched Ghostty.App.swift desktop notification hook")
PYEOF

echo "vendored $(find "$DEST" -name '*.swift' | wc -l | tr -d ' ') swift files"

# Xcode 16.3 (Swift 6.1, macOS 15.4 SDK): hide macOS 26 SDK-only symbols behind the compiler version.
uv run --no-project python -I - "$DEST" <<'PYEOF'
import sys, pathlib
d = pathlib.Path(sys.argv[1])
def patch(rel, old, new):
    p = d / rel
    s = p.read_text()
    assert s.count(old) == 1, (rel, s.count(old))
    p.write_text(s.replace(old, new))
patch("Support/Backport.swift",
"""    @available(macOS 26, *)
    var official: Glass {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
""",
"""    #if compiler(>=6.2)
    @available(macOS 26, *)
    var official: Glass {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
    #endif
""")
patch("Ghostty/Surface View/SurfaceView.swift",
"""            if #available(macOS 26.0, *) {
                return ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true)
            } else {
                return RoundedRectangle(cornerRadius: 8)
            }
""",
"""            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                return ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true)
            } else {
                return RoundedRectangle(cornerRadius: 8)
            }
            #else
            return RoundedRectangle(cornerRadius: 8)
            #endif
""")
# Same type-checker blow-up Gutter hit on Swift 6.3 CLT; indices-based ForEach avoids it.
patch("Ghostty/Surface View/SurfaceView.swift",
      "ForEach(Array(keySequence.enumerated()), id: \\.offset) { _, key in",
      "ForEach(keySequence.indices, id: \\.self) { idx in")
patch("Ghostty/Surface View/SurfaceView.swift", "KeyCap(key.description)", "KeyCap(keySequence[idx].description)")
patch("Ghostty/Surface View/SurfaceView.swift",
      "ForEach(Array(keyTables.enumerated()), id: \\.offset) { index, table in",
      "ForEach(keyTables.indices, id: \\.self) { index in")
patch("Ghostty/Surface View/SurfaceView.swift", "Text(verbatim: table)", "Text(verbatim: keyTables[index])")
# Interpolation with `default:` is Swift 6.2 (SE-0477).
patch("Ghostty/Surface View/SurfaceView.swift",
      'Text("\\(selected + 1)/\\(searchState.total, default: "?")")',
      'Text("\\(selected + 1)/\\(searchState.total.map(String.init) ?? "?")")')
print("patched macOS 26 SDK symbols")
PYEOF
