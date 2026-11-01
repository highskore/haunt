"""Render picked mockup screens (default: all in screens.json) at 2x with headless Chrome and write the manifest."""
import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from fid import DESIGN, SCALE, delta_e, hex_rgb, ink, rgb_hex, sample, scan  # noqa: E402
from tokens import FILES  # noqa: E402

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
REF = DESIGN / "reference"
VIEWPORT = (1500, 700)
GUARD_PX = 1.5

# Runs after the mockup's own script: isolates one section, pins its size, and reports DOM geometry.
INJECT = r"""
<style>:root { --mono: "Berkeley Mono Variable", "Berkeley Mono", "SF Mono", ui-monospace, Menlo, monospace; }</style>
<script>
(() => {
  const S = __SPEC__;
  document.querySelector('header.top').remove();
  const secs = [...document.querySelectorAll('section.item')];
  secs.forEach((s, i) => { if (i !== S.index - 1) s.remove(); });
  const sec = secs[S.index - 1];
  sec.querySelectorAll(':scope > .num, :scope > h2, :scope > p').forEach(e => e.remove());
  const main = document.querySelector('main');
  Object.assign(main.style, { padding: '0', margin: '0', maxWidth: 'none' });
  const root = sec.lastElementChild;
  Object.assign(root.style, { width: (S.width + 2) + 'px', boxShadow: 'none', borderRadius: '0' });
  if (S.fill) root.style.height = '442px';
  const crop = root.matches(S.crop) ? root : root.querySelector(S.crop);
  const cr = crop.getBoundingClientRect();
  const ox = cr.left + crop.clientLeft, oy = cr.top + crop.clientTop;
  const box = (el, text) => {
    let r = el.getBoundingClientRect();
    if (text) { const g = document.createRange(); g.selectNodeContents(el); r = g.getBoundingClientRect(); }
    return { left: r.left - ox, top: r.top - oy, right: r.right - ox, bottom: r.bottom - oy, width: r.width, height: r.height };
  };
  const q = (sel) => { const el = crop.querySelector(sel); if (!el) throw new Error('no element for ' + sel); return el; };
  const out = { crop: { w: crop.clientWidth, h: crop.clientHeight }, boxes: {}, text: {}, errors: [] };
  for (const sel of S.selectors) { try { out.boxes[sel] = box(q(sel), false); out.text[sel] = box(q(sel), true); } catch (e) { out.errors.push(String(e.message)); } }
  out.page = { x: ox, y: oy };
  const tag = document.createElement('script');
  tag.type = 'application/json'; tag.id = '__fid'; tag.textContent = JSON.stringify(out);
  document.body.appendChild(tag);
})();
</script>
"""


def expand(spec, groups):
    vars_ = spec.get("vars", {})

    def sub(item):
        item = dict(item)
        for k in ("sel", "expect_sel"):
            if k in item:
                for v, val in vars_.items():
                    item[k] = item[k].replace("$" + v, val)
        return item
    anchors, edges = [], []
    for g in spec.get("groups", []):
        anchors += [sub(a) for a in groups[g].get("anchors", [])]
        edges += [sub(e) for e in groups[g].get("edges", [])]
    anchors += [sub(a) for a in spec.get("anchors", [])]
    edges += [sub(e) for e in spec.get("edges", [])]
    return anchors, edges


def default_tol(a):
    # Text is sampled as its inkiest pixel, so it gets a little slack that flat surfaces don't.
    return 1.0 if a.get("text") or a["token"] == "color.claude" else 0.5


def coord(expr, box, axis):
    if expr.endswith("%"):
        return (box["left"] if axis == "x" else box["top"]) + float(expr[:-1]) / 100 * (box["width"] if axis == "x" else box["height"])
    for base in ("left", "right", "cx", "top", "bottom", "cy"):
        if expr.startswith(base):
            v = {"cx": (box["left"] + box["right"]) / 2, "cy": (box["top"] + box["bottom"]) / 2}.get(base, box.get(base))
            rest = expr[len(base):]
            return v + (float(rest) if rest else 0)
    raise ValueError(f"bad coordinate expr {expr!r}")


def point(at, box):
    return math.floor(coord(at[0], box, "x") * SCALE), math.floor(coord(at[1], box, "y") * SCALE)


def chrome(args):
    return subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--force-device-scale-factor={SCALE}",
                           f"--window-size={VIEWPORT[0]},{VIEWPORT[1]}", "--virtual-time-budget=3000", *args],
                          capture_output=True, text=True, check=True)


def render(name, spec, groups, tokens):
    anchors, edges = expand(spec, groups)
    selectors = sorted({a["sel"] for a in anchors} | {e["sel"] for e in edges} | {e["expect_sel"] for e in edges if "expect_sel" in e})
    js = json.dumps({"index": spec["index"], "crop": spec["crop"], "fill": spec.get("fill", False), "width": spec.get("width", 900), "selectors": selectors})
    html = FILES[spec["file"]].read_text().replace("</body>", INJECT.replace("__SPEC__", js) + "</body>")
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "page.html"
        page.write_text(html)
        dom = chrome(["--dump-dom", page.as_uri()]).stdout
        shot = Path(tmp) / "shot.png"
        chrome([f"--screenshot={shot}", page.as_uri()])
        full = Image.open(shot).convert("RGB")
    geo = json.loads(dom.split('id="__fid">', 1)[1].split("</script>", 1)[0])
    errors = list(geo["errors"])
    w, h = geo["crop"]["w"], geo["crop"]["h"]
    x0, y0 = round(geo["page"]["x"] * SCALE), round(geo["page"]["y"] * SCALE)
    im = full.crop((x0, y0, x0 + w * SCALE, y0 + h * SCALE))

    out_anchors = []
    for a in anchors:
        box = geo["boxes"].get(a["sel"])
        if box is None:
            continue
        expect = tokens[a["token"]]["value"]
        entry = {"name": a["name"], "token": a["token"], "expect": expect, "tol": a.get("tol", default_tol(a))}
        if a.get("text"):
            t = geo["text"][a["sel"]]
            rect = [math.floor(t["left"] * SCALE), math.floor(t["top"] * SCALE), math.ceil(t["right"] * SCALE), math.ceil(t["bottom"] * SCALE)]
            got, _ = ink(im, rect)
            entry.update(mode="text", rect=rect)
        else:
            x, y = point(a["at"], box)
            got = sample(im, x, y)
            entry.update(mode="point", x=x, y=y)
        if got is None:
            errors.append(f"{a['name']}: off the crop")
            continue
        de = delta_e(got, hex_rgb(expect))
        entry["ref"] = rgb_hex(got)
        if de > entry["tol"]:
            errors.append(f"{a['name']}: reference shows {rgb_hex(got)}, token {a['token']} is {expect} (ΔE {de:.1f}); anchor misplaced")
        out_anchors.append(entry)

    out_edges = []
    for e in edges:
        box = geo["boxes"].get(e["sel"])
        if box is None:
            continue
        x, y = point(e["from"], box)
        found = scan(im, x, y, e["dir"])
        ebox = geo["boxes"][e.get("expect_sel", e["sel"])]
        axis = "y" if e["dir"] in ("up", "down") else "x"
        dom_px = coord(e["expect"], ebox, axis) * SCALE - (1 if e["dir"] in ("up", "left") else 0)
        if found is None or abs(found - dom_px) > GUARD_PX:
            errors.append(f"{e['name']}: scan found {found}, DOM says {dom_px:.1f}; probe misplaced")
            continue
        out_edges.append({"name": e["name"], "x": x, "y": y, "dir": e["dir"], "expect": found, "tol": e.get("tol", 2)})

    REF.mkdir(exist_ok=True)
    im.save(REF / f"{name}.png")
    return {"file": f"haunt-reference/mockups/{FILES[spec['file']].parent.name}/index.html", "index": spec["index"], "crop": spec["crop"],
            "size_pt": [w, h], "size_px": [w * SCALE, h * SCALE], "anchors": out_anchors, "edges": out_edges}, errors


def main():
    cfg = json.loads((DESIGN / "screens.json").read_text())
    tokens = json.loads((DESIGN / "tokens.json").read_text())["tokens"]
    manifest_path = REF / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    names = sys.argv[1:] or list(cfg["screens"])
    failed = False
    for name in names:
        entry, errors = render(name, cfg["screens"][name], cfg["groups"], tokens)
        manifest[name] = entry
        status = "ok" if not errors else "SPEC ERRORS"
        print(f"{name}: {entry['size_pt'][0]}x{entry['size_pt'][1]} pt, {len(entry['anchors'])} anchors, {len(entry['edges'])} edges  {status}")
        for err in errors:
            print("   ", err)
        failed |= bool(errors)
    manifest = {k: manifest[k] for k in cfg["screens"] if k in manifest}
    manifest_path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
