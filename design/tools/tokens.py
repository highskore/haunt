"""Build design/tokens.json from the mockup <style> blocks (--write), or fail if it has drifted (--check)."""
import json
import os
import re
import sys
from pathlib import Path

DESIGN = Path(__file__).resolve().parent.parent
MOCKUPS = Path(os.environ.get("HAUNT_MOCKUPS", Path.home() / "code/haunt-reference/mockups"))
FILES = {"ui": MOCKUPS / "pawr-ui/index.html", "av": MOCKUPS / "pawr-agents-view/index.html"}
OUT = DESIGN / "tokens.json"

# Page chrome around the mockups, not part of the app.
PAGE_ONLY = re.compile(r"^(\*|header\.top.*|main|\.item.*)$")
HEX = re.compile(r"#[0-9a-fA-F]{3,8}\b")
NUM = re.compile(r"(?<![#\w])-?\d*\.?\d+")

# Sources must all agree; inline tuples cover values that only exist in the mockups' JS-built markup.
SEMANTIC = {
    "font.ui": ["ui|:root|--ui"],
    "font.mono.css": ["ui|:root|--mono", "av|:root|--mono"],
    "font.base.size": ["ui|body|font@0"],
    "font.base.line": ["ui|body|font@1"],
    "color.window.bg": ["ui|.win|background","av|.win|background", "av|.float|background"],
    "color.window.border": ["ui|.win|border@color", "av|.win|border@color"],
    "color.sidebar.bg": ["ui|.side|background", "av|.side|background"],
    "color.hairline": ["ui|.title|border-bottom@color", "ui|.side|border-right@color", "av|.foot|border-top@color"],
    "color.row.selected": ["ui|.tab.sel|background", "av|.tab.sel|background"],
    "color.text.primary": ["ui|.tab .name|color", "av|.tab .name|color"],
    "color.text.terminal": ["ui|.pane|color", "av|.pane|color"],
    "color.text.meta": ["ui|.tab .meta|color", "ui|.tab .right|color", "av|.dim|color"],
    "color.text.label": ["ui|.label|color", "ui|.muted|color", "av|.foot|color", "av|.tbl .th|color"],
    "color.text.sub": ["ui|.sub|color", "ui|.kbd|color", "av|.tbl .num|color"],
    "color.text.hi": ["ui|.pane .hi|color", "av|.hi|color"],
    "color.text.ok": ["ui|.pane .ok|color", "ui|.tab .ic|color", "av|.tbl .mono|color"],
    "color.text.placeholder": [("av|inline|color:#5f5f5f;font-size:12px", "#5f5f5f")],
    "color.needs": ["av|.needs|color", ("ui|inline|<span style=\"color:#fff\">needs you</span>", "#ffffff")],
    "color.lights": ["ui|.lights i|background"],
    "color.bar.track": ["ui|.bar|background", "av|.pbar|background"],
    "color.bar.fill": ["ui|.bar b|background", "av|.pbar b|background"],
    "color.icon.bg": ["ui|.tab .ic|background", "av|.ic|background"],
    "color.icon.fg": ["ui|.tab .ic|color", "av|.ic|color"],
    "color.kbd.border": ["ui|.kbd|border@color", "av|.btn|border@color"],
    "color.card.border": ["av|.card|border@color"],
    "color.card.bg": ["av|.card|background"],
    "color.float.border": ["av|.float|border@color"],
    "color.table.rule": ["av|.tbl > div|border-bottom@color"],
    "color.btn.fg": ["av|.btn|color"],
    "color.btn.primary.bg": ["av|.btn.pri|background"],
    "color.btn.primary.fg": ["av|.btn.pri|color"],
    "color.dot": ["ui|.dot|background"],
    "color.dot.hollow": ["ui|.dot.hollow|border@color"],
    "color.claude": ["ui|:root|--claude", "av|:root|--claude", ("ui|inline|fill=\"#D97757\"", "#d97757")],
    "color.zen.track": [("ui|inline|height:2px;background:#1e1e1e", "#1e1e1e")],
    "color.ticker.sep": [("av|inline|<span style=\"color:#2a2a2a\">│</span>", "#2a2a2a")],
    "color.focus.expanded.bg": [("av|inline|background:#121212;border-bottom:1px solid #1f1f1f", "#121212")],
    "color.focus.term.border": [("av|inline|border:1px solid #222;border-radius:6px;background:#0b0b0b", "#222222")],
    "color.monitor.bg": [("av|inline|background:#080808", "#080808")],
    "size.window.h": ["ui|.win|height", "av|.win|height"],
    "size.window.radius": ["ui|.win|border-radius"],
    "size.titlebar.h": ["ui|.title|height", "av|.title|height"],
    "size.titlebar.padx": ["ui|.title|padding@1"],
    "size.titlebar.gap": ["ui|.title|gap"],
    "size.titlebar.icons.gap": [("ui|inline|display:flex;gap:16px;font-size:14px", 16)],
    "size.titlebar.icons.font": [("ui|inline|display:flex;gap:16px;font-size:14px", 14)],
    "size.crumb.font": [("ui|inline|<span style=\"font-size:12px;color:#8a8a8a\">pawr", 12)],
    "size.crumb.spacer": [("ui|inline|<span style=\"width:52px\"></span>", 52)],
    "size.lights.d": ["ui|.lights i|width", "ui|.lights i|height"],
    "size.lights.gap": ["ui|.lights|gap"],
    "size.sidebar.w": ["ui|.side|width"],
    "size.sidebar.rail.w": [("ui|inline|side(TABS.map(ring).join(''), 56, 'padding-top:4px')", 56)],
    "size.sidebar.rail.padtop": [("ui|inline|side(TABS.map(ring).join(''), 56, 'padding-top:4px')", 4)],
    "size.sidebar.padtop.icon_only": [("ui|inline|TABS.map((t, i) => tabRow(t, i)).join(''), 250, 'padding-top:6px'", 6)],
    "size.rail.cell": [("ui|inline|width:36px;height:36px;display:grid;place-items:center;margin:8px auto", 36)],
    "size.rail.cell.margin": [("ui|inline|width:36px;height:36px;display:grid;place-items:center;margin:8px auto", 8)],
    "size.rail.cell.radius": [("ui|inline|background:#1a1a1a;border-radius:9px", 9)],
    "size.rail.ring.r": [("ui|inline|cx=\"18\" cy=\"18\" r=\"15\" fill=\"none\" stroke=\"#2a2a2a\" stroke-width=\"2\"", 15)],
    "size.rail.ring.stroke": [("ui|inline|cx=\"18\" cy=\"18\" r=\"15\" fill=\"none\" stroke=\"#2a2a2a\" stroke-width=\"2\"", 2)],
    "size.narrow.w": [("av|inline|right:24px;top:24px;bottom:24px;width:280px", 280)],
    "size.floating.w": [("av|inline|right:48px;top:56px;width:300px", 300)],
    "size.floating.header.h": [("av|inline|height:30px;display:flex;align-items:center;gap:8px;padding:0 12px;border-bottom:1px solid #1c1c1c", 30)],
    "size.floating.row.pad": [("av|inline|style: 'padding:7px 12px'", [7, 12])],
    "size.menu.w": [("av|inline|right:150px;top:32px;width:340px", 340)],
    "size.ticker.h": [("av|inline|height:30px;background:#0b0b0b;border-bottom:1px solid #242424", 30)],
    "size.focus.row.pad": [("av|inline|align-items:center;padding:9px 16px;border-bottom:1px solid #171717", [9, 16])],
    "size.pane.pad": ["ui|.pane|padding"],
    "size.pane.font": ["ui|.pane|font@0"],
    "size.pane.line": ["ui|.pane|font@1"],
    "size.label.font": ["ui|.label|font-size"],
    "size.label.tracking_em": ["ui|.label|letter-spacing"],
    "size.label.pad": ["ui|.label|padding"],
    "size.row.pad": ["ui|.tab|padding", "av|.tab|padding"],
    "size.row.cols": ["ui|.tab|grid-template-columns"],
    "size.row.gap": ["ui|.tab|gap"],
    "size.row.name": ["ui|.tab|font-size"],
    "size.row.meta": ["ui|.tab .meta|font-size"],
    "size.row.right": ["ui|.tab .right|font-size"],
    "size.icon.size": ["ui|.tab .ic|width", "ui|.tab .ic|height"],
    "size.icon.radius": ["ui|.tab .ic|border-radius"],
    "size.icon.glyph": ["ui|.tab .ic|font@0"],
    "size.claude.icon": [("ui|inline|viewBox=\"0 0 24 24\" width=\"16\" height=\"16\"", 16)],
    "size.bar.h": ["ui|.bar|height", "av|.pbar|height"],
    "size.bar.mt": ["ui|.bar|margin-top"],
    "size.sub.font": ["ui|.sub|font-size"],
    "size.sub.mt": ["ui|.sub|margin-top"],
    "size.sub.gap": ["ui|.sub|gap"],
    "size.dot": ["ui|.dot|width"],
    "size.dot.hollow.border": ["ui|.dot.hollow|border@0"],
    "size.kbd.font": ["ui|.kbd|font@0"],
    "size.kbd.radius": ["ui|.kbd|border-radius"],
    "size.kbd.pad": ["ui|.kbd|padding"],
    "size.kbd.line": ["ui|.kbd|line-height"],
    "size.btn.font": ["av|.btn|font-size"],
    "size.btn.radius": ["av|.btn|border-radius"],
    "size.btn.pad": ["av|.btn|padding"],
    "size.foot.h": ["av|.foot|height"],
    "size.foot.h.floating": [("av|inline|<div class=\"foot\" style=\"height:26px\">", 26)],
    "size.foot.gap": ["av|.foot|gap"],
    "size.foot.padx": ["av|.foot|padding@1"],
    "size.foot.font": ["av|.foot|font-size"],
    "size.card.radius": ["av|.card|border-radius"],
    "size.card.pad": ["av|.card|padding"],
    "size.card.gap": ["av|.card|gap"],
    "size.card.hd.font": ["av|.card .hd|font-size"],
    "size.card.out.font": ["av|.card .out|font@0"],
    "size.float.radius": ["av|.float|border-radius"],
    "size.grid.gap": [("av|inline|grid-template-rows:1fr 1fr;gap:12px;padding:14px", 12)],
    "size.grid.pad": [("av|inline|grid-template-rows:1fr 1fr;gap:12px;padding:14px", 14)],
    "size.table.cell.pad": ["av|.tbl > div|padding"],
    "size.table.font": ["av|.tbl|font-size"],
    "size.table.th.font": ["av|.tbl .th|font-size"],
    "size.zen.bar": [("ui|inline|height:2px;background:#1e1e1e", 2)],
}


def norm_color(c):
    c = c.lower()
    if len(c) == 4:
        c = "#" + "".join(ch * 2 for ch in c[1:])
    return c


def parse_value(v):
    v = v.strip()
    if HEX.fullmatch(v):
        return norm_color(v)
    nums = NUM.findall(HEX.sub("", v))
    if nums and re.fullmatch(r"(-?\d*\.?\d+(px|em)?\s*)+", v):
        out = [float(n) if "." in n else int(n) for n in nums]
        return out[0] if len(out) == 1 else out
    return v


def style_rules(path):
    html = path.read_text()
    css = "\n".join(re.findall(r"<style>(.*?)</style>", html, re.S))
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    rules = {}
    for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
        decls = {}
        for d in body.split(";"):
            if ":" in d:
                k, v = d.split(":", 1)
                decls[k.strip()] = v.strip()
        for s in sel.split(","):
            s = " ".join(s.split())
            if not PAGE_ONLY.match(s):
                rules.setdefault(s, {}).update(decls)
    return html, rules


def resolve(src, files):
    if isinstance(src, tuple):
        spec, value = src
        f, _, sub = spec.split("|", 2)
        if sub not in files[f][0]:
            raise ValueError(f"inline source not in mockup: {spec}")
        norm = HEX.sub(lambda m: norm_color(m.group()), sub).lower()
        vals = value if isinstance(value, list) else [value]
        for x in vals:
            if str(x).lower() not in norm:
                raise ValueError(f"value {x} not in inline source: {spec}")
        return value
    f, sel, prop = src.split("|")
    prop, _, pick = prop.partition("@")
    raw = files[f][1].get(sel, {}).get(prop)
    if raw is None:
        raise ValueError(f"missing in mockup CSS: {src}")
    if pick == "color":
        return norm_color(HEX.search(raw).group())
    if pick:
        n = NUM.findall(HEX.sub("", raw))[int(pick)]
        return float(n) if "." in n else int(n)
    return parse_value(raw)


def build():
    files = {k: style_rules(p) for k, p in FILES.items()}
    tokens, errors = {}, []
    for name, srcs in SEMANTIC.items():
        vals = []
        for s in srcs:
            try:
                v = resolve(s, files)
            except (ValueError, AttributeError, IndexError) as e:
                errors.append(f"{name}: {e}")
                continue
            vals.append((s, v))
        if not vals:
            continue
        if any(v != vals[0][1] for _, v in vals):
            errors.append(f"{name}: sources disagree: {vals}")
        tokens[name] = {"value": vals[0][1], "src": [s if isinstance(s, str) else s[0] for s, _ in vals]}
    tokens["font.mono.family"] = {"value": "Berkeley Mono Variable", "src": ["decision: installed terminal font, overrides --mono"]}
    tokens["font.mono.fallback"] = {"value": ["SF Mono", "Menlo"], "src": ["decision"]}
    css = {k: {s: {p: parse_value(v) for p, v in d.items()} for s, d in sorted(r.items())} for k, (_, r) in files.items()}
    return {"_": "generated by design/tools/tokens.py from the mockup <style> blocks; do not edit by hand",
            "sources": {k: f"haunt-reference/mockups/{p.parent.name}/{p.name}" for k, p in FILES.items()},
            "tokens": dict(sorted(tokens.items())), "css": css}, errors


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    data, errors = build()
    text = json.dumps(data, indent=1, ensure_ascii=False) + "\n"
    if errors:
        print("token sources broken:\n  " + "\n  ".join(errors))
        sys.exit(1)
    if mode == "--write":
        OUT.write_text(text)
        print(f"wrote {OUT} ({len(data['tokens'])} tokens)")
        return
    if not OUT.exists() or OUT.read_text() != text:
        import difflib
        old = OUT.read_text().splitlines() if OUT.exists() else []
        diff = list(difflib.unified_diff(old, text.splitlines(), "tokens.json", "from mockups", lineterm="", n=1))
        print("tokens.json has drifted from the mockup CSS:\n" + "\n".join(diff[:80]))
        sys.exit(1)
    print(f"tokens.json matches the mockups ({len(data['tokens'])} tokens)")


if __name__ == "__main__":
    main()
