# {{name}}

{{description}}

A Haunt plugin: a sandboxed WebAssembly component that adds a "Say hello" command to the ⌘K palette and badges new tasks and tool calls.

Start a new plugin with `haunt plugin new <name> [--dir <path>] [--id <reverse-dns id>]`: it copies this template, fills in the id, name and description, and runs `git init`. If you copy the template by hand, replace the double-brace placeholders in `haunt-plugin.toml`, `Cargo.toml` and this README yourself; `haunt plugin install` refuses the placeholder id.

## Build

```sh
cargo build --release --target wasm32-wasip2   # or ./build.sh
cargo test                                     # native unit tests
```

`rust-toolchain.toml` adds the `wasm32-wasip2` target. The component ends up at `target/wasm32-wasip2/release/haunt_plugin.wasm`, which is the `entry` in `haunt-plugin.toml`. The crate is called `haunt-plugin` in every plugin so that path never changes; if you rename the crate, change `entry` too.

## Install

```sh
haunt plugin install .
```

Haunt shows the capabilities from `haunt-plugin.toml` and asks before installing (`--yes` skips the question). It pins the sha256 of the wasm and the manifest. After a rebuild, run `haunt plugin install .` again: it updates the plugin and asks only if the plugin wants new capabilities. `haunt plugin list` shows what's installed, `haunt plugin remove <id>` removes it.

## Capabilities

Every plugin can add palette commands and modes, add entries to a tab's context menu (`row-menu`; a chosen entry calls `on-action(id, <surface>)`), keep up to 10 MB of its own data (`kv`), and write to its log. Each call runs under a 50 ms CPU budget and 64 MB of memory. Ask only for what you need in `[capabilities]`:

| key | grants |
|---|---|
| `events = [...]` | agent events delivered to `on-event`: `agent.session-start`, `agent.prompt`, `agent.task`, `agent.subagent`, `agent.tool`, `agent.permission-request`, `agent.notification`, `agent.plan-exit`, `agent.question`, `agent.todos`, `agent.file-edited`, `agent.stop`, `agent.unknown`, or `agent.*` for all. Events carry commands, paths and prompts, which can contain secrets. `terminal.*` names are accepted but not delivered yet. `verified` is false for an event anything in the terminal could have forged; plugins with `pty_write`, `decisions_read` or `allowlist_suggest` get verified events only. |
| `notifications = true` | `notify.notify`, notifications with action buttons; replies arrive at `on-action` |
| `pty_write = true` | `pty.answer`: Allow or Deny for the surface's pending permission request, nothing else. No event carries the request key yet, so this can't be used today. |
| `pty_type = true` | `typing.type-text`: types text, then Return if asked, into the current tab, only while handling a palette command or key the user just ran and never while that tab has a prompt up. No control or invisible characters but a tab. |
| `fs_read = ["glob", ...]` | `fs.read` and `fs.list` on matching paths |
| `fs_write = ["glob", ...]` | `fs.write` on matching paths |
| `decisions_read = true` | `decisions.query`: the verified permission decisions, newest first. Read only. |
| `allowlist_suggest = true` | `allowlist.approvals` (each exact Bash command approved in haunt at least twice, per project, with its folder) and `allowlist.propose`, which only offers a rule; Haunt writes it when the user accepts. |
| `sidebar = true` | `sidebar.rows` (tab names, kinds and state groups, no task text) and `sidebar.arrange`: pins, named sections, manual order and colours over Haunt's grouping. Rows needing you always stay first. Drags arrive at `on-row-moved`. |

An fs glob is absolute or starts with `${cwd}/` (the agent's folder, from verified events only, never `$HOME` or the haunt dir). It may use `*` within a path segment, but not `**`, `.` or `..`. Nothing inside the haunt dir is ever reachable.

`net`, `hid`, `exec`, `terminal_read` and `clipboard` are reserved: this Haunt version refuses a manifest that asks for them.

## Updating the WIT pin

`wit/haunt-plugin.wit` is a copy of Haunt's `wit/haunt-plugin.wit`, pinned at `haunt:plugin@0.4.0` (the `package` line). The manifest's `api = "0.4"` must match the major.minor Haunt supports. To move to a newer API:

1. Copy `wit/haunt-plugin.wit` from the Haunt version you target over `wit/haunt-plugin.wit`.
2. Set `api` in `haunt-plugin.toml` to the new major.minor.
3. Rebuild; wit-bindgen errors show the exports and imports that changed.

## Licence

MIT, see `LICENSE`.
