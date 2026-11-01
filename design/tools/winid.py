"""Print the window id of an app's frontmost on-screen window, for `screencapture -l`."""
import argparse
import sys

import Quartz


def windows(owner, title=None):
    opts = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    for w in Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []:
        if w.get("kCGWindowOwnerName") != owner or w.get("kCGWindowLayer", 0) != 0:
            continue
        name = w.get("kCGWindowName") or ""
        if title and title not in name:
            continue
        b = w["kCGWindowBounds"]
        yield int(w["kCGWindowNumber"]), name, (int(b["X"]), int(b["Y"]), int(b["Width"]), int(b["Height"]))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("owner")
    p.add_argument("--title")
    p.add_argument("--all", action="store_true", help="list every matching window with title and bounds")
    args = p.parse_args()
    found = list(windows(args.owner, args.title))
    if not found:
        sys.exit(f"no on-screen window owned by {args.owner!r}")
    if args.all:
        for wid, name, (x, y, w, h) in found:
            print(f"{wid}\t{w}x{h} pt at {x},{y}\t{name}")
    else:
        print(found[0][0])


if __name__ == "__main__":
    main()
