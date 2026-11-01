"""Prove the kit catches drift: references must pass, altered copies and altered mockup CSS must fail."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageCms

sys.path.insert(0, str(Path(__file__).parent))
from check import run  # noqa: E402
from fid import DESIGN, hex_rgb  # noqa: E402
from tokens import MOCKUPS  # noqa: E402

TOOLS = Path(__file__).parent
P3 = "/System/Library/ColorSync/Profiles/Display P3.icc"


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

        # Near-identical greys a ΔE 2 check let through must now fail on exactly the element that changed.
        s = "ui-06-grouped-flat"
        cases = [("#1a1a1a", "#202020", "row.sel.bg"), ("#0e0e0e", "#0b0b0b", "sidebar.bg"),
                 ("#1a1a1a", "#1c1c1c", "row.sel.bg"), ("#6b6b6b", "#6f6f6f", "label.text")]
        for src, dst, anchor in cases:
            p = tmp / "recolour.png"
            recolour(Image.open(DESIGN / f"reference/{s}.png").convert("RGB"), hex_rgb(src), hex_rgb(dst)).save(p)
            ok, res, _ = run(p, s, out_dir=tmp / "out")
            bad = [r["name"] for r in res if not r["ok"]]
            print(f"{'FAIL' if anchor not in bad else 'ok  '} {s:<20} {src} -> {dst} fails on: {', '.join(bad)}")
            if anchor not in bad:
                fails.append(f"{src} -> {dst}")

        # A Display P3-tagged capture must be converted back and still pass.
        p = tmp / "p3.png"
        p3 = ImageCms.ImageCmsProfile(P3)
        im = ImageCms.profileToProfile(Image.open(DESIGN / f"reference/{s}.png").convert("RGB"),
                                       ImageCms.createProfile("sRGB"), p3, outputMode="RGB")
        im.save(p, icc_profile=p3.tobytes())
        ok, res, _ = run(p, s, out_dir=tmp / "out")
        bad = [r["name"] for r in res if not r["ok"]]
        print(f"{'ok  ' if ok else 'FAIL'} {s:<20} P3-tagged capture converts and passes{': ' + ', '.join(bad) if bad else ''}")
        if not ok:
            fails.append("P3 conversion")
    print("\nselftest " + ("PASSED" if not fails else "FAILED: " + "; ".join(fails)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
