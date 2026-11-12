# Themes

Haunt is black and white. A theme is an optional set of token overrides, picked in `config.toml` and reloaded live. With no `theme` set, Haunt looks exactly as the mockups do. Haunt itself ships only black and white; every other theme is a data-only theme plugin, `haunt-plugins/haunt-theme-<name>` (see `docs/core-api.md`).

## Picking a theme

```toml
theme = "glass"       # top level of ~/.haunt/config.toml; leave it out for the default
```

- **Default:** with no `theme` key, or `theme = "bw"`, you get the built-in tokens: `design/tokens.json` plus `Tok.App`.
- **Pickers:** the Themes window and ⌘K ▸ Pick theme… preview a theme live and write `theme = "<id>"` into `config.toml` when you choose one. A symlinked `config.toml` is written through, and stays a symlink.
- **Where Haunt looks**, first match wins:
  1. `~/.haunt/themes/<name>.toml`, your own;
  2. installed theme plugins, by their `[contributes.theme] id`;
  3. `haunt.app/Contents/Resources/themes/<name>.toml`, empty today.

  A file of yours hides a plugin theme with the same name, and that plugin's fonts are not loaded with it.
- **Allowed names:** `[a-z0-9-]+`. A name is never treated as a path, so `theme = "../x"` is refused and logged.
- **When it fails:** an unknown, unreadable or invalid theme, or a file over 256 KB, is logged and Haunt falls back to the default.

## A theme file

A theme only lists the tokens it changes. Keys are the token names from `design/tokens.json` without their `color.`, `size.` or `font.` prefix. The `[app]` table covers `Tok.App` (Haunt's own measures, which no mockup has).

```toml
name = "Frutiger Aero"
extends = "bw"            # optional: another theme's name, applied first
appearance = "light"      # macOS look for menus, sheets and alerts: "dark" (default) or "light"

[color]
window.bg = "#e9f4fb"
sidebar.bg = "#d6ecf7"
text.primary = "#10324a"

[size]
sidebar.w = 248
row.pad = [6, 12]

[font]
ui = "Avenir Next"

[app]
hairline = 1

[layout]
palette_position = "bottom-right"

[effects]
window.radius = 12

[ghostty]
background-opacity = 0.9
```

- **Value types:**
  - A colour is `#rrggbb` or `#rrggbbaa`.
  - A size is a number from 0 to 400. An array needs as many numbers as the default has, as in `row.pad` above.
  - A font is a family name, and must be installed or come with the theme's plugin.
- **What gets skipped:** each of these is logged once per save and skipped, and the rest of the theme still applies: an unknown key; a value of the wrong type; a size out of range; a line break in a value.
- **`extends`:** applies the parent theme first, then this file. Chains stop at 4 levels, and a cycle is refused.
- **`[layout]`:** a theme may set any `[layout]` key from `config.toml` (`palette_position`, `palette_width`, `palette_rows`, `title_format`, `titlebar_buttons`…). Your own `[layout]` keys win.
- **Claude orange:** `color.claude` stays `#D97757` in every theme.

## What a theme can't do

A theme is data. It can change how Haunt looks, never what it runs, types, reads or binds, and it can't hide what Haunt needs you to see.

- **`[ghostty]`:** only appearance keys, from an exact list checked against Ghostty v1.4.0 (`themeKeys` in `Theme.swift`): `palette`, `background`, `foreground`, `bold-color`, `bold-is-bright`, `minimum-contrast`, `background-opacity`, `background-blur` (and `-radius`), `unfocused-split-opacity`/`-fill`, `window-padding-x`/`-y`/`-balance`/`-color`, `font-size`, `font-feature`, `font-thicken` (and `-strength`), `font-synthetic-style`, `font-family`/`-style`/`-variation` with their `-bold`, `-italic` and `-bold-italic` forms, the thirteen `adjust-*` keys, `cursor-color`/`-text`/`-opacity`/`-style`/`-style-blink`/`-invert-fg-bg`, and `selection-foreground`/`-background`/`-invert-fg-bg`. A key must also match `^[a-z0-9-]+$`. Anything else (`command`, `env`, `keybind`, `custom-shader`, `theme`, paths…) is dropped and logged. What's left still passes the same refusals as `[ghostty]` in `config.toml`, and your own `[ghostty]` keys win.
- **Readable text:** `Theme.readable` lists every text and indicator colour with the backgrounds it's drawn over, and every other colour token is in `Theme.decorative` (a test fails on one in neither). Text and indicators must be opaque, except `text.meta`, `text.sub`, `text.label`, `app.title.meta`, `app.sidebar.foot.fg`, `icon.fg` and `palette.mute`, which may be see-through down to 40%. Content needs 3:1 against each of its backgrounds and guides such as line numbers 1.5:1, judged on the blended colour; a see-through background is laid over black (white for a light theme). A colour under its minimum is drawn in whichever of black or white reads best on all its backgrounds, and logged when the theme set it.
- **Terminal colours:** the terminal's text needs 3:1 against its background. A `[ghostty]` palette entry, `selection-background`, `selection-foreground` (against the selection) or `cursor-text` under 1.5:1 is dropped and logged, and so is a `bold-color` under 3:1. Black (0) on a dark background and bright white (15) on a light one are exempt: they are meant to sit close to it. Bright black (8) on dark and white (7) on light are secondary text, such as autosuggestions, and need 1.3:1. The generated Ghostty config always has `minimum-contrast` between 1.1 and 21, so no colour can vanish into the background, unless your own `config.toml` sets `minimum-contrast`.
- **Fonts:** a theme plugin's fonts are used only while its theme is on screen. A plugin bundled in the signed app has its fonts registered for Haunt's process, and they may draw anything, the terminal included. A plugin you installed yourself never has its fonts registered: Haunt reads them from the file and only `font.ui` draws with them, so neither Ghostty nor Core Text's fallback can pick one up. `font.mono.*` and the `[ghostty]` `font-family*` keys can't name such a font, compared case-folded, unquoted and with whitespace collapsed, entry by entry in a CSS stack or list. A font whose family, PostScript or display name matches a font already on the Mac (compared the same way) isn't loaded at all.

## Effects

Some looks need more than colours and sizes. The `[effects]` table switches on elements Haunt draws itself. It is a fixed schema: each key below takes one value of its type, and anything else (an unknown key, a wrong type, a number out of range, a choice not listed) is logged as a problem and skipped. Their colours and measures come from `[color]`, `[size]` and `[app]` tokens, never from the effect.

| Key | Value | Draws |
| --- | --- | --- |
| `window.material` | `"none"`, `"glass"` | the desktop blurred through the window (an `NSVisualEffectView`) |
| `window.radius` | 0–40 | rounded window corners |
| `window.ring` | bool | an inner ring and top highlight (`app.window.ring`, `app.window.highlight`) |
| `titlebar.rule` | bool, default true | the hairline under the title bar |
| `titlebar.lights` | `"grey"`, `"color"` | the traffic lights at rest |
| `sidebar.footer` | bool | the live agent count under the sidebar |
| `label.case`, `label.weight` | `"upper"`, `"sentence"`; `"regular"`, `"medium"`, `"semibold"` | group labels |
| `row.inset`, `row.radius` | 0–40 | rows as rounded boxes inset from the sidebar's edges |
| `needs.pill` | bool | a needs-you row's status in a pill (`app.pill.*`) |
| `bar.radius`, `bar.glow` | 0–10; bool | rounded progress bars, and a glow on the fill (`app.bar.glow`) |
| `bar.done` | bool | a finished task keeps its full bar (default); off, only work in progress has one |
| `palette.material` | `"none"`, `"glass"` | the palette's own material, ring and highlight |
| `palette.blur` | `"hud"`, `"window"`, `"sheet"`, `"menu"`, `"popover"`, `"sidebar"`, `"under-window"`, `"full-screen"` | which macOS blur material a glass palette uses, under its `palette.bg` tint; a glass palette's tint is at least 50% opaque (`#…80`), and a thinner one is raised to it and logged |
| `palette.tab.sub` | `"meta"`, `"task"` | a tab's entry shows its meta line, or only the agent's task (a shell keeps its meta) |
| `palette.font` | `"mono"`, `"ui"` | the palette's text |
| `palette.icons` | bool | the sidebar's icons in place of the shortcut column; shortcuts move right |
| `palette.selection` | `"bar"`, `"pill"`, `"cursor"` | the selected row (`app.palette.pill.*`), or filled with `palette.sel` behind a triangle cursor |
| `palette.foot`, `palette.scrim` | bool, default true | the hints line, and the dimmed window behind the palette |
| `palette.keys` | `"box"`, `"plain"` | shortcuts in a box or as text |
| `palette.modes` | `"styled"`, `"plain"` | a plugin mode's rows (the decision log) styled like the rest, or in the black-and-white layout and mono font with an inverted selection, inside the themed panel |
| `palette.input.icon`, `palette.input.weight` | bool; `"regular"`, `"light"` | a search glyph before the query, and the query's weight |
| `window.square`, `window.border` | bool | square corners instead of the system's, and a 1 pt `color.window.border` inside the edge |
| `titlebar.double` | bool | a second rule (`app.titlebar.rule2`) just above the title bar's |
| `lights.shape` | `"circle"`, `"diamond"`, `"boxes"`, `"squares"` | the traffic lights at rest, diamonds outlined in `app.ornament`, bevelled minimise, maximise and close boxes on the right, or flat squares |
| `label.rule` | `"none"`, `"diamond"`, `"groupbox"`, `"block"` | a group label between a short rule and diamond and a rule fading to the edge, each group in an etched box with its label on the top edge (`app.group.pad`, `app.group.gap`), or the label in `app.label.ink` on a block of `app.label.fill` (`app.label.block.pad`) |
| `row.select` | `"fill"`, `"brackets"`, `"name"`, `"cursor"` | the selected row filled, two corner brackets over a glow from its left edge, only its name highlighted (`app.row.select.fill`, `app.row.select.ink`) with a dotted ring, or the whole row in those colours behind a triangle cursor |
| `icon.ring`, `icon.shell` | bool; `"tile"`, `"diamond"` | rings around the agent icons, and the shell glyph on a tile or in a diamond |
| `progress.style` | `"bar"`, `"dotted"`, `"segments"` | the progress bar solid, a dotted track with a fading fill and a diamond knob (`app.bar.knob`), or blocks (`app.bar.segment`: width, gap) in a sunken track, or in `app.bar.frame` when it has any opacity |
| `needs.glow` | bool | a glow behind the needs-you status |
| `needs.weight` | `"regular"`, `"bold"` | the needs-you status's weight, when it isn't a pill |
| `ornament` | `"none"`, `"sigil"`, `"lcd"` | artwork drawn in code: a sigil at the sidebar's foot (left out when the rows need its room), and, behind the window's content, a sigil at `app.ornament.alpha` (0–0.12) and marks in the window's corners, shown only when the window and Ghostty's background are both see-through; or an LCD grid in `app.ornament` at that alpha over the title bar and sidebar, never over the terminal |
| `palette.inset` | 0–80, default 22 | how far the bottom-right palette stands in from the window's edges |
| `palette.header`, `palette.input.rules` | bool | `[strings] palette.header` above the input, and rules above and below the input |
| `ui.weight` | `"regular"`, `"light"` | the theme's UI face's regular text drawn light |
| `name.font` | `"ui"`, `"display"` | the sidebar's tab names in the UI face or in `app.display.font` |
| `window.frame`, `pane.frame` | `"none"`, `"bevel"` | a raised bevel around the window inside `app.window.pad`, and a sunken one around the terminal, `app.pane.gap` from the sidebar (`app.bevel.*`) |
| `titlebar.style`, `titlebar.icon`, `titlebar.menu` | `"plain"`, `"caption"`; bool; bool | the title bar as a caption filled with `app.titlebar.fill` and titled on the left in `app.row.select.ink`, a ghost before the title, and a row of Haunt's own menus under it that open them |
| `icon.style` | `"vector"`, `"pixel"` | the claude and shell icons as pixel art |
| `palette.frame` | `"panel"`, `"dialog"` | the palette as a raised dialog: a caption with `[strings] palette.header`, `palette.message` beside an information icon, a sunken field (`app.palette.field`) labelled with `palette.input.glyph` in `palette.ink`, a sunken list, OK (the default button, ringed in black with a dotted focus) and Cancel, and a close box in the caption that does what Escape does; the selected row gets a dotted focus ring |

Every effect is off by default, so black and white draws as it did before them.

**Display type.** `[app] display.font` names a face for the title's `{tab}` or `{app}` part, the group labels and the palette header. `[app] text.chrome` lists gradient stops, top to bottom, that fill that text and a pill selection, each optionally at a place (`"#c9c9cf 22%"`, given for every stop and in order, or spread evenly); every stop must be opaque, and every stop and the blend between them (sixteen samples a segment) must read 3:1 on the window, sidebar and palette backgrounds and carry `palette.pill.ink` at 3:1, or the text is drawn flat and the theme logged.

**Rings.** `[app] palette.rings` lists rings drawn around the palette in place of its border, outermost first, each `"#rrggbb width"` with a width up to 8 pt.

**`[strings]`.** A theme may word seven places: `titlebar.right`, `palette.header`, `palette.foot` (replacing the default hints; a mode's hints stay Haunt's), `palette.input.glyph`, `palette.message` (with `palette.frame = "dialog"`), `sidebar.foot` (with `ornament`; it must show `{agents}` or `{agents.roman}`) and `row.sub.prefix` (before a subagent line). Each is one plain line of up to 64 code points, with no control, bidi or invisible characters and at most two combining marks on a character; none may pass for one of Haunt's status words (Needs you, Running, Idle, Waiting for you, Approve, Done, Failed, and Allow or Deny as a word), checked as plugins' row labels are, lookalikes, spacing and accents included, nor read as a permission request or its answer (no word may start with Allow, Deny, Deni, Approv, Permi or Request). Anything else is refused and logged. `{day.roman}`, `{month.roman}` and `{year.roman}` come from the clock, `{agents}` and `{agents.roman}` from the sidebar; the filled-in line is checked again, and Haunt draws its own words in its place if it fails or doesn't fit whole; a theme's words are never cut short. `row.sub.prefix` is checked together with the subagent label beside it, as cut to fit.

## Layers

A theme can draw its own look as data: rules, frames, bevels, gradients, patterns, small images and vector marks, each in a named **slot**. Haunt draws only what the theme lists, clipped to the slot, under the slot's text, and never on the terminal. A layer can't contain text: `[strings]` stay a theme's only words.

```toml
[[layer]]
id = "row-brackets"        # optional; a theme that extends this one replaces the layer with the same id
slot = "row.selected"
when = ["focused"]         # optional: draw only in all of these states
opacity = 1.0              # 0–1

  [[layer.draw]]
  kind = "path"
  d = "M0 6 V0 H6"         # SVG path syntax: M L H V C Q Z, absolute or relative
  view = [6, 6]            # the units `d` is in, scaled to the frame
  x = "left"               # the frame: an anchor and a length on each axis...
  w = 6
  y = "top"
  h = 6
  stroke = "@ornament"     # "#rrggbb", "#rrggbbaa", or "@" and a colour token's name
  repeat = "corners"       # once in each corner, turned to face inward

  [[layer.draw]]
  kind = "rect"
  left = 2                 # ...or insets from the slot's edges (the default: all 0, the whole slot)
  right = 2
  radius = 4
  fill = "#ffffff10"
```

**Slots.** Each is drawn after its own background and before its text.

| Slot | Bounds |
| --- | --- |
| `window.bg` | the window, behind every view, minus the terminal |
| `pane.backdrop` | behind the terminal, at most 12% opaque, only when Ghostty's `background-opacity` is under 1 |
| `pane.frame` | a 4 pt ring around the terminal, never inside it |
| `titlebar`, `sidebar`, `sidebar.footer`, `palette`, `palette.field` | those areas |
| `lights` | around each traffic light, never inside it (a ring may spill 4 pt past it); `index = 0`–`2` picks one |
| `label.group` | a group label's line; its text is a text run |
| `row`, `row.selected`, `row.hover` | a sidebar row's box, clipped to it |
| `palette.row.selected`, `palette.row.hover` | a palette entry, with the same 6 pt |
| `icon`, `bar.track`, `bar.fill` | a row's icon, its progress track and the filled part |
| `status.needs` | a needs-you status; its text is a text run |
| `palette.caption`, `button`, `button.default` | reserved for the dialog palette |

**States** (`when`): `focused`, `inactive`, `selected`, `hover`, `pressed`.

**The frame.** On each axis, either insets (`left`/`right`, `top`/`bottom`, from −400 to 400; negative reaches out, still clipped), or an anchor (`x`: `left`, `center`, `right`, `text.left`, `text.right`; `y`: `top`, `center`, `bottom`) with a length (`w`, `h`) and an offset (`dx`, `dy`). `from_text = true` starts the left inset at the end of the slot's text run, for a rule after a label. Text anchors are only for `label.group` and `status.needs`.

| `kind` | Keys | Draws |
| --- | --- | --- |
| `rect` | `radius`, `fill`, `stroke`, `width`, `dash` | a (rounded) rectangle |
| `line` | `stroke`, `width`, `dash`, `along` | a line along the frame's `top`, `bottom`, `left`, `right`, `hmid` (default) or `vmid` |
| `gradient` | `stops`, `angle`, `radius` | a linear gradient: 2–8 `"#colour"` or `"#colour 40%"` stops (places for all or none, in order); `angle` 0 runs left to right, 90 (default) top to bottom |
| `bevel` | `rings` | one or two 1 pt rings, outermost first, each `[top, left, bottom, right]` colours |
| `pattern` | `cell`, `dots`; or `tile` | a cell up to 16×16 pt with up to 64 1-pt `"#colour x y"` dots, or a PNG tile, repeated over the frame |
| `image` | `file`, `repeat` | a PNG from the theme's folder; `repeat` `"corners"` or `"tile"` |
| `path` | `d`, `view`, `fill`, `stroke`, `width`, `dash`, `repeat` | a vector shape, up to 256 commands; `repeat = "corners"` |
| `shadow` | `color`, `blur`, `offset`, `radius` | a soft shadow around the frame's shape, not the shape itself: `blur` up to 12, `offset` up to ±6 |

`width` is 0.25–8 pt, `dash` 1–4 lengths from 0.5 to 40, `radius` 0–40.

**What Haunt enforces.**
- **Clipping:** every layer is clipped to its slot; no slot reaches into the terminal, and `pane.backdrop` is under it.
- **Readable text:** in a slot with text, Haunt draws the slot's layers offscreen, at the screen's scale and never under 2x, over the slot's real background (the row's fill and tint, a pill under its word) and the layers of the slots drawn under it (the sidebar's and the row's under a needs word), and checks each run of its text, in the colour it is drawn in, against every pixel wholly inside that run's box: all must read at 3:1. If one doesn't, or can't be measured, none of the slot's layers are drawn there, and that is logged once. So stacking, path winding and any kind of shape are judged as painted. A text slot's images and patterns are drawn together, under its other shapes, at most 12% opaque as a group; so is everything in `pane.backdrop`.
- **Caps:** 64 `[[layer]]` tables for the whole `extends` chain (skipped ones count), 16 shapes a layer, 256 shapes in all, 4 shadows and 4 gradients a slot, 8 images a chain, each PNG up to 256 KB and 512×512 px, 4 MB decoded in all. Images are PNG only, with a plain `[a-z0-9-].png` name in the theme's own folder (a theme plugin lists them in `[contributes.theme] images`, docs/core-api.md); no SVG, no animated PNG.
- **Too slow:** if a theme's layers take over 60 ms to check and draw in two window redraws, or over 200 ms in one, Haunt turns them off for the rest of the session and logs `layers off: too slow to draw`. The theme's tokens still apply.
- **No animation, no text.**
- **Bad input:** an unknown slot, kind, state or key, a value out of range or of the wrong type, is logged once per save and skipped: the key, else the shape, else the layer. The rest of the theme still applies.

An image fills its frame; a tiled image or pattern tile is drawn at half its pixel size, as @2x art. Core checks the tables and decodes the PNGs (`core/src/theme_layers.rs`); the app resolves colours and draws (`macos/Sources/Layers.swift`).

## How it works

1. **Tokens.** `gen_tokens.py` emits a `Theme` struct with one field per token from `tokens.json`, plus `AppTokens` (`[app]`) and `Effects`. `Tok.Color.x`, `Tok.Size.x` and `Tok.Font.x` read `Theme.current`.
2. **Loading.** `HauntConfig.reload` reads `theme`, `LoadedTheme.load` resolves the chain and builds a `Theme` from the defaults plus the overrides, and the theme's `[layout]` and `[ghostty]` go under your own.
3. **Live reload.** Haunt watches `config.toml`, the themes folder, and the active theme's files (every candidate path, so creating a missing one reloads too). The watches follow the theme on screen, a preview's included. Saving a theme or changing `theme =` takes effect at once. The pickers' list is kept until the themes folder or the installed plugins change.
4. **Applying.** On a theme change, AppDelegate sets `Theme.current`, flushes the font and row caches, resets the colours held outside `draw`, relays out every view and rewrites the Ghostty config.
5. **Layers.** `LoadedTheme.load` hands the chain's files to core, ancestors first, and resolves what comes back against the finished theme; `Layers.draw` is called at each slot's site.
6. **Plugins** read the theme on screen through the `theme` import's `tokens()` (from `Theme.exported()`), so their rows and decorations can match it.

Fixtures use `bw`, as they ignore your `config.toml`, so `design/check` keeps comparing against the mockups. `HAUNT_THEME=<id>` puts a fixture in another theme, found in the bundled themes or `$TMPDIR/haunt-fixture/themes`.
