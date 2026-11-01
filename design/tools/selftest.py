"""Prove the kit catches drift: references must pass, altered copies and altered mockup CSS must fail."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from check import run  # noqa: E402
from fid import DESIGN  # noqa: E402
from tokens import MOCKUPS  # noqa: E402

TOOLS = Path(__file__).parent


def brighten(im):
    return im.point(lambda v: min(255, v + 6))


def shift_down_2pt(im):
    out = im.copy()
    out.paste(im.crop((0, 0, im.width, im.height - 4)), (0, 4))
    return out


def widen_sidebar_2pt(im, edge_x):
    out = im.copy()
    out.paste(im.crop((edge_x - 4, 0, im.width - 4, im.height)), (edge_x, 0))
    return out


def recolour(im, src, dst):
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            if px[x, y] == src:
                px[x, y] = dst
    return im


def main():
    manifest = json.loads((DESIGN / "reference/manifest.json").read_text())
    screens = list(manifest)
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # Tokens: clean mockups pass, a one-step grey change in a copy must fail.
        r = subprocess.run([sys.executable, TOOLS / "tokens.py", "--check"], capture_output=True, text=True)
        print(("ok  " if r.returncode == 0 else "FAIL") + " tokens.json matches mockups")
        if r.returncode:
            fails.append("tokens clean")
        alt = tmp / "mockups"
        shutil.copytree(MOCKUPS / "pawr-ui", alt / "pawr-ui")
        shutil.copytree(MOCKUPS / "pawr-agents-view", alt / "pawr-agents-view")
        f = alt / "pawr-ui/index.html"
        f.write_text(f.read_text().replace("background: #0e0e0e", "background: #0f0f0f", 1))
        r = subprocess.run([sys.executable, TOOLS / "tokens.py", "--check"], capture_output=True, text=True,
                           env={**os.environ, "HAUNT_MOCKUPS": str(alt)})
        print(("ok  " if r.returncode else "FAIL") + " tokens drift caught (.side #0e0e0e -> #0f0f0f)")
        if not r.returncode:
            fails.append("tokens drift")

        for s in screens:
            ref = Image.open(DESIGN / f"reference/{s}.png").convert("RGB")
            ok, res, _ = run(DESIGN / f"reference/{s}.png", s, out_dir=tmp / "out")
            n = len(res)
            print(f"{'ok  ' if ok else 'FAIL'} {s:<20} reference passes ({n} checks)")
            if not ok:
                fails.append(f"{s} reference")
            for label, fn in (("brightened +6", brighten), ("shifted 2 pt down", shift_down_2pt)):
                p = tmp / f"{s}-alt.png"
                fn(ref.copy()).save(p)
                ok, res, _ = run(p, s, out_dir=tmp / "out")
                bad = [r["name"] for r in res if not r["ok"]]
                print(f"{'FAIL' if ok else 'ok  '} {s:<20} {label} fails ({len(bad)}/{len(res)}: {', '.join(bad[:4])}{'...' if len(bad) > 4 else ''})")
                if ok:
                    fails.append(f"{s} {label}")

        # One edge only: the sidebar 2 pt wider must fail on sidebar.right.
        s = "ui-03-icon-only"
        edge = next(e for e in manifest[s]["edges"] if e["name"] == "sidebar.right")["expect"]
        p = tmp / "wide.png"
        widen_sidebar_2pt(Image.open(DESIGN / f"reference/{s}.png").convert("RGB"), edge).save(p)
        ok, res, _ = run(p, s, out_dir=tmp / "out")
        bad = [r["name"] for r in res if not r["ok"]]
        print(f"{'FAIL' if ok else 'ok  '} {s:<20} sidebar 2 pt wider fails on: {', '.join(bad)}")
        if ok or "sidebar.right" not in bad:
            fails.append("sidebar widen")

        # One element only: the selected row #1a1a1a -> #202020 must fail exactly on that row's checks.
        s = "ui-06-grouped-flat"
        p = tmp / "row.png"
        recolour(Image.open(DESIGN / f"reference/{s}.png").convert("RGB"), (26, 26, 26), (32, 32, 32)).save(p)
        ok, res, _ = run(p, s, out_dir=DESIGN / "out/selftest")
        bad = [r["name"] for r in res if not r["ok"]]
        print(f"{'FAIL' if ok else 'ok  '} {s:<20} selected row #1a1a1a -> #202020 fails on: {', '.join(bad)}")
        if ok or "row.sel.bg" not in bad:
            fails.append("selected row recolour")
    print("\nselftest " + ("PASSED" if not fails else "FAILED: " + "; ".join(fails)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
