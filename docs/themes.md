# Themes (design note)

Status: proposal. Nothing here is built yet.

Haunt is black and white. A theme is an optional set of token overrides, picked in `config.toml` and reloaded live. With no `theme` set, Haunt looks exactly as it does today.

## Picking a theme

```toml
theme = "aero"        # top level of ~/.haunt/config.toml; leave it out for the default
```

- **Default:** with no `theme` key, or `theme = "bw"`, you get the built-in tokens: `design/tokens.json` plus `Tok.App`.
- **Where Haunt looks:** first `~/.haunt/themes/<name>.toml`, then the themes bundled in `haunt.app/Contents/Resources/themes/`. A theme in your folder takes precedence over a bundled one with the same name.
- **Allowed names:** `[a-z0-9-]+`. A name is never treated as a path, so `theme = "../x"` is refused and logged.
- **When it fails:** an unknown, unreadable or invalid theme is logged and Haunt falls back to the default.

## A theme file

A theme only lists the tokens it changes. Keys are the token names from `design/tokens.json` without their `color.`, `size.` or `font.` prefix. The `[app]` table covers `Tok.App` (Haunt's own measures, which no mockup has).

```toml
name = "Frutiger Aero"
extends = "bw"            # optional: another theme's name, applied first
appearance = "light"      # macOS look for menus, sheets and alerts: "dark" (default) or "light"

[color]
window.bg = "#e9f4fb"
sidebar.bg = "#d6ecf7"
row.selected = "#bfe0f2"
hairline = "#a9cfe3"
text.primary = "#10324a"
text.sub = "#3d6a86"
palette.bg = "#f4fbff"

[size]
sidebar.w = 248
palette.radius = 12
row.pad = [6, 12]

[font]
ui = "Avenir Next"
mono.family = "SF Mono"

[app]
hairline = 1
```

- **Value types:**
  - A colour is `#rrggbb` or `#rrggbbaa`.
  - A size is a number. An array needs as many numbers as the default has, as in `row.pad` above.
  - A font is a family name. If it isn't installed, the token keeps its default. `font.ui` is a CSS stack in `tokens.json` today, and `Draw.ui` draws with the system font. A theme's `ui` would make `Draw.ui` use that family.
- **What gets skipped:** each of these is logged once per save and skipped, and the rest of the theme still applies:
  - an unknown key;
  - a value of the wrong type;
  - a size outside 0–400.
- **`extends`:** applies the parent theme first, then this file. Chains stop at 4 levels, and a cycle is refused.
- **Terminal colours:** follow the theme. Ghostty's `background` and `foreground` already come from `color.window.bg` and `color.text.terminal`. A theme can add a `[ghostty]` table for `palette = …` and `cursor-color`. It passes through the same refusals as `[ghostty]` in `config.toml`, and anything set under `[ghostty]` in `config.toml` wins over the theme.
- **Claude orange:** `color.claude` stays `#D97757` in every theme.

## How it swaps at runtime

1. **Generated code.** `gen_tokens.py` emits a `Theme` struct with one field per token, and `Theme.bw` built from `tokens.json`. `Tok.Color.x`, `Tok.Size.x` and `Tok.Font.x` become `static var`s that read `Theme.current`. The roughly 250 call sites don't change. `Tok.App` moves into the same struct.
2. **Loading.** `Config.reload` reads `theme`, resolves the chain and builds a `Theme` from `Theme.bw` plus the overrides. It returns `themeChanged` next to `ghostty`, `keys` and `layout`.
3. **Live reload.** The watcher also watches the active theme file and the files it extends, with the same `FileStamp` check and re-arming `config.toml` uses. Saving the theme or changing `theme =` takes effect at once.
4. **Applying a theme.** In AppDelegate's `config.watch` handler, on `themeChanged`:
   - set `Theme.current`;
   - flush `Draw`'s font and ellipsis caches and the sidebar's `RowLines` cache;
   - reset the colours held outside `draw` (the pane and scrim layer colours, `window.backgroundColor`, `NSAppearance`);
   - mark every view as needing layout and display;
   - rewrite the Ghostty config (which reloads it, as a `[ghostty]` edit does today).

   That is one relayout per save.
5. **Cost.** With no theme set, `Theme.current` is `Theme.bw`, and reading a token is one load from a struct. Nothing watches a theme file.

Fixture builds always use `bw` (as they ignore the user's `config.toml` today), so `design/check` keeps comparing against the mockups. A bundled theme could add its own reference captures later.

## Not covered by tokens

The themes the user has asked about (glass, sigilcore, Frutiger Aero, Win95, PS1) need more than colours and sizes. Glass needs a material: an `NSVisualEffectView` behind the sidebar and title bar. Win95 needs bevelled borders and PS1 needs pixel fonts. These could come later as an `[effects]` table of named styles (for example `sidebar.material = "sidebar"` and `border.style = "bevel"`), each drawn by Haunt. Themes stay data only, with no code. Fonts must already be installed; Haunt bundles none for themes.

## Open questions

- Should `[layout]` keys be allowed in a theme (for example a theme that hides `titlebar_buttons`)? This note says no: a theme only changes looks.
- Bundled themes: which ones ship first, and do they get fidelity captures?
- Should plugins be able to read the current theme's colours, so their palette rows and decorations match?
