# Haunt

A native macOS terminal for running many coding agents side by side: Claude Code, Codex and more. Every piece of agent state on screen comes from the agents' own hook events, never from scraping terminal output.

![Haunt](docs/img/haunt.png)

Haunt is a set of repos:

- **haunt** (this repo): the app (Swift/AppKit on libghostty), the shared Rust core and the `haunt` CLI.
- **Agent adapters:** [haunt-claude](../haunt-plugins/haunt-claude) and [haunt-codex](../haunt-plugins/haunt-codex) turn each agent's hooks into one agent-neutral event stream.
- **Plugins**, each sandboxed in its own repo:
  - [haunt-decision-log](../haunt-plugins/haunt-decision-log): a searchable log of every permission decision;
  - [haunt-allowlist](../haunt-plugins/haunt-allowlist): suggests an allow rule after repeated approvals;
  - [haunt-tabs-plus](../haunt-plugins/haunt-tabs-plus): tab groups, pins and colours;
  - [haunt-commands](../haunt-plugins/haunt-commands): your own ⌘K commands that type into a tab;
  - [haunt-plugin-template](../haunt-plugins/haunt-plugin-template): what `haunt plugin new` scaffolds from.

## What it does

- **Live agent sidebar:** every tab is a real terminal. Agents are grouped into Needs you, Running and Idle, with task progress, one row per subagent, and the exact pending prompt ("Approve: git push?").
- **Approve from anywhere:** a notification's Allow/Deny answers exactly the request it was shown for. Allow only appears when the whole command fits on the banner, measured in the real font; anything longer gets Open only.
- **Review changes (⌘⇧R):** an agent's diff, the checks it ran, and an inbox of tabs with changes. Comments go back to the agent as a prompt.
- **⌘K palette:** tabs, actions, plugin commands and modes. **Agents view (⌘⇧A):** the window shrinks to a narrow strip of agent rows.
- **Plugins:** WASM components (wasmtime). Each capability is shown and approved at install and pinned in a lockfile. Nothing is installed by default.
- **Themes (in progress):** black and white with Claude orange by default. Optional theme plugins carry colours, fonts and window effects, and run no code.

## What's different

Haunt treats agent and terminal output as untrusted:

- Each tab gets a random nonce in its environment. Events without it only update status; they can never create a permission request.
- Every answer from Haunt (a click, a notification, a plugin) goes through one gate. It refuses if the request is stale or replaced, if another prompt is on screen, if you typed at the terminal, or if the command hides characters.
- A plugin can type only from a command you ran, only into the visible tab, never while a prompt is open, with no control characters, and rate-limited.
- Every paste is checked: escapes and hidden characters are spelled out before anything reaches the shell.
- The review screen runs git with filters, diff drivers, hooks and submodule configs disabled, so a hostile repo can't run code when you look at its diff.

> Status: tabs, sidebar, notifications, review, ⌘K, plugins and the CLI work today. Themes are being built. macOS 15+ on Apple silicon.

## How it works

```
Claude Code ──hooks──▶ ~/.haunt/sock ──▶ haunt-core (Rust) ──UniFFI──▶ Swift / AppKit UI
                                             │                          └─ libghostty surfaces
                                             └─ WASM plugins (wasmtime)
```

- **Agent adapters** live in their own repos and all follow one agent-neutral event spec. The Claude Code adapter, [haunt-claude](../haunt-plugins/haunt-claude), is a Claude Code plugin. It sends session, task, subagent, tool and permission events as JSON lines to a private Unix socket.
  - Each tab gets its own surface id and a random nonce in its environment.
  - Events without the right nonce only update status. They can never create a permission request.
- **`core/`** holds the agent model, sidebar layout, decision log, allowlist suggestions and plugin host. It has no UI code, so future Windows and Linux front ends can share it.
- **`macos/`** is the native app: title bar, sidebar, tabs and libghostty surfaces.
- **`wit/`** defines the plugin API (`haunt:plugin@0.4`).
  - Plugins are sandboxed WASM components. Each capability is granted when you install the plugin and pinned in a lockfile.
  - A plugin gets no filesystem, network or environment it wasn't granted.

Design tokens live in `design/tokens.json`. `design/check` compares the running app against the reference mockups pixel by pixel.

## Build

Requires Xcode 16.3+ and Rust (pinned in `rust-toolchain.toml`). libghostty is prebuilt in `macos/deps/`. Only `scripts/update-ghostty.sh` needs Zig, when bumping Ghostty.

```sh
macos/make-app.sh     # builds core, bindings and build/haunt.app
macos/make-app.sh --plugins tabs-plus,allowlist   # also bundles those plugins (or all)
open build/haunt.app
```

`make-app.sh` needs the Claude adapter checked out (see below). It also bundles the Codex adapter if `../haunt-plugins/haunt-codex` is there (or `HAUNT_CODEX_ADAPTER`), the `haunt` CLI as `haunt.app/Contents/Helpers/haunt`, and the first-party plugins you name with `--plugins` (or `HAUNT_PLUGINS`): a name is one `macos/plugins.lock` pins, the repo `../haunt-plugins/haunt-<name>` (`HAUNT_PLUGINS_DIR`), today `allowlist`, `commands`, `decision-log`, `tabs-plus`, `theme-glass` or `theme-sigil`, and `all` is every one it pins. The default is none, and an unknown name fails the build. Code plugins are built for `wasm32-wasip2`; a data-only theme plugin is copied as its manifest and the files it names. `HAUNT_FIRST_PARTY_PLUGINS` adds repos by path (each built once, and only with a real id). Every repo is checked before any is built. A bundled plugin is only offered: nothing is installed until you choose it in `haunt setup`.

Signing: set `HAUNT_SIGN_ID`, or put your identity in a `.sign-id` file (gitignored). Without either, the app is signed ad hoc.

`macos/release.sh` builds a release locally from a clean checkout: `make-app.sh --plugins all`, a check that the app is signed as configured (the same identity on the app and the CLI, hardened runtime, the wasmtime entitlement, arm64 only), `build/haunt-<version>-arm64.zip` made with `ditto` and its `.sha256`, and `build/RELEASE_NOTES.md` from `macos/release-notes.md`. It publishes nothing.

## Set up

```sh
haunt setup                  # asks: Claude Code, Codex, both, or just the terminal
haunt setup claude|codex     # set up one
haunt setup --remove codex   # take one out
haunt setup --plugins tabs-plus,allowlist   # install bundled plugins (none to skip)
haunt setup --remove-plugins tabs-plus      # remove one; its saved data is kept
```

Each run first prints the exact change and asks before making it: the `claude plugin` commands for Claude Code, a diff of `~/.codex/config.toml` for Codex. `--dry-run` changes no agent config (it only stages the adapter copy below); `--yes` skips the question. The choice is kept in `~/.haunt/state.json` (`$HAUNT_CONFIG_DIR`, else `$HAUNT_HOME`, when set). `--dry-run` ends with `preview sha256 <hex>`; `--expect <hex>` applies only if the change still matches that preview. Plugins work the same way: a name is the plugin's id without `dev.haunt.` and must be one the app bundles, the plan lists what each plugin can do, and `--dry-run`, `--yes` and `--expect` apply to it too. Plain `haunt setup` asks about plugins after the agents, only if the app bundles any; `--list-plugins` prints them as JSON, with where any installed copy came from. On first launch the app asks the same questions in a sheet (the plugins unchecked) and runs the same command; change them later in Settings (⌘,).

The adapter is first copied to `~/.haunt/adapters/<agent>/<content hash>` and installed from there, so moving or rebuilding haunt.app doesn't break it. Removing an agent deletes that copy. Run Haunt from `/Applications`: setup refuses a quarantined, translocated copy of the app.

For Claude Code it runs:

```sh
claude plugin marketplace add ~/.haunt/adapters/claude/<hash>
claude plugin install haunt@haunt
```

For Codex it runs the adapter's own `install.sh`, which adds a marked block of hooks to `$CODEX_HOME/config.toml` and backs the file up first; then trust the hooks with `/hooks` in Codex. See [haunt-codex](../haunt-plugins/haunt-codex).

The Claude adapter is the haunt-claude repo, cloned next to this one as `../haunt-plugins/haunt-claude`. `make-app.sh` also bundles a copy into `haunt.app/Contents/Resources/adapters/claude` (and haunt-codex into `adapters/codex`): the commit `macos/adapters.lock` pins, taken with `git archive`. It refuses a checkout with uncommitted changes or at another commit; bump the pin after pushing the adapter, or set `HAUNT_ADAPTER_UNPINNED=1` to bundle the working tree while iterating. Set `HAUNT_CLAUDE_ADAPTER` to use a checkout somewhere else. First-party plugins (`--plugins`) are pinned the same way, in `macos/plugins.lock`: each is built from `git archive` of its pinned commit, never the working tree, and make-app refuses one whose manifest `api` isn't the one this haunt supports before it builds anything. The pinned sources are unpacked under `target/plugin-src` and built with this repo's toolchain; a source with a `.cargo` folder, or a `.cargo` or `rust-toolchain` file between it and the checkout, is refused. Bump a pin after pushing the plugin, or set `HAUNT_PLUGINS_UNPINNED=1` to build the working trees. Or try it without installing: `claude --plugin-dir ../haunt-plugins/haunt-claude`. Needs `jq` 1.6+ and `nc`, both on macOS by default.

Optional: `shell/install.sh` installs a matching Claude Code theme and prints the zsh lines for a minimal prompt inside Haunt. It never edits your `~/.zshrc`.

## Configure

`~/.haunt/config.toml` is reloaded live:

```toml
font = "Berkeley Mono Variable"
font_size = 11

[layout]
agents_view = "narrow-list"                           # the default, and the only view so far
titlebar_buttons = ["search", "new_tab", "sidebar"]   # the default
palette_position = "center-top"                       # or "bottom-right"
palette_rows = "two-line"                             # or "single-line": the sub beside the title
title_format = ""                                     # e.g. "{tab} — {meta}"; empty shows no title
row_labels = ["checklist", "ci"]                      # whose row label wins; none by default

[notifications]      # all on by default
enabled = true       # every agent notification
on_permission = true # an agent needs you: Allow / Deny / Open tab
on_done = true       # an agent finished its turn
menu_bar = true      # the menu bar item

[ghostty]            # passed through to libghostty, less the keys below
cursor-style = "bar"
```

`agents_view` is the view ⌘⇧A shows. `titlebar_buttons` lists the title bar's icons, left to right, from `search`, `new_tab`, `settings` and `sidebar`. Unknown names are skipped and logged; `[]` leaves the bar empty. Each icon's tooltip shows its shortcut from `[keys]`. `palette_position` puts ⌘K at the top centre or in the bottom-right corner, `palette_width` (240–600) sets its width, and `palette_rows` lays out its rows. `title_format` centres a title in the title bar: `{tab}` is the selected tab's name and `{meta}` the first part of its meta line. A theme's `[layout]` can set these too, and yours win. `row_labels` orders plugins whose decorations want the same row: the first listed one that has one shows, plugins not listed come after in install order, and the rest show in the row's tooltip. Name a plugin by its id, the id's last part (`checklist-meter`) or that part's first word (`checklist`).

`[keys]` sets shortcuts by action name (the generated `config.toml` lists them with their defaults). A plugin's palette command is named `"<plugin id>/<item id>"`, for example `"dev.haunt.tabs-plus/move-up" = "alt+cmd+up"`; a plugin's default key must include cmd and never takes one of Haunt's or a chord the terminal or macOS uses (a chord set here has no such limit), and bound plugin commands appear in the Window menu.

`[notifications]` turns agent notifications and the menu bar item on and off. Turning one off takes back what it already posted. Notifications never come for the tab you are looking at.

`[ghostty]` is passed through to libghostty, except for what would get a paste past Haunt's paste check or slip in config Haunt never sees. These are dropped and logged: `right-click-action = paste` or `copy-or-paste`, `middle-click-action` other than `ignore` (Haunt pastes on middle click itself; `ignore` turns that off), any `keybind` to `paste_from_clipboard` or `paste_from_selection`, `config-file`, `config-default-files`, and any key or value with a line break. Haunt also always unbinds Ghostty's ⌘V, ⇧⌘V and Paste key, so every paste goes through its own Edit menu.

## Use

- **Tabs:** ⌘T new, ⌘W close, ⌘1–⌘9 select, ⇧⌘] and ⇧⌘[ next and previous. **Rename Tab** is in the Window menu (no default key; set `rename_tab` in `[keys]`), on a row's right-click menu, or a double-click on its name. An empty name goes back to the automatic one.
- **Agents view:** ⌘⇧A shrinks the window to a narrow strip of agent rows docked to the right of the screen, with shell tabs counted at the foot. Click a row to get the full window back on that tab, or press ⌘⇧A again. It is remembered across launches.
- **Notifications:** an agent waiting on you, or done with its turn, posts a macOS notification unless its tab is the one in front.
  - **Allow** and **Deny** appear only for a short request the core can answer, one whose whole command fits on one line of the banner, so none of it can be hidden. They need the Mac unlocked. Anything longer, multi-line or unusual gets only **Open tab**, and you answer it in the terminal.
  - The answer goes through the core and only reaches the request it was shown for: if the prompt changed or you already answered in the terminal, the click does nothing.
  - The menu bar item shows how many agents are waiting, lists them by state (click one to open its tab), and has **Pause all notifications**. Pausing lasts until you resume or quit; it isn't saved.
- **Paste:** ⌘V pastes the clipboard and ⇧⌘V (Edit ▸ Paste Selection, `paste_selection`) the selection. Haunt shows a paste that carries an escape, another control or a hidden character in full, characters spelled out, and asks first; Ghostty's own paste protection asks before a multi-line one that isn't bracketed. A middle click pastes the selection too, except in an app that takes the mouse (vim or tmux with mouse mode on), where the click goes to the app; there shift+middle click doesn't paste either. `[ghostty] middle-click-action = ignore` turns middle-click paste off.
- **Review changes:** ⌘⇧R (View ▸ Review Changes, or the ⌘K palette) shows what the selected agent changed in its repository: files and diffs, the checks it ran, comments you can send back to it as a prompt, and an inbox of tabs with changes to review. It only reads; approving has no git side effects. See `docs/review.md`.

## CLI

The CLI is bundled in the app. To put it on your PATH:

```sh
ln -s /Applications/haunt.app/Contents/Helpers/haunt /usr/local/bin/haunt   # or any folder on PATH, e.g. ~/.local/bin
```

```sh
haunt dump                       # sidebar state as JSON
haunt decisions [query]          # permission decision log
haunt plugin install ./my-plugin # shows the capabilities, asks before installing
haunt plugin list | remove <id> | approve <id>
haunt setup [claude|codex|none] [--remove] [--plugins <names|all|none>] [--remove-plugins <names>] [--yes] [--dry-run] [--expect <sha256>]
```

## Plugins

A plugin's settings go in config.toml under its id, for example `[plugins."dev.haunt.tabs-plus"]` with `pins = false`. Only the settings its README lists are accepted, with the same type as their default; anything else is skipped and logged. A change applies when you save.

Each plugin lives in its own repo. `haunt plugin new my-plugin [--dir <path>] [--id <reverse-dns id>]` scaffolds one from the built-in template (a minimal plugin that adds a ⌘K palette item, with the WIT this haunt implements) and runs `git init`. Build it with `cargo build --release --target wasm32-wasip2`, then run `haunt plugin install .`. The scaffold's README lists the capabilities and how to update the WIT pin. See `docs/core-api.md` for the host API and limits: 50 ms CPU per call, 64 MB memory, 10 MB storage.

## Tests

```sh
cargo test --workspace                   # the adapter e2e tests skip if an adapter or jq is missing
HAUNT_REQUIRE_ADAPTERS=1 cargo test --workspace   # ...and fail instead
cargo check -p haunt-cli --no-default-features    # the slim CLI, without plugins or wasmtime
../haunt-plugins/haunt-claude/tests/run.sh
../haunt-plugins/haunt-codex/tests/run.sh
macos/tests/keys.sh      # [keys], [layout], the generated Ghostty config and its refusals
macos/tests/paste.sh     # the paste preview and what needs confirming
macos/tests/review.sh    # the review screen's git runner, diff parser, checks and send-back
macos/tests/sidebar.sh   # sidebar drop targets, the agents view's restored frame
macos/tests/theme.sh     # theme files: lookup, extends, validation, the user over the theme
macos/tests/themepicker.sh   # the theme pickers (⌘K and the Themes window): preview, keep, revert
macos/tests/loginpath.sh # the login-shell PATH lookup
macos/tests/bundle-plugins.sh # make-app's --plugins: none by default, exactly the names given, pinned, api checked
macos/tests/notify.sh    # notifications: when Allow shows, answer routing, toggles, the menu bar menu
macos/tests/answerkey.sh # answers go as keystrokes, and only the fixed Allow/Deny keys do
macos/tests/palette.sh   # the palette keeps its selection on a refresh, not on new text
macos/fidelity.sh        # pixel check against the mockups (HAUNT_INACTIVE=1 for the unfocused window)
```

## Licence

MIT. Haunt embeds libghostty from [Ghostty](https://github.com/ghostty-org/ghostty) (MIT); see `NOTICE`.
