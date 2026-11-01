"""Compare an app window capture with a mockup screen: anchors at ΔE76 <= 2, edges at +-2 px (1 pt); writes a heatmap and report."""
import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
from fid import DESIGN, delta_e, hex_rgb, ink, load_srgb, rgb_hex, sample, scan  # noqa: E402

GREEN, RED = (60, 220, 90), (255, 60, 60)


def run(capture, screen, offset=(0, 0), out_dir=DESIGN / "out"):
    manifest = json.loads((DESIGN / "reference/manifest.json").read_text())
    if screen not in manifest:
        sys.exit(f"unknown screen {screen!r}; known: {', '.join(manifest)}")
    spec = manifest[screen]
    ref = Image.open(DESIGN / f"reference/{screen}.png").convert("RGB")
    raw, profile = load_srgb(capture)
    dx, dy = offset
    app = raw.crop((dx, dy, dx + ref.width, dy + ref.height))
    results = []
    if profile and "srgb" not in profile.lower():
        print(f"WARNING: capture is tagged {profile!r}, not sRGB; converted to sRGB before comparing. "
              "haunt should render in sRGB so its colours match the tokens.", file=sys.stderr)
    if (raw.width - dx, raw.height - dy) != ref.size:
        results.append({"kind": "size", "name": "window.size", "ok": False,
                        "detail": f"capture is {raw.width - dx}x{raw.height - dy} px after offset, reference is {ref.width}x{ref.height} px "
                                  f"(size the window to {spec['size_pt'][0]}x{spec['size_pt'][1]} pt)"})

    for a in spec["anchors"]:
        want = hex_rgb(a["expect"])
        if a["mode"] == "text":
            got, _ = ink(app, a["rect"])
        else:
            got = sample(app, a["x"], a["y"])
        de = delta_e(got, want) if got else float("inf")
        results.append({"kind": "anchor", "name": a["name"], "ok": de <= a["tol"], "token": a["token"],
                        "expect": a["expect"], "got": rgb_hex(got) if got else None, "de": round(de, 2), "anchor": a})

    for e in spec["edges"]:
        got = scan(app, e["x"], e["y"], e["dir"])
        off = None if got is None else got - e["expect"]
        results.append({"kind": "edge", "name": e["name"], "ok": off is not None and abs(off) <= e["tol"],
                        "expect": e["expect"], "got": got, "off_px": off, "edge": e})

    out_dir.mkdir(parents=True, exist_ok=True)
    heatmap(ref, app, results).save(out_dir / f"{screen}-diff.png")
    ok = all(r["ok"] for r in results)
    report = {"screen": screen, "capture": str(capture), "profile": profile, "pass": ok,
              "failed": [r["name"] for r in results if not r["ok"]],
              "results": [{k: v for k, v in r.items() if k not in ("anchor", "edge")} for r in results]}
    (out_dir / f"{screen}-report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")
    return ok, results, out_dir


def heatmap(ref, app, results):
    diff = ImageChops.difference(ref, app).convert("L").point(lambda v: min(255, v * 8))
    base = Image.blend(ref, app, 0.5).point(lambda v: v // 2)
    img = Image.composite(Image.new("RGB", ref.size, RED), base, diff)
    d = ImageDraw.Draw(img)
    for r in results:
        col = GREEN if r["ok"] else RED
        if r["kind"] == "anchor":
            a = r["anchor"]
            if a["mode"] == "text":
                d.rectangle(a["rect"], outline=col)
                x, y = a["rect"][0], a["rect"][1]
            else:
                x, y = a["x"], a["y"]
                d.ellipse((x - 5, y - 5, x + 5, y + 5), outline=col, width=2)
        elif r["kind"] == "edge":
            e = r["edge"]
            x, y = e["x"], e["y"]
            ex, ey = (x, e["expect"]) if e["dir"] in ("up", "down") else (e["expect"], y)
            d.line((x, y, ex, ey), fill=col, width=1)
            d.line((ex - 6, ey, ex + 6, ey) if e["dir"] in ("up", "down") else (ex, ey - 6, ex, ey + 6), fill=col, width=2)
        else:
            continue
        if not r["ok"]:
            d.text((x + 8, y - 6), r["name"], fill=RED)
    return img


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("capture", type=Path)
    p.add_argument("screen")
    p.add_argument("--offset", default="0,0", help="px to skip at the capture's top-left, e.g. a window frame")
    p.add_argument("--out", type=Path, default=DESIGN / "out")
    args = p.parse_args()
    ok, results, out_dir = run(args.capture, args.screen, tuple(int(v) for v in args.offset.split(",")), args.out)
    for r in results:
        mark = "ok  " if r["ok"] else "FAIL"
        if r["kind"] == "anchor":
            print(f"{mark} {r['name']:<24} {r['token']:<24} want {r['expect']} got {r['got']}  ΔE {r['de']}")
        elif r["kind"] == "edge":
            print(f"{mark} {r['name']:<24} edge {r['edge']['dir']:<5} want {r['expect']} got {r['got']}  off {r['off_px']} px")
        else:
            print(f"{mark} {r['name']:<24} {r['detail']}")
    n_fail = sum(not r["ok"] for r in results)
    print(f"\n{args.screen}: {'PASS' if ok else 'FAIL'} ({len(results) - n_fail}/{len(results)} checks)  heatmap: {out_dir / (args.screen + '-diff.png')}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
