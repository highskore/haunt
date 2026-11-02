# haunt-core API (Phase 2)

The Swift app talks to the core through one UniFFI object, `HauntCore` (`ffi/src/lib.rs`). The core owns the sidebar view-model: Swift renders `SidebarSnapshot` verbatim and doesn't format text or decide state. The events adapters send are specified in [agent-events.md](agent-events.md).

## Object

```
object HauntCore {
  constructor(config_dir: string)                 // normally ~/.haunt
  fn start() -> Result<(), CoreError>             // binds sock and ctl, opens decisions.jsonl; a second call is a no-op
  fn register_surface(cwd: string) -> Result<SurfaceEnv, CoreError>   // Invalid past 512 surfaces
  fn unregister_surface(surface_id: string)
  fn set_surface_info(surface_id: string, title: string, cwd: string, git_branch: Option<string>)
  fn select_surface(surface_id: string)           // marks Row.selected
  fn on_osc_notification(surface_id: string, title: string, body: string)
  fn snapshot() -> SidebarSnapshot
  fn set_listener(listener: CoreListener)
  fn answer_permission(surface_id: string, request_key: u64, allow: bool) -> Option<bytes>
  fn on_user_input(surface_id: string)           // every keyDown routed to that surface
  fn decisions(query: string, limit: u32) -> sequence<Decision>     // newest first
  fn allow_suggestions() -> sequence<AllowSuggestion>              // plugin proposals that pass every check
  fn accept_allow_suggestion(project: string, command: string) -> Result<(), CoreError>
  fn dismiss_allow_suggestion(project: string, command: string)
}

callback interface CoreListener { fn changed() }

record SurfaceEnv { surface_id: string, nonce: string, socket_path: string }
error  CoreError { Insecure { reason }, Io { reason }, Invalid { reason } }

record SidebarSnapshot { groups: sequence<SidebarGroup>, color_style: ColorStyle }
record SidebarGroup { id: string, label: string, rows: sequence<Row> }   // id: needs-you, running, idle, pinned, tabs, section:<id>
record Row {
  surface_id: string, kind: RowKind, name: string, meta: string, status_text: string,
  needs_you: bool, progress: Option<Progress>, subagents: sequence<Subrow>, selected: bool,
  pending: Option<PendingRequest>, color: Option<TabColor>
}
enum   TabColor { Red, Orange, Yellow, Green, Blue, Purple, Gray }
enum   ColorStyle { Dot, Tint }
record PendingRequest { key: u64, tool: string, preview: string, suspicious: bool }
enum   RowKind { Shell, Claude, Codex }     // an agent without a kind of its own is Claude
record Progress { done: u64, total: u64 }
record Subrow { label: string, meta: string }

record Decision { at_ms: u64, surface_id: string, tool: string, preview: string, command: Option<string>, cwd: Option<string>, outcome: Outcome, agent: Agent }
enum   Agent { Claude, Codex, Other { id: string } }   // "claude", "codex" or the id in decisions.jsonl; absent is Claude
enum   Outcome { AllowedInHaunt, DeniedInHaunt, AllowedByPlugin { plugin_id: string }, DeniedByPlugin { plugin_id: string }, AnsweredInTerminal, Superseded }
record AllowSuggestion { project: string, command: string, rule: string, approvals: u32, plugin_id: string }
```

`select_surface` is an addition to the contract as first agreed, because `Row.selected` needs a source. `SidebarGroup` was renamed from `Group` because a Swift `struct Group` would shadow SwiftUI's `Group`.

In Swift, the generated `Progress` struct shadows `Foundation.Progress` inside the module. Write `Foundation.Progress` if you need the other one.

## Using it

1. Create one `HauntCore(configDir: "~/.haunt" expanded)`, call `setListener`, then `start()`. If `start` throws, show the reason and keep running: the OSC fallback still works, but only for status.
2. For each new surface, call `try registerSurface(cwd:)` and put these in the pty environment. It throws `Invalid` once 512 surfaces are registered; open the tab without the env then (hooks fall back to status-only OSC).

   | variable | value |
   |---|---|
   | `HAUNT` | `1` |
   | `HAUNT_SURFACE_ID` | `env.surfaceId` |
   | `HAUNT_HOOK_NONCE` | `env.nonce` (128-bit random, hex) |
   | `HAUNT_SOCK` | `env.socketPath` |

3. On `PWD` and title changes, and whenever the git branch is known, call `setSurfaceInfo`. On tab selection, call `selectSurface`. When a tab closes, call `unregisterSurface`.
4. On `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` with title `haunt://cli-agent` or `warp://cli-agent`, call `onOscNotification`. The core ignores other titles, so the UI can pass every notification through and still show the non-agent ones itself.
5. `changed()` fires on whatever thread made the change. That is often the socket thread. Hop to the main actor, then call `snapshot()`. It is never called while the core holds its lock, so calling back into the core is safe.
6. Allow/Deny: a row with `pending` has a nonce-verified request. If `pending.suspicious` is set, show the preview with a warning and no Allow/Deny: the command is multi-line or has hidden characters, so it is answered only in the terminal, and `answerPermission` returns `nil` for it. Keep `pending.key` with whatever offers the answer (the button, a notification's `userInfo`) and pass it back: `answerPermission(surfaceId, requestKey, allow)` returns the asking agent's keys for `ghostty_surface_text`: `"1"` (allow) or `"\u{1b}"` (deny) for Claude Code, `"y"` or `"\u{1b}"` for Codex (see [agent-events.md](agent-events.md#agent-ids)). An agent haunt has no keys for gets no `pending` at all. For Claude Code, `1` picks Claude Code's first option, "Yes", wherever the highlight is, where Enter would pick the highlighted one ("Yes, and don't ask again" or "No" if the highlight moved). In a prompt that defaults to No, Claude Code hides the indexes and ignores digits, so `1` does nothing there rather than answering No. It returns them only while that key is still the surface's live request, and consumes the request, so a second call, or a key from a prompt that has since changed, returns `nil`. If it returns `nil`, write nothing.

### UI must call

- `onUserInput(surfaceId)` on every keyDown routed to a surface (before or as it goes to the pty). Once the user types at the terminal, the prompt may already be answered and the tool running until `PostToolUse` arrives, so a late Allow (`1`) or Deny (Esc) from haunt would be typed into the running session. The call retires the surface's live request: `pending` disappears, `answerPermission` returns `nil`, and the request is logged when its outcome is known (`AnsweredInTerminal` if the matching tool runs, else `Superseded`). The macOS app makes its surfaces `HauntSurfaceView` (`macos/Sources/MainWindow.swift`), a subclass of the vendored `Ghostty.SurfaceView`. libghostty has no single write choke point the app can hook (clipboard reads also serve OSC 52), so the subclass calls it before `super` on each user write path: `keyDown`, the three paste actions, `insertText` (IME, Character Viewer, dictation), middle-click `otherMouseDown`, `performDragOperation`, `readSelection` (Services), and whenever a paste confirmation resolves. Ghostty's own bindings reach the surface through `keyDown` as well, menu shortcuts never do, and the vendored sources stay unpatched. Mouse clicks and scrolls that a TUI's mouse mode reports, and key-release events, are not counted: a click to focus the terminal shouldn't drop the request.
- `try registerSurface(cwd:)`: it throws now (past 512 surfaces), so `CoreAPI.registerSurface` must be `throws` and its callers need `try`.
- `gatePluginRequest(request:)` for every `.ptyAnswer` from `HauntPlugins.takeRequests()`, writing only the bytes it returns (see Plugins).

Elapsed times in subrow meta are computed when `snapshot()` runs. A UI that wants them to tick can call `snapshot()` once a second while any row is running.

## Decision log

Every verified permission request is recorded once, when it ends, with its outcome:

| outcome | when |
|---|---|
| `AllowedInHaunt` / `DeniedInHaunt` | `answer_permission` with the live key |
| `AllowedByPlugin` / `DeniedByPlugin` | a plugin's `.ptyAnswer` through `gate_plugin_request`; in `decisions.jsonl` it is `{"allowed_by_plugin":{"plugin_id":…}}` |
| `AnsweredInTerminal` | a verified `tool_ran`/`tool_done`/`tool_failed` matched it, so it was allowed at the terminal prompt |
| `Superseded` | anything else ended it: a newer prompt, leaving `needs you` (including a denial typed in the terminal, which then shows up as the next prompt or stop), or the surface closing |

Requests only exist for verified events, so unverified events never add an entry; they can only end a verified request, which is then logged as `Superseded`. Entries live in memory (the last 10,000) and in `<config_dir>/decisions.jsonl`, one JSON object per line, appended. `start` opens it with `O_NOFOLLOW`, refuses a symlink or a file of another uid, keeps it 0600, and loads the existing lines. Loading is strict: a line with an unknown field or outcome, an empty surface id or tool, or a `command` that isn't a Bash command whose `preview` shows exactly that command is skipped. Before `start` the log is memory-only.

`decisions(query, limit)` returns them newest first; `query` is a case-insensitive substring of tool, preview, cwd, outcome (`allowed_in_haunt`, …) or surface id, and empty matches all. The ⌘K `log` mode is not built in: it is the first-party plugin `dev.haunt.decision-log` (`~/code/haunt-plugins/haunt-decision-log`), which reads the same records through the `decisions` import (see Plugins).

## Allowlist suggestions

Nothing is allowed by default. The core keeps the safety primitives: it counts approvals, holds the proposals and is the only thing that writes a rule. When to offer a rule is a plugin's call: the first-party `dev.haunt.allowlist` (`~/code/haunt-plugins/haunt-allowlist`) proposes one after 3 identical approvals. The core never suggests anything on its own.

A plugin with `allowlist_suggest` reads the counts (`allowlist.approvals(min-count)`) and calls `allowlist.propose(project, command)`. That only records a pending suggestion and fires `changed()`; it writes no file. `allow_suggestions()` lists the proposals that still pass every check, with the exact rule `Bash(<command>)`, the current count and the proposing `plugin_id`, most recently approved first. Every proposal is checked when it is made, whenever suggestions are listed, and again on accept:

- It needs at least one counted approval of exactly that command in exactly that project. Only Claude Code approvals count, because Claude Code is the one agent that reads `.claude/settings.local.json`, and only clicks in haunt (`AllowedInHaunt`). `AllowedByPlugin` and `AnsweredInTerminal` never count; see the nonce limit below. A plugin can't propose a command you never approved.
- Counting uses `Decision.command`, the command exactly as the hook sent it (`ToolCall.raw_command`), not the shown `preview`. An approval counts only if the two are equal, so a command with invisible characters, tabs or newlines (which the preview shows as markers) never counts, and a rule can't allow a variant of what was approved. Log lines without `command` (written before it existed) don't count.
- Wildcards are never suggested: a command containing `*`, `(` or `)`, anything outside printable ASCII, leading or trailing spaces, or over 1024 bytes can't be proposed.
- The project (the hook cwd) must be absolute with no `.` or `..` components, equal byte for byte to its canonical path (so no symlink anywhere in it, and no trailing or doubled slash), and a directory owned by the current uid (`Invalid` or `Insecure` if it fails).
- A rule the user accepted or dismissed in this run can't be proposed again. At most 256 proposals are kept.

`accept_allow_suggestion(project, command)` only accepts a current suggestion (`Invalid` otherwise) and adds the rule to `<project>/.claude/settings.local.json` under `permissions.allow`, keeping every other key and their order (the file is re-indented). A file that isn't a JSON object, or a non-object `permissions` or non-array `allow`, is an `Invalid` error and is never overwritten. It refuses (`Insecure`) a symlinked `.claude` or settings file and never follows one: the directory is opened with `O_NOFOLLOW`, and the new content goes to a temp file (`O_EXCL | O_NOFOLLOW`) in it that is renamed over the old one. The file keeps its mode, or gets 0600 if new. Accepted and dismissed suggestions are not offered again in this run. Neither that memory nor the proposals are persisted yet, so after a restart the plugin proposes again, and a dismissed rule comes back.

## Snapshot format (mockup layout 06, grouped flat)

Groups, in order: `NEEDS YOU`, `RUNNING`, `IDLE`. Done, failed and shell rows go in `IDLE`. Empty groups are left out. Within a group, the most recent status change comes first. Ties keep tab (registration) order.

| field | shell | agent (Claude, Codex) |
|---|---|---|
| `name` | last path component of the cwd (`~` for home) | same, of the agent cwd |
| `meta` | `~cwd · <shell>`, e.g. `~/code/vibes · zsh` (the basename of `$SHELL`) | `branch · task`; the agent cwd stands in for a missing branch |

The agent cwd is the latest verified hook event's `cwd`, falling back to the surface cwd from `setSurfaceInfo`. A Claude launched as the surface's command never changes the shell's `PWD`, so the hook is the only place its cwd shows up. Once there is an agent cwd, the core reads the branch from `.git/HEAD` above it on every verified event and ignores the `git_branch` the UI passed; the API is unchanged.
| `status_text` | empty | `needs you`, `3/5` (running with progress), empty (running without progress), `done`, `failed`, empty (idle) |
| `progress` | none | `done/total` of the main agent's tasks, else of its latest TodoWrite |
| `subagents` | none | while running or needing you: `label` = `Explore · trace hooks`, `meta` = `2/4 · 1m12s` or `14 tools · 48s` |

The task part of `meta`:

- needs you: `Approve: git push?` for a verified Bash request, `Approve: Edit /w/a.rs?` for other tools, and `Waiting for you` when the request isn't verified
- running: the subject of the latest in-progress task, else the prompt (one line, at most 120 characters)
- done: `Done in 4m` (`45s`, `4m`, `1h5m`)
- failed: `Failed`

A surface becomes an agent row with its first agent event and stays one until it is unregistered. Its kind follows the `agent` of the latest verified event (`Claude` until one arrives). Phase 1 hooks send no session-end event.

### Arrangement (`core/src/arrange.rs`)

A plugin granted `sidebar` (the first-party one is `dev.haunt.tabs`) can push an arrangement: pinned tabs, named sections, a manual order, a flat list, and colours. The core merges it over its own grouping on every `snapshot()`:

1. `NEEDS YOU` (`needs-you`) first: every row that needs you, in the core's order, whatever the arrangement says. When a pinned or sectioned row stops needing you, it goes back to its place.
2. `PINNED` (`pinned`): the pinned rows, in the plugin's order.
3. The plugin's sections (`section:<id>`), before or after step 4 as the arrangement's `placement` says. A row listed in more than one place goes to the first: pinned, then sections in order.
4. `RUNNING` (`running`) and `IDLE` (`idle`) with the rest, or one `TABS` group (`tabs`) when `flat` is set. Rows the plugin ranked in `order` come first, in that order, and the rest follow in the core's order. One global order means a tab that leaves RUNNING and comes back keeps its place. A group of shells only still has no label.

Every row shows exactly once. Unknown and repeated surface ids are ignored, and empty groups are left out. A section title is 1 to 32 ASCII letters, digits, spaces and basic punctuation (`-_.,:;!?'&()/+#`), so no lookalike letters from other scripts; it is single-spaced and uppercased like the core's labels. Its letters and digits may not spell `NEEDS YOU`, `RUNNING`, `IDLE`, `PINNED` or `TABS`, so `N-E-E-D-S YOU` is refused too. Section ids are lowercase letters, digits and `-`. At most 32 sections and 1024 ids per list; `sidebar.arrange` refuses anything else.

The first plugin to arrange owns the sidebar until it calls `clear` or goes away; others get an error. An arrangement belongs to the loaded instance that set it. It is dropped when that plugin is disabled (a trap or timeout), reloaded or removed, and the snapshot applies only an arrangement whose instance is still loaded with `sidebar`. `Row.color` is set only for rows the plugin coloured. `SidebarSnapshot.color_style` says how to draw it: `Dot`, a small dot beside the name, or `Tint`, a faint background. Without an arrangement every row has no colour and the style is `Dot`.

The colours are names, so the app picks shades that sit in the black-and-white design. `design/tokens.json` is generated from the mockups, so they belong in Swift (or a hand-kept token file), not there. A starting point: dot at full value, tint at about 12% over `color.sidebar.bg`.

| colour | dot |
|---|---|
| Red | `#b07a7a` |
| Orange | `#b08f72` |
| Yellow | `#ada27a` |
| Green | `#84a083` |
| Blue | `#7f93ad` |
| Purple | `#9a87ad` |
| Gray | `#8a8a8a` |

## Transport and security

**Socket** (`core/src/intake.rs`, owned by `HauntCore`): `<config_dir>/sock`. The debug/CLI socket `<config_dir>/ctl` follows the same directory, socket and peer-uid rules (below).

- The directory is created with mode 0700. `start` refuses (`CoreError::Insecure`) a directory that is a symlink or is owned by another uid. If it has group or other bits, it is ours, so they are removed. The socket is chmod 0600, and its owner and mode are checked after `bind`.
- A leftover socket of ours is replaced. `start` refuses anything else at that path, a socket owned by another uid, and a socket that still accepts connections (`CoreError::Io`: another haunt is running). It also refuses a path longer than `sun_path` allows.
- Every connection's peer uid (`getpeereid`) must equal ours. At most 32 connections are open at once. Each line must arrive whole within 2 s of the previous one, and a connection is closed after 10 s in total, so a peer trickling bytes can't hold the slots and silence the hooks.
- Messages are newline-delimited JSON of at most 64 KB. A longer line is discarded, and the stream continues with the next line.
- Each line is one v1 event ([agent-events.md](agent-events.md)) with `surface_id`. Lines for a surface that isn't registered are dropped before rate limiting, so random ids cost nothing. Each surface is rate-limited to 50 events/s with a burst of 200, separately for verified and unverified lines, so a flood of forged lines for a known surface id can't drop the real ones; extra lines are dropped and counted.

**Nonce gating** (`core/src/session.rs`): an event is *verified* only if it came over the socket and its `nonce` matches that surface's nonce, compared in constant time. Unverified events (wrong or missing nonce, or any OSC 777 event) may change status and progress, but can never create an answerable request. The rules:

- Only a verified `permission_seen` creates a request, and only if it isn't `truncated` and carries a command or file path. Otherwise the row shows "Waiting for you" and the user answers in the terminal.
- Leaving `needs you` for any reason, verified or not, drops the request.
- Each entry into `needs you`, and each `permission_seen`, starts a new generation. A request can be answered only in the generation that created it. So an unverified event that puts the row back into `needs you` (a forged stop and then a forged `permission_prompt`, say) can never revive an old request. A forged `permission_seen` retires the real one, which costs the user the button but never sends an answer to the wrong prompt.
- `answer_permission` needs the surface to be in `needs you` with a live request at that moment whose key is the one passed in, not `suspicious` and not retired by `on_user_input`, and consumes it.

A request resolves when a verified `tool_ran`, `tool_done` or `tool_failed` matches it. The match is on `tool_use_id` when both sides have one (the id is taken from the matching `tool_start`), otherwise on tool name plus exact command or file path. An event with `truncated: true` never matches. Any change out of `needs you`, or an answer, also clears it. For an agent other than Claude Code (Codex has no failure hook), a verified tool event from the same thread that isn't the pending call also ends it as `Superseded` (see [agent-events.md](agent-events.md#agent-ids)).

**Invisible characters**: the hook sends `tool_input` strings over the socket unmodified (JSON escapes keep them on one line). Every other decoded string has control characters and Unicode format characters (General_Category Cf: bidi overrides U+202A–202E and U+2066–2069, zero-widths U+200B–200F, U+2060, U+FEFF, soft hyphen, tags and so on) removed, and other whitespace turned into a space.

A request keeps its command or file path exactly as sent. Its `preview` hides nothing: a newline shows as `⏎`, a tab as `⇥`, and any other control, Cf or non-space whitespace character as `\u{…}`, so `ls #\nrm -rf ~/x` shows as `ls #⏎rm -rf ~/x` and can't pass for a comment. A request with any such character is `suspicious`: `answer_permission` refuses it (it stays live until the terminal answers) and it is never suggested for the allowlist. Matching a request to its `tool_ran` uses the exact input too.

**What the nonce does not protect against**: `HAUNT_HOOK_NONCE` is in the pty environment, so every process the session starts inherits it, including the commands Claude's tools run. Code running inside the session can therefore read it and forge verified events for its own surface: a fake `permission_seen` (which retires the real request and shows its own preview), a fake `tool_ran` (which logs `AnsweredInTerminal`), a fake cwd. Verification separates the hooks from other local programs and from text printed into the pty (OSC), not from the session's own tools. That is why `AnsweredInTerminal` never counts toward allowlist suggestions, only a click in haunt does, and why a plugin's `${cwd}` grant never widens to `$HOME` or the haunt dir.

**OSC 777 fallback**: `haunt://cli-agent` and `warp://cli-agent` bodies go through the same parser, but they count for status only. The haunt hook sends a stripped-down status body there (no nonce, at most 250 bytes).

## Plugins (`HauntPlugins`, feature `plugins`)

Installed with `haunt plugin install <path>` (cli/), which shows the capabilities, asks y/N (`--yes` for scripts) and pins sha256 of the wasm and manifest in `~/.haunt/plugins.lock`. A plugin whose files no longer match is not loaded until `haunt plugin approve <id>`.

`haunt plugin new <name> [--dir <path>] [--id <id>]` scaffolds a plugin repo from `cli/template/`, a snapshot of the `haunt-plugin-template` repo embedded in the binary, with `wit/haunt-plugin.wit` from this checkout. The id defaults to `dev.haunt.<name>` and must pass the same reverse-DNS rule as the manifest; it refuses a non-empty folder and runs `git init`. When the template repo changes, copy it over `cli/template/` (without `wit/`); `cli/tests/plugin.rs` builds and installs the scaffold.

| call | what |
|---|---|
| `HauntPlugins.load(hauntDir:core:bundledDir:)` | first installs or updates the app's own plugins from `bundledDir` (see Bundled plugins), then loads every pinned plugin from `<hauntDir>/plugins` with only its granted imports; runs `init`. `core` (the `HauntCore`) backs the `decisions` and `allowlist` imports, and from then on every event for a registered surface reaches the plugins whose `events` grant covers it, with `verified` set as below. Call it after `core.start()` so the decision log is loaded. |
| `loadErrors()` | plugins skipped, with the reason (hash mismatch, link error, trap) |
| `paletteItems(mode: nil, query:)` | registered commands and modes (`isMode`), title-filtered by `query` |
| `paletteItems(mode: "word", query:)` | the items that mode's plugin returns for `query`, each with optional `atMs` (time column), `mark` (`open`, `filled`, `round`) and `surfaceId` (Enter jumps to that tab, if it is open, instead of invoking the item) |
| `invokePaletteItem(pluginId:itemId:)` | calls the plugin's `on-action(itemId, "")` |
| `takeRequests()` | `HostRequest.notify` / `.ptyAnswer` queued by plugins |
| `rowMenuItems(surfaceId:)` | every plugin's entries for that row's context menu, built when it opens: `RowMenuItem { pluginId, id, title, checked, parent }`. An entry whose `parent` is another entry's id goes in that entry's submenu (one level). |
| `invokeRowMenuItem(pluginId:itemId:surfaceId:)` | calls the plugin's `on-action(itemId, surfaceId)` |
| `rowMoved(surfaceId:groupId:beforeSurfaceId:)` | a sidebar drag ended: the row was dropped into the `SidebarGroup.id` `groupId`, above `beforeSurfaceId` (`nil`: at the end). It goes to plugins granted `sidebar`, whose new arrangement then fires `changed()`. Don't offer drops into `needs-you`; they are ignored. |
| `HauntCore.gatePluginRequest(request:)` | the only way to turn a `.ptyAnswer` into bytes (`core/src/ptygate.rs`); returns `PtyWrite { surfaceId, bytes }` or `nil` |

Each call runs under a 50 ms CPU budget and 64 MB of memory; a trap or timeout disables that plugin until the next load.

Events reach plugins on the thread that delivered them (usually the socket thread), after the core has released its lock. A plugin call holds the plugins' lock and may then take the core's, through `decisions` or `allowlist`; the core never calls a plugin while holding its own. `propose` and `arrange` fire `changed()` from inside a plugin call, so the listener must hop to the main actor and not call `HauntPlugins` synchronously. Row decorations from `on-event` are dropped for now: the snapshot has no field for them yet.

**Verified events**: `agent-event.verified` is true when the event came over the socket with the surface's nonce (see Nonce gating). An unverified one (OSC 777, wrong or no nonce) can be forged by anything that prints into the terminal, so treat its fields as untrusted. A plugin granted `pty_write`, `allowlist_suggest` or `decisions_read` gets verified events only. Only a verified event's `cwd` widens a `${cwd}` grant.

**API version**: `haunt:plugin@0.3.0`; manifests say `api = "0.3"`. Older plugins no longer install or load; rebuild them against the 0.3 WIT.

- 0.2 added the `decisions` and `allowlist` imports (below), and `at-ms`, `mark` and `surface` on `palette-item`, plus the `mark` enum.
- 0.3 added `verified` on `agent-event`, the `sidebar` import (below), and two exports every plugin implements. `row-menu(surface) -> list<menu-item>` builds context-menu entries; a chosen entry calls `on-action(id, surface)`. `on-row-moved(surface, group, before)` is called only for plugins granted `sidebar`.

**sidebar** (`sidebar`):

- `rows()` returns the rows in the core's order with surface id, name, kind (`shell`, `claude`, `codex`), state group and selection. It includes no meta, task, prompt or command text.
- `arrange(arrangement)` sets this plugin's arrangement, merged as described under Arrangement, and `clear()` gives the sidebar back.
- Surface ids last as long as their tab and are new after a restart, so per-tab state keyed by them starts over with every launch.

**decisions** (`decisions_read`): `query(text, limit)` returns the same records as `HauntCore.decisions`, at most 1000, without the raw `command` (the preview shows it with nothing hidden). It is read only: nothing a plugin can call adds, changes or removes a decision.

**allowlist** (`allowlist_suggest`): `approvals(min-count)` returns the counted approvals (Claude Code, clicked in haunt, the raw command equal to its preview) per project and exact command, newest first. The host raises `min-count` to at least 2 (`APPROVALS_MIN`), so a one-off approval, such as an `export TOKEN=…`, never reaches a plugin. `propose(project, command)` adds a pending suggestion; it errors if the proposal fails a check (see Allowlist suggestions). No import writes a settings file, and none can accept a suggestion. Only `HauntCore.acceptAllowSuggestion` does, after the user accepts it in the UI.

An ungranted import is absent: a component that imports it fails to link at install and at load.

**Bundled plugins**: `macos/make-app.sh` builds the decision-log and allowlist plugins (or the repos in `HAUNT_FIRST_PARTY_PLUGINS`) and puts each in `haunt.app/Contents/Resources/plugins/<id>/` as `haunt-plugin.toml` and `plugin.wasm`, inside the signature. `Store::install_bundled` installs them on launch without a prompt, pinned with `source = "bundled"`:

- A new bundled plugin is installed with the capabilities its manifest asks for.
- When the app ships a different build of one, it is updated in place, unless it asks for a capability the pinned one wasn't granted. Then the new files go on disk unpinned, the plugin stops loading ("does not match the lockfile"), and `haunt plugin approve <id>` shows the full prompt.
- A copy installed from another source is never replaced. `haunt plugin remove` of a bundled plugin adds its id to the lockfile's `removed_bundled`, and it is never installed again.

**fs grants**: `${cwd}` in an `fs_read`/`fs_write` glob expands only to cwds of verified events. A cwd that is `$HOME`, an ancestor of it, inside the haunt dir or containing it is ignored, and if `$HOME` can't be resolved `${cwd}` expands to nothing. No path inside the haunt dir is ever readable, writable or listable, whatever the globs say.

**pty writes** (`pty_write`): a plugin can only call `pty.answer(surface, allow, request-id: u64)`, where `request-id` is the `key` of that surface's pending request. There is no free-form text: a plugin typing arbitrary text with ESC or `\r` could drive the session. Pass every `.ptyAnswer` to `gatePluginRequest` and write exactly the bytes it returns to `surfaceId`; it goes through `answer_permission`, so the key must be the live request of that very surface, not suspicious and not retired by typing, and it is consumed. Never write anything for a request it returns `nil` for. The agent events plugins receive don't carry the key yet, so no plugin can use this until they do.

## Control socket and CLI

`<config_dir>/ctl` (`core/src/ctl.rs`) is bound by `start` next to `sock`, with the same directory, 0600, stale-socket and peer-uid rules, but separately, so hook floods and rate limits never reach it. At most 8 connections; each line must arrive whole within 5 s of the previous one and a connection is closed after 10 s; lines up to 64 KB. Each request is one JSON line and gets one JSON line back, `{"ok":false,"error":…}` on failure:

| request | response |
|---|---|
| `{"cmd":"dump"}` | `{"ok":true,"snapshot":<SidebarSnapshot>,"pending":[{"surface_id","key","tool","preview","suspicious"}]}` |
| `{"cmd":"event","line":<hook line, object or string>}` | `{"ok":true,"verified":bool,"changed":bool}`. The line goes through the same nonce check as `sock`: without the surface's nonce it is status-only. |
| `{"cmd":"decisions","query":"git","limit":50}` | `{"ok":true,"decisions":[<Decision>…]}`; `query` and `limit` (default 50, at most 1000) are optional |

Nonces never appear in any response.

The `haunt` binary (`cli/`) talks to it: `haunt dump` prints the dump as pretty JSON, and `haunt decisions [query]` prints one decision per line as JSON, newest first. It uses `$HAUNT_CTL` if set, else `~/.haunt/ctl`.
