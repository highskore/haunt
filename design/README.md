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
`th-01-glass` is the Glass card from `haunt-themes`, 900×560 pt, checked on its solid colours and edges only: its
`hex` anchors give the card's colour, as theme colours aren't tokens. Its render also writes
`reference/th-01-glass-backdrop.png`, the card's wallpaper as the glass shows it, which `macos/fidelity.sh` hands the
fixture (HAUNT_BACKDROP) in place of the desktop.
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
- Anchors pass at ΔE76 ≤ 0.5 against the token colour for surfaces, hairlines and greys. Text and the Claude orange pass at ≤ 1.0, because text is read from the inkiest pixel in the glyph box. Override per anchor with `tol` in `screens.json`.
- Edges pass at ±2 px, which is ±1 pt at 2x.
- **haunt should render in sRGB**, because the tokens are sRGB hex values. Captures tagged with another profile, such as Display P3, are converted to sRGB with a loud warning. Untagged captures are assumed to be sRGB.
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
  - Near-identical greys must fail on the element that changed: `#0e0e0e` → `#0b0b0b` on `sidebar.bg`, `#1a1a1a` → `#1c1c1c` (and `#202020`) on `row.sel.bg`, and `#6b6b6b` → `#6f6f6f` on `label.text`.
  - A Display P3-tagged copy of a reference must convert back and pass.
  - A one-step grey change in a copy of the mockup CSS must fail the token check.
