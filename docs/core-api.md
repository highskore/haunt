# haunt-core API (Phase 1)

The Swift app talks to the core through one UniFFI object, `HauntCore` (`ffi/src/lib.rs`). The core owns the sidebar view-model: Swift renders `SidebarSnapshot` verbatim and doesn't format text or decide state.

## Object

```
object HauntCore {
  constructor(config_dir: string)                 // normally ~/.haunt
  fn start() -> Result<(), CoreError>             // binds <config_dir>/sock; a second call is a no-op
  fn register_surface(cwd: string) -> SurfaceEnv
  fn unregister_surface(surface_id: string)
  fn set_surface_info(surface_id: string, title: string, cwd: string, git_branch: Option<string>)
  fn select_surface(surface_id: string)           // marks Row.selected
  fn on_osc_notification(surface_id: string, title: string, body: string)
  fn snapshot() -> SidebarSnapshot
  fn set_listener(listener: CoreListener)
  fn answer_permission(surface_id: string, allow: bool) -> Option<bytes>
}

callback interface CoreListener { fn changed() }

record SurfaceEnv { surface_id: string, nonce: string, socket_path: string }
error  CoreError { Insecure { reason }, Io { reason } }

record SidebarSnapshot { groups: sequence<SidebarGroup> }
record SidebarGroup { label: string, rows: sequence<Row> }
record Row {
  surface_id: string, kind: RowKind, name: string, meta: string, status_text: string,
  needs_you: bool, progress: Option<Progress>, subagents: sequence<Subrow>, selected: bool
}
enum   RowKind { Shell, Claude }
record Progress { done: u64, total: u64 }
record Subrow { label: string, meta: string }
```

`select_surface` is an addition to the contract as first agreed, because `Row.selected` needs a source. `SidebarGroup` was renamed from `Group` because a Swift `struct Group` would shadow SwiftUI's `Group`.

In Swift, the generated `Progress` struct shadows `Foundation.Progress` inside the module. Write `Foundation.Progress` if you need the other one.

## Using it

1. Create one `HauntCore(configDir: "~/.haunt" expanded)`, call `setListener`, then `start()`. If `start` throws, show the reason and keep running: the OSC fallback still works, but only for status.
2. For each new surface, call `registerSurface(cwd:)` and put these in the pty environment:

   | variable | value |
   |---|---|
   | `HAUNT` | `1` |
   | `HAUNT_SURFACE_ID` | `env.surfaceId` |
   | `HAUNT_HOOK_NONCE` | `env.nonce` (128-bit random, hex) |
   | `HAUNT_SOCK` | `env.socketPath` |

3. On `PWD` and title changes, and whenever the git branch is known, call `setSurfaceInfo`. On tab selection, call `selectSurface`. When a tab closes, call `unregisterSurface`.
4. On `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` with title `haunt://cli-agent` or `warp://cli-agent`, call `onOscNotification`. The core ignores other titles, so the UI can pass every notification through and still show the non-agent ones itself.
5. `changed()` fires on whatever thread made the change. That is often the socket thread. Hop to the main actor, then call `snapshot()`. It is never called while the core holds its lock, so calling back into the core is safe.
6. Allow/Deny: `answerPermission(surfaceId, allow)` returns `"\r"` (allow) or `"\u{1b}"` (deny) for `ghostty_surface_text`. It returns them only while that surface is blocked on a nonce-verified permission request, and consumes the request, so a second call returns `nil`. If it returns `nil`, write nothing.

Elapsed times in subrow meta are computed when `snapshot()` runs. A UI that wants them to tick can call `snapshot()` once a second while any row is running.

## Snapshot format (mockup layout 06, grouped flat)

Groups, in order: `NEEDS YOU`, `RUNNING`, `IDLE`. Done, failed and shell rows go in `IDLE`. Empty groups are left out. Within a group, the most recent status change comes first. Ties keep tab (registration) order.

| field | shell | Claude |
|---|---|---|
| `name` | last path component of the cwd (`~` for home) | same |
| `meta` | git branch, else the `~`-abbreviated cwd | `branch · task`; the cwd stands in for a missing branch |
| `status_text` | empty | `needs you`, `3/5` (running with progress), empty (running without progress), `done`, `failed`, empty (idle) |
| `progress` | none | `done/total` of the main agent's tasks, else of its latest TodoWrite |
| `subagents` | none | while running or needing you: `label` = `Explore · trace hooks`, `meta` = `2/4 · 1m12s` or `14 tools · 48s` |

The task part of `meta`:

- needs you: `Approve: git push?` for a verified Bash request, `Approve: Edit /w/a.rs?` for other tools, and `Waiting for you` when the request isn't verified
- running: the subject of the latest in-progress task, else the prompt (one line, at most 120 characters)
- done: `Done in 4m` (`45s`, `4m`, `1h5m`)
- failed: `Failed`

A surface becomes a Claude row with its first agent event and stays one until it is unregistered. Phase 1 hooks send no session-end event.

## Transport and security

**Socket** (`core/src/intake.rs`, owned by `HauntCore`): `<config_dir>/sock`. The debug/CLI socket is `<config_dir>/ctl`.

- The directory is created with mode 0700. `start` refuses (`CoreError::Insecure`) a directory that is a symlink or is owned by another uid. If it has group or other bits, it is ours, so they are removed. The socket is chmod 0600, and its owner and mode are checked after `bind`.
- A leftover socket of ours is replaced. `start` refuses anything else at that path, a socket owned by another uid, and a socket that still accepts connections (`CoreError::Io`: another haunt is running). It also refuses a path longer than `sun_path` allows.
- Every connection's peer uid (`getpeereid`) must equal ours. At most 32 connections are open at once, each with a 5 s read timeout.
- Messages are newline-delimited JSON of at most 64 KB. A longer line is discarded, and the stream continues with the next line.
- Each line is the hook's v1 envelope (`hooks/README.md`) plus `surface_id`. Lines for a surface that isn't registered are dropped before rate limiting, so random ids cost nothing. Each surface is rate-limited to 50 events/s with a burst of 200; extra lines are dropped and counted.

**Nonce gating** (`core/src/session.rs`): an event is *verified* only if it came over the socket and its `nonce` matches that surface's nonce, compared in constant time. Unverified events (wrong or missing nonce, or any OSC 777 event) may change status and progress, but never the permission request. Only a verified request can be answered. Unverified events can't set, replace or clear one. `answer_permission` also requires the surface to be in `needs you` at that moment.

A request resolves when a verified `tool_ran`, `tool_done` or `tool_failed` matches it. The match is on `tool_use_id` when both sides have one (the id is taken from the matching `tool_start`), otherwise on tool name plus exact command or file path. An event with `truncated: true` never matches. A verified `stop` or `prompt_submit`, or an answer, also clears the request.

**OSC 777 fallback**: `haunt://cli-agent` and `warp://cli-agent` bodies go through the same parser, but they count for status only. The haunt hook sends a stripped-down status body there (no nonce, under 255 bytes).

The app must not bind `HauntIntake` (the spike's standalone export) at the same time: `HauntCore.start()` owns the socket, and a second bind fails with "in use".
