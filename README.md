# Haunt

A quiet macOS terminal for running many coding agents side by side: Claude Code, Codex and more.

![Haunt](docs/img/haunt.png)

Every tab is a real terminal (libghostty). The sidebar shows what each agent is doing, built from Claude Code's own hook events, never from guessing at screen output:

- **Grouped by state:** Needs you, Running, Idle.
- **Real progress:** task counts and a progress bar, plus one row per subagent with its tool count and elapsed time.
- **The pending prompt:** "Approve: git push?" shows on the row, so you can see which tab is waiting without opening it.
- **Plain shells:** shell tabs sit alongside agents, showing their folder and shell.

The design is black and white with one accent: the Claude orange.

> Status: early. Phase 1 (tabs, sidebar, live agent state) works. Phase 2 (notifications with Allow/Deny, ⌘K palette, plugins) is in progress. macOS 15+ on Apple silicon.

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
- **`wit/`** defines the plugin API (`haunt:plugin@0.3`).
  - Plugins are sandboxed WASM components. Each capability is granted when you install the plugin and pinned in a lockfile.
  - A plugin gets no filesystem, network or environment it wasn't granted.

Design tokens live in `design/tokens.json`. `design/check` compares the running app against the reference mockups pixel by pixel.

## Build

Requires Xcode 16.3+ and Rust (pinned in `rust-toolchain.toml`). libghostty is prebuilt in `macos/deps/`. Only `scripts/update-ghostty.sh` needs Zig, when bumping Ghostty.

```sh
macos/build.sh && macos/make-app.sh     # builds core, bindings and build/haunt.app
open build/haunt.app
```

`make-app.sh` needs the Claude adapter checked out (see below). It also bundles the Codex adapter if `../haunt-plugins/haunt-codex` is there (or `HAUNT_CODEX_ADAPTER`), the `haunt` CLI as `haunt.app/Contents/Helpers/haunt`, and the first-party decision-log and allowlist plugins from `../haunt-plugins/` (built for `wasm32-wasip2`; Haunt installs them on launch, see `docs/core-api.md`).

Signing: set `HAUNT_SIGN_ID`, or put your identity in a `.sign-id` file (gitignored). Without either, the app is signed ad hoc.

## Set up

```sh
haunt setup                  # asks: Claude Code, Codex, both, or just the terminal
haunt setup claude|codex     # set up one
haunt setup --remove codex   # take one out
```

Each run first prints the exact change and asks before making it: the `claude plugin` commands for Claude Code, a diff of `~/.codex/config.toml` for Codex. `--dry-run` only prints; `--yes` skips the question. The choice is kept in `~/.haunt/state.json`. On first launch the app asks the same question in a sheet and runs the same command; change it later in Settings (⌘,).

For Claude Code it runs:

```sh
claude plugin marketplace add ../haunt-plugins/haunt-claude
claude plugin install haunt@haunt
```

For Codex it runs the adapter's own `install.sh`, which adds a marked block of hooks to `$CODEX_HOME/config.toml` and backs the file up first; then trust the hooks with `/hooks` in Codex. See [haunt-codex](../haunt-plugins/haunt-codex).

The Claude adapter is the haunt-claude repo, cloned next to this one as `../haunt-plugins/haunt-claude`. `make-app.sh` also bundles a copy into `haunt.app/Contents/Resources/adapters/claude`; set `HAUNT_CLAUDE_ADAPTER` to use a checkout somewhere else. Or try it without installing: `claude --plugin-dir ../haunt-plugins/haunt-claude`. Needs `jq` 1.6+ and `nc`, both on macOS by default.

Optional: `shell/install.sh` installs a matching Claude Code theme and prints the zsh lines for a minimal prompt inside Haunt. It never edits your `~/.zshrc`.

## Configure

`~/.haunt/config.toml` is reloaded live:

```toml
font = "Berkeley Mono Variable"
font_size = 11

[layout]
titlebar_buttons = ["search", "new_tab", "sidebar"]   # the default

[ghostty]            # passed through to libghostty as-is
cursor-style = "bar"
```

`titlebar_buttons` lists the title bar's icons, left to right, from `search`, `new_tab`, `settings` and `sidebar`. Unknown names are skipped and logged; `[]` leaves the bar empty. Each icon's tooltip shows its shortcut from `[keys]`.

## CLI

```sh
haunt dump                       # sidebar state as JSON
haunt decisions [query]          # permission decision log
haunt plugin install ./my-plugin # shows the capabilities, asks before installing
haunt plugin list | remove <id> | approve <id>
haunt setup [claude|codex|none] [--remove] [--yes] [--dry-run]
```

## Plugins

Each plugin lives in its own repo. `haunt plugin new my-plugin [--dir <path>] [--id <reverse-dns id>]` scaffolds one from the built-in template (a minimal plugin that adds a ⌘K palette item, with the WIT this haunt implements) and runs `git init`. Build it with `cargo build --release --target wasm32-wasip2`, then run `haunt plugin install .`. The scaffold's README lists the capabilities and how to update the WIT pin. See `docs/core-api.md` for the host API and limits: 50 ms CPU per call, 64 MB memory, 10 MB storage.

## Tests

```sh
cargo test --workspace                   # hook_e2e skips if the adapter isn't checked out
../haunt-plugins/haunt-claude/tests/run.sh
macos/fidelity.sh        # pixel check against the mockups
```

## Licence

MIT. Haunt embeds libghostty from [Ghostty](https://github.com/ghostty-org/ghostty) (MIT); see `NOTICE`.
