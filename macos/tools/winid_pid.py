"""Print the on-screen window id owned by a pid, so captures never pick up another haunt build.
An optional width in pt picks one of its windows, such as the palette panel over the main window.
Prints: id width height x y (pt)."""
import sys

import Quartz

opts = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []:
    if w.get("kCGWindowOwnerPID") == int(sys.argv[1]) and w.get("kCGWindowLayer", 0) == 0:
        b = w["kCGWindowBounds"]
        if len(sys.argv) > 2 and int(b["Width"]) != int(sys.argv[2]):
            continue
        print(int(w["kCGWindowNumber"]), int(b["Width"]), int(b["Height"]), int(b["X"]), int(b["Y"]))
        sys.exit(0)
sys.exit(1)
