"""Print the on-screen window id owned by a pid, so captures never pick up another haunt build."""
import sys

import Quartz

opts = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []:
    if w.get("kCGWindowOwnerPID") == int(sys.argv[1]) and w.get("kCGWindowLayer", 0) == 0:
        b = w["kCGWindowBounds"]
        print(int(w["kCGWindowNumber"]), int(b["Width"]), int(b["Height"]))
        sys.exit(0)
sys.exit(1)
