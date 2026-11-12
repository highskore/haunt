# {{name}}

{{description}}

A Haunt plugin: a sandboxed WebAssembly component that adds a "Say hello" command to the ⌘K palette and labels a tab's row with new tasks and tool calls.

Start a new plugin with `haunt plugin new <name> [--dir <path>] [--id <reverse-dns id>]`: it copies this template, fills in the id, name and description, and runs `git init`. If you copy the template by hand, replace the double-brace placeholders in `haunt-plugin.toml`, `Cargo.toml` and this README yourself; `haunt plugin install` refuses the placeholder id.

`description` in `haunt-plugin.toml` is optional: one line of at most 160 characters, which `haunt setup` and Settings show next to the name.

A plugin with `[settings]` gets them in `init` and again in `on-settings-changed` whenever config.toml changes them. Haunt clears its palette commands (not its modes) before that call, so register them again there.

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
| `events = [...]` | agent events delivered to `on-event`: `agent.session-start`, `agent.prompt`, `agent.task`, `agent.subagent`, `agent.tool`, `agent.permission-request`, `agent.notification`, `agent.plan-exit`, `agent.question`, `agent.todos`, `agent.file-edited`, `agent.stop`, `agent.unknown`, or `agent.*` for all. Commands, paths and prompts need `event_details` too. `terminal.*` names are accepted but not delivered yet. `verified` is false for an event anything in the terminal could have forged; plugins with `pty_write`, `decisions_read` or `allowlist_suggest` get verified events only. |
| `event_details = true` | the `command`, `file-path`, prompt and plan text on events, which can contain secrets; shown in red at install. Without it those fields are none. |
| `notifications = true` | `notify.notify`, notifications with action buttons; a chosen action arrives at `on-action(action-id, binding or "")` |
| `sidebar_top = true` | `top-row.set(row)`: one row of its own above every sidebar group; a click calls `on-action(action, "top")` |
| `keys = true` | `keys.bind(id, chord)`: a chord with cmd of its own; press and release call `on-action(id, "key-down")` and `"key-up"`. `keys.hover-hold(some("alt"))`: holding ⌥ over a sidebar row calls `on-hover-hold(true, surface)`, then `false` |
| `exec = ["git-status", ...]` | `exec.run(surface, command)`: fixed git and gh commands in the tab's project folder; the result calls `on-exec(job, outcome)` |
| `notify_hold = true` | `hold.start(minutes)` / `hold.set-summary(headline, actions)` / `hold.release()`: Haunt's and other plugins' notifications wait, then one summary shows once every holder lets go, with your headline and up to 2 actions (`on-action(id, "hold")`; an action's `surface`, an open tab's id, brings that tab forward first); permission prompts never wait |
| `pty_write = true` | `pty.answer`: Allow or Deny for the surface's pending permission request, nothing else. A verified `permission_seen` haunt can answer carries its `request-key`. |
| `away = true` | `on-away-changed(away, away-ms)`: the user locked, slept or idled past `[presence] away_after` minutes (config.toml, 10 by default), then came back; a sheet shown on the return waits until the user switches to Haunt (a second after, dropped if they type first or after 10 minutes) |
| `terminal_read = true` | `terminal.read(surface, lines)`: the last 1 to 50 visible lines of a tab, only while handling a palette command or key the user just used (any open tab), or during `on-hover-hold(true, surface)` while the user holds ⌥ over that row (that tab alone); 8 reads each time. Red consent line. |
| `pty_type = true` | `typing.type-text`: types text, then Return if asked, into the current tab, only while handling a palette command or key the user just ran and never while that tab has a prompt up. No control or invisible characters but a tab. |
| `fs_read = ["${cwd}/glob", ...]` | `fs.read` (files up to 4 MB) and `fs.list` (at most 4096 names) on matching paths inside agents' project folders; shown in red at install |
| `fs_write = ["${cwd}/glob", ...]` | `fs.write` on matching paths inside agents' project folders; shown in red at install |
| `decisions_read = true` | `decisions.query`: the verified permission decisions, newest first. Read only. |
| `allowlist_suggest = true` | `allowlist.approvals` (each exact Bash command approved in haunt at least twice, per project, with its folder) and `allowlist.propose`, which only offers a rule; Haunt writes it when the user accepts. |
| `decorate = true` | `rows.decorate(surface, decoration)`: a label or a sparkline in the row's right-hand slot (in place of the status), a suffix after its meta line and a thin bar under it. Plain text only: hidden characters are removed, labels cut to 24 characters and suffixes to 64. If two plugins decorate the same row, the one loaded first (installed first) is shown. |
| `timer = true` | `timer.every(seconds)`: `on-tick(now-ms)` every 15 seconds or more, until `timer.stop()`. Every plugin can read its time zone with `clock.local-offset-min()`. |
| `panel = true` | `panel.show(id, placement, title, nodes)`: a sheet, a right-hand pane, a floating card or a window the app draws from text, rows, buttons, dividers, a heat grid and a canvas. At most 512 nodes, 8 levels, 4 panels and 4 updates a second. Buttons and the user closing it arrive at `on-action(action, "panel:<id>")` (an empty action for a close). |
| `clipboard = "write"` | `clipboard.write(text)`: once per palette command, key, panel button or notification action the user used; lines kept, each plain; at most 400 lines and 16 KB. Any other value fails install: the clipboard is never read. |
| `open_url = ["github.com"]` | `link.open-url(url)`: from a click on a panel button (its tooltip shows the url) or notification action (its title gets the host) whose action is that https url, once per click; the host must be exactly a listed domain (no `xn--` labels). Every path on it is trusted, so an open redirect there can reach any site. |
| `fs_list = true` | `fs-list.entries(dir)`: names, sizes and folder flags directly in a folder inside an agent's project folder; no contents, no dot entries or symlinks, at most 4096 entries and 20 calls a second. `fs-list.tree(dir, depth ≤ 5)`: per-folder file counts and bytes for a whole repo, `truncated` past 50,000 entries; once per 10 s. It returns a job id; the result calls `on-fs-tree(job, outcome)`. |
| `sidebar = true` | `sidebar.rows` (tab names, kinds and state groups, no task text) and `sidebar.arrange`: pins, named sections, manual order and colours over Haunt's grouping. `sidebar.focus(surface)` switches to an open tab, once per button, key or command the user uses. Rows needing you always stay first. Drags arrive at `on-row-moved`. |

Every fs glob starts with `${cwd}/` (the agent's folder, from verified events only, never `$HOME` or the haunt dir). It may use `*` within a path segment, but not `**`, `.` or `..`. Nothing inside the haunt dir is ever reachable.

`net` and `hid` are reserved: this Haunt version refuses a manifest that asks for them.

## Updating the WIT pin

`wit/haunt-plugin.wit` is a copy of Haunt's `wit/haunt-plugin.wit`, pinned at `haunt:plugin@0.5.0` (the `package` line). The manifest's `api = "0.5"` must match the major.minor Haunt supports. To move to a newer API:

1. Copy `wit/haunt-plugin.wit` from the Haunt version you target over `wit/haunt-plugin.wit`.
2. Set `api` in `haunt-plugin.toml` to the new major.minor.
3. Rebuild; wit-bindgen errors show the exports and imports that changed.

## Licence

MIT, see `LICENSE`.
