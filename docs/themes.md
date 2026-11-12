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
| `row.raised` | bool | the selected row lifted: shadow, ring and highlight (`app.row.raised.*`) |
| `row.hover` | bool | a faint fill (`app.row.hover`) on the sidebar or palette row under the pointer, shaped like the selection |
| `needs.pill` | bool | a needs-you row's status in a pill (`app.pill.*`) |
| `bar.radius`, `bar.glow` | 0–10; bool | rounded progress bars, and a glow on the fill (`app.bar.glow`) |
| `bar.done` | bool | a finished task keeps its full bar (default); off, only work in progress has one |
| `palette.material` | `"none"`, `"glass"` | the palette's own material, ring and highlight |
| `palette.blur` | `"hud"`, `"window"`, `"sheet"`, `"menu"`, `"popover"`, `"sidebar"`, `"under-window"`, `"full-screen"` | which macOS blur material a glass palette uses, under its `palette.bg` tint; a glass palette's tint is at least 50% opaque (`#…80`), and a thinner one is raised to it and logged |
| `palette.tab.sub` | `"meta"`, `"task"` | a tab's entry shows its meta line, or only the agent's task (a shell keeps its meta) |
| `palette.font` | `"mono"`, `"ui"` | the palette's text |
| `palette.icons` | bool | the sidebar's icons in place of the shortcut column; shortcuts move right |
| `palette.selection` | `"bar"`, `"pill"` | the selected row (`app.palette.pill.*`) |
| `palette.foot`, `palette.scrim` | bool, default true | the hints line, and the dimmed window behind the palette |
| `palette.keys` | `"box"`, `"plain"` | shortcuts in a box or as text |
| `palette.modes` | `"styled"`, `"plain"` | a plugin mode's rows (the decision log) styled like the rest, or in the black-and-white layout and mono font with an inverted selection, inside the themed panel |
| `palette.input.icon`, `palette.input.weight` | bool; `"regular"`, `"light"` | a search glyph before the query, and the query's weight |
| `window.square`, `window.border` | bool | square corners instead of the system's, and a 1 pt `color.window.border` inside the edge |
| `titlebar.double` | bool | a second rule (`app.titlebar.rule2`) just above the title bar's |
| `lights.shape` | `"circle"`, `"diamond"` | the traffic lights at rest, diamonds outlined in `app.ornament` |
| `label.rule` | `"none"`, `"diamond"` | a group label between a short rule and diamond and a rule fading to the edge |
| `row.select` | `"fill"`, `"brackets"` | the selected row filled, or two corner brackets over a glow from its left edge |
| `icon.ring`, `icon.shell` | bool; `"tile"`, `"diamond"` | rings around the agent icons, and the shell glyph on a tile or in a diamond |
| `progress.style` | `"bar"`, `"dotted"` | the progress bar solid, or a dotted track with a fading fill and a diamond knob (`app.bar.knob`) |
| `needs.glow` | bool | a glow behind the needs-you status |
| `ornament` | `"none"`, `"sigil"` | artwork drawn in code: a sigil at the sidebar's foot (left out when the rows need its room), marks in the window's corners, and a sigil behind the terminal at `app.ornament.alpha` (0–0.12) when the window and Ghostty's background are both see-through |
| `palette.inset` | 0–80, default 22 | how far the bottom-right palette stands in from the window's edges |
| `palette.header`, `palette.input.rules` | bool | `[strings] palette.header` above the input, and rules above and below the input |

Every effect is off by default, so black and white draws as it did before them.

**Display type.** `[app] display.font` names a face for the title's `{tab}` or `{app}` part, the group labels and the palette header. `[app] text.chrome` lists gradient stops, top to bottom, that fill that text and a pill selection; every stop must be opaque, read 3:1 on the window, sidebar and palette backgrounds, and carry `palette.pill.ink` at 3:1, or the text is drawn flat and the theme logged.

**`[strings]`.** A theme may word seven places: `titlebar.right`, `palette.header`, `palette.foot` (replacing the default hints; a mode's hints stay Haunt's), `palette.input.glyph`, `palette.message` (with `palette.frame = "dialog"`), `sidebar.foot` (with `ornament`; it must show `{agents}` or `{agents.roman}`) and `row.sub.prefix` (before a subagent line). Each is one plain line of up to 64 code points, with no control, bidi or invisible characters and at most two combining marks on a character; none may use Haunt's status words (needs you, allow, deny, approved, permission, request, waiting, done). Anything else is refused and logged. `{day.roman}`, `{month.roman}` and `{year.roman}` come from the clock, `{agents}` and `{agents.roman}` from the sidebar.

## How it works

1. **Tokens.** `gen_tokens.py` emits a `Theme` struct with one field per token from `tokens.json`, plus `AppTokens` (`[app]`) and `Effects`. `Tok.Color.x`, `Tok.Size.x` and `Tok.Font.x` read `Theme.current`.
2. **Loading.** `HauntConfig.reload` reads `theme`, `LoadedTheme.load` resolves the chain and builds a `Theme` from the defaults plus the overrides, and the theme's `[layout]` and `[ghostty]` go under your own.
3. **Live reload.** Haunt watches `config.toml`, the themes folder, and the active theme's files (every candidate path, so creating a missing one reloads too). The watches follow the theme on screen, a preview's included. Saving a theme or changing `theme =` takes effect at once. The pickers' list is kept until the themes folder or the installed plugins change.
4. **Applying.** On a theme change, AppDelegate sets `Theme.current`, flushes the font and row caches, resets the colours held outside `draw`, relays out every view and rewrites the Ghostty config.
5. **Plugins** read the theme on screen through the `theme` import's `tokens()` (from `Theme.exported()`), so their rows and decorations can match it.

Fixtures use `bw`, as they ignore your `config.toml`, so `design/check` keeps comparing against the mockups. `HAUNT_THEME=<id>` puts a fixture in another theme, found in the bundled themes or `$TMPDIR/haunt-fixture/themes`.
