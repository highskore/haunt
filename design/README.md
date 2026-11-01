# design: fidelity kit

"Matches the mockup" is a tool check here, not a judgement call. The mockups live in
`~/code/haunt-reference/mockups/` (`pawr-ui`, `pawr-agents-view`); override with `HAUNT_MOCKUPS=<dir>`.
Everything runs through `uv`, so you don't need a venv.

| file | what it is |
|---|---|
| `tokens.json` | every colour, size, padding, radius and font the picked screens use. It's generated from the mockup `<style>` blocks, so don't edit it by hand |
| `screens.json` | per-screen anchor specs: which element, where to sample, and which token it should show |
| `reference/<screen>.png` | the mockup window rendered at 2x by headless Chrome and cropped to the window's content box |
| `reference/manifest.json` | the anchor points (px at 2x) with their expected colours, the edge probes with their expected coordinates, and the window size |
| `out/` | check output (heatmaps and reports). It's gitignored |

## Screens

`ui-03-icon-only`, `ui-06-grouped-flat`, `ui-07-rail`, `ui-08-breadcrumb`, `ui-10-zen`
(pawr-ui layouts), and `av-01-narrow-list` to `av-09-focus` (agents-only views 01–09).
`.win` screens are 900×440 pt. Floating panels use their own size (see `size_pt` in the manifest),
and the ticker is 1440×29 pt.

## Checking the app

```sh
id=$(design/winid haunt)                       # frontmost haunt window; --all lists them
screencapture -x -o -l "$id" /tmp/shot.png     # window only, no shadow. Never full screen
design/check /tmp/shot.png ui-06-grouped-flat  # exit 0 = pass
```

- Size the window to the screen's `size_pt` first, and load the mockup's `TABS` data so the rows line up.
- Pass `--offset DX,DY` if the capture has extra pixels at its top-left, such as a window frame.
- Anchors pass at ΔE76 ≤ 2 against the token colour. Text anchors use the inkiest pixel in the glyph box.
- Edges pass at ±2 px, which is ±1 pt at 2x.
- Captures that carry an ICC profile are converted to sRGB first. Untagged captures are assumed to be sRGB.
- Output goes to `out/<screen>-diff.png`, which shows the diff in red with markers (green passes, red fails and is named), and to `out/<screen>-report.json`.

## Changing things

- **The mockup changed:** run `design/tokens --write` and then `design/render`, and commit both.
- **Drift check:** `design/tokens` (CI-friendly) fails if `tokens.json` no longer matches the mockup CSS.
- **New anchor or screen:** add it to `screens.json` and run `design/render [screen]`. Rendering fails if
  an anchor doesn't land on its token's colour, or if an edge probe disagrees with the DOM geometry.
  That stops a misplaced probe from becoming the "truth".
- **Self-test:** `design/selftest`.
  - Every reference must pass its own check.
  - Every screen must fail when brightened +6 or shifted down 2 pt.
  - A sidebar made 2 pt wider must fail on `sidebar.right`.
  - A recoloured selected row must fail on `row.sel.bg`.
  - A one-step grey change in a copy of the mockup CSS must fail the token check.

ΔE ≤ 2 can't tell some of these greys apart. For example, `#0b0b0b` vs `#0e0e0e` is ΔE 0.9, and `#6b6b6b`
vs `#6f6f6f` is 1.6. To catch those, tighten `tol` on the anchors where it matters.
