# Haunt

A quiet macOS terminal for running many Claude Code agents side by side.

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
- **`wit/`** defines the plugin API (`haunt:plugin@0.1`).
  - Plugins are sandboxed WASM components. Each capability is granted when you install the plugin and pinned in a lockfile.
  - A plugin gets no filesystem, network or environment it wasn't granted.

Design tokens live in `design/tokens.json`. `design/check` compares the running app against the reference mockups pixel by pixel.

## Build

Requires Xcode 16.3+ and Rust (pinned in `rust-toolchain.toml`). libghostty is prebuilt in `macos/deps/`. Only `scripts/update-ghostty.sh` needs Zig, when bumping Ghostty.

```sh
macos/build.sh && macos/make-app.sh     # builds core, bindings and build/haunt.app
open build/haunt.app
```

`make-app.sh` needs the Claude adapter checked out (see below).

Signing: set `HAUNT_SIGN_ID`, or put your identity in a `.sign-id` file (gitignored). Without either, the app is signed ad hoc.

## Set up Claude Code

```sh
claude plugin marketplace add ../haunt-plugins/haunt-claude
claude plugin install haunt@haunt
```

The adapter is the haunt-claude repo, cloned next to this one as `../haunt-plugins/haunt-claude`. `make-app.sh` also bundles a copy into `haunt.app/Contents/Resources/adapters/claude`; set `HAUNT_CLAUDE_ADAPTER` to use a checkout somewhere else. Or try it without installing: `claude --plugin-dir ../haunt-plugins/haunt-claude`. Needs `jq` 1.6+ and `nc`, both on macOS by default.

Optional: `shell/install.sh` installs a matching Claude Code theme and prints the zsh lines for a minimal prompt inside Haunt. It never edits your `~/.zshrc`.

## Configure

`~/.haunt/config.toml` is reloaded live:

```toml
font = "Berkeley Mono Variable"
font_size = 11

[ghostty]            # passed through to libghostty as-is
cursor-style = "bar"
```

## CLI

```sh
haunt dump                       # sidebar state as JSON
haunt decisions [query]          # permission decision log
haunt plugin install ./my-plugin # shows the capabilities, asks before installing
haunt plugin list | remove <id> | approve <id>
```

## Plugins

`examples/hello` is a minimal plugin that adds a ⌘K palette item. Build it with `cargo build --release --target wasm32-wasip2`, then run `haunt plugin install ./examples/hello`. See `docs/core-api.md` for the host API and limits: 50 ms CPU per call, 64 MB memory, 10 MB storage.

## Tests

```sh
cargo test --workspace                   # hook_e2e skips if the adapter isn't checked out
../haunt-plugins/haunt-claude/tests/run.sh
macos/fidelity.sh        # pixel check against the mockups
```

## Licence

MIT. Haunt embeds libghostty from [Ghostty](https://github.com/ghostty-org/ghostty) (MIT); see `NOTICE`.
