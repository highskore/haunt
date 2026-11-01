# Agent event spec v1

This is the contract every adapter emits and the core parses: `haunt-claude` (Claude Code), `haunt-codex` (Codex CLI), and any later one. The parser is `core/src/event.rs`; what the events do is `core/src/session.rs`, `progress.rs` and `intake.rs`. The examples at the end are parsed by a test in `event.rs`, so this file and the parser can't drift apart. MUST and SHOULD carry their RFC 2119 meaning.

## Agent ids

`agent` is a lowercase ASCII id for the coding agent behind the session.

| id | agent | row kind | Allow / Deny keys | allowlist suggestions |
|---|---|---|---|---|
| `claude` | Claude Code | `Claude` | `1` / Esc | yes |
| `codex` | Codex CLI | `Codex` | `y` / Esc | no |
| anything else | a future adapter | `Claude` | none: answered in the terminal only | no |

A new agent takes a new id in this table. Adapters MUST send `agent` on every event. A missing `agent` means `claude`, only so that pre-spec hooks keep working.

The core keeps the agent per surface from **verified** events only, so a forged OSC body can't relabel a row or change its answer keys. A request remembers the agent that asked, and its answer keys and decision-log entry come from that.

- **Keys.** Claude Code's prompt maps `1` to "Yes" wherever the highlight is. Codex's approval overlay (codex-cli 0.136 tui keymap) maps `y` to proceed and ignores digits. Esc declines the call in both. Enter is never sent, because it takes whichever option is highlighted. For an agent without known keys the row still shows `Approve: …?`, but `pending` is empty and `answer_permission` returns nothing.
- **Allowlist.** Suggestions write `Bash(<command>)` into `<project>/.claude/settings.local.json`, which only Claude Code reads, so only Claude decisions count.
- **Request lifetime.** Claude Code reports a denied call. Codex has no failure hook, and its `PermissionRequest` has no `tool_use_id`. So for any agent but `claude`, a verified `tool_start`, `tool_done`, `tool_failed` or `tool_ran` from the same thread (the same `agent_id`, or both main) that is not the pending call ends the request as `Superseded`: the prompt is gone and a key from haunt would land in the agent's input. For every agent, `prompt_submit`, `stop` and the user typing into the surface (`on_user_input`) end it too.

## Envelope

Each event is one JSON object. Absent fields are left out rather than sent as `null`. The core ignores fields it doesn't know.

| field | type | required | meaning |
|---|---|---|---|
| `v` | int | yes | `1`. Any other value, or none, is rejected. |
| `agent` | string | yes | an id from the table above |
| `event` | string | yes | an event name below |
| `surface_id` | string | socket | `$HAUNT_SURFACE_ID`. Lines for a surface that isn't registered are dropped. |
| `nonce` | string | socket | `$HAUNT_HOOK_NONCE`, left out when unset |
| `session_id` | string | no | the agent's session or thread id |
| `cwd` | string | no | the agent's working directory. A verified absolute one becomes the row's cwd. |
| `agent_id` | string | no | set when a subagent produced the event; on `subagent_result`, the finished subagent |
| `agent_type` | string | no | the subagent's type or role |
| `permission_mode` | string | no | the agent's own value; the core ignores it today |
| `truncated` | bool | no | `true` if any string was cut |

Tool fields, shared by the tool events:

- `tool_name` (string): the agent's own tool name. Shell commands MUST be named `Bash`, because the core previews and allowlists only `Bash`.
- `tool_use_id` (string): the agent's call id.
- `tool_input` (object): only `command`, `url` and `file_path`, each a string. An adapter MUST NOT send other inputs (edit bodies, patches, prompts to subagents). For a file-editing tool, `file_path` is the absolute path of the first file it touches.

Ids (`task_id` included) are strings and counts are non-negative integers; a value of another type counts as absent. An event that lacks a field marked required below is rejected whole.

## Events

An adapter sends the events its agent can observe and leaves the others out. Within one hook, events MUST come in the order the adapter's README lists. The core needs `tool_start` before `permission_seen` before `tool_ran`.

| event | fields | core effect |
|---|---|---|
| `session_start` | `plugin_version` (the adapter's version); `model`, `source` (ignored) | makes the surface an agent row |
| `prompt_submit` | `query` | new turn: running, the prompt shown, progress reset. Sent for the main thread only. |
| `tool_start` | `tool_name` (required), `tool_use_id`, `tool_input` | running. Verified ones are kept to supply the `tool_use_id` a later `permission_seen` lacks. |
| `permission_seen` | `tool_name` (required), `tool_input` (no `url`), `tool_use_id` if known | needs you. Verified, untruncated and with a `command` or `file_path`: an answerable request. |
| `tool_ran` | `tool_name` (required), `tool_use_id`, `tool_input` (no `url`) | resolves a matching request (answered in the terminal) |
| `tool_done` | `tool_name` (required), `tool_use_id`, `tool_input` | same as `tool_ran` |
| `tool_failed` | `tool_name` (required), `tool_use_id`, `tool_input` | same as `tool_ran` |
| `notification` | `notification_type`, `message` | `permission_prompt`: needs you, without a request. `idle_prompt`: nothing. |
| `question_asked` | none | needs you, status only |
| `question_answered` | `summary` | none yet |
| `task_created` | `task_id` (required), `task_subject` | progress |
| `task_updated` | `task_id`, `task_status` (both required): `pending`, `in_progress`, `completed` or `deleted` | progress |
| `todos_written` | `tool_count` (items), `todos_done` | progress when there are no tasks |
| `plan_exit` | `summary` | none yet |
| `file_edited` | `tool_name`, `tool_input.file_path` | none yet |
| `subagent_spawn` | `agent_type`, `description` | queues a label for the next `subagent_start` of that type |
| `subagent_start` | `agent_id`, `agent_type` | subrow on |
| `subagent_stop` | `agent_id`, `agent_type` | subrow off |
| `subagent_tool` | `agent_id`, `tool_name` (required) | subrow tool count |
| `subagent_result` | `agent_id`, `agent_type`, `description`, `tool_count`, `duration_ms` | final subrow counts |
| `stop` | none | done |
| `stop_failure` | none | failed |

A request resolves when a verified `tool_ran`, `tool_done` or `tool_failed` matches it: on `tool_use_id` when both have one, else on `tool_name` plus the exact `command` or `file_path`. A `truncated` event never matches.

The core passes any other event name through as `EventKind::Unknown` and ignores it. `question_asked` and `stop_failure` are parsed that way too, and `session.rs` acts on their names. A new event is an addition to this spec, not a version bump. A change in what an existing field means is a bump to `v: 2`.

Legacy names, accepted but not part of the spec: the title `warp://cli-agent`, and the official Warp plugin's `permission_request`, `agent_needs_input` (needs you), `permission_replied` and `tool_complete` (leave a needs you that has no request). Adapters MUST NOT send them.

Known wrinkles, kept for v1: `plugin_version` is the adapter's version (`adapter_version` in v2). `tool_count` is todo items on `todos_written` and tool calls on `subagent_result`. `notification_type` values are Claude Code's; other agents SHOULD reuse `permission_prompt` and `idle_prompt` rather than invent new ones. `subagent_spawn.agent_type` MUST equal the `agent_type` the agent later reports on `subagent_start` (Claude Code's default is `general-purpose`, Codex's `default`), because the core matches on it. `plan_exit`, `task_*`, `question_answered` and `subagent_result` come from Claude Code tools and are optional for other agents; Codex reports its `update_plan` as `todos_written`.

## Transport

1. **Gate.** An adapter MUST do nothing unless `HAUNT=1`.
2. **Socket.** If `HAUNT_SOCK` is a Unix socket and `HAUNT_SURFACE_ID` is set, send one line per event, newline-terminated. A line is at most 60,000 bytes; the core discards lines over 64 KB. A line holds no raw control character (JSON escapes only), or the core rejects it. A failed send MUST be dropped, never downgraded to OSC. The core rate-limits each surface to 50 events/s with a burst of 200.
3. **Nonce.** Copy it from the environment; never pass it on a command line or write it anywhere else. An event is verified only when it came over the socket with that surface's nonce (compared in constant time). Only verified events may create a request, set the row's agent or cwd, enter the decision log or count toward an allowlist suggestion.
4. **OSC 777 fallback**, only when there is no socket: `ESC ] 777 ; notify ; haunt://cli-agent ; <body> BEL`. The body is at most 250 bytes and has only `v, agent, event, agent_id, agent_type, task_id, task_status, task_subject, description, tool_name, tool_count, todos_done, notification_type`. It never carries the nonce, cwd, session id, prompt, command or message, and the core treats it as status only. It goes wherever the agent lets it reach the terminal: `/dev/tty`, or Claude Code's `terminalSequence`. An adapter MUST NOT print it to stdout where the agent feeds stdout to the model (Codex).
5. **Sanitising.** Before encoding, remove C0, DEL, C1 and Unicode Cf characters from every string. The core strips them again after decoding (keeping `tool_input` strings raw for the preview, which shows them), and rejects a raw control character anywhere in a body.
6. **Truncation.** Cut, in this order: `tool_input.command`, `tool_input.url`, `tool_input.file_path`, `summary`, `query`, `message`, `description`, `task_subject`, `cwd`. Each cut ends with `…` and sets `truncated: true`. If the line still doesn't fit, send only `{v, agent, event, surface_id, session_id, agent_id, tool_use_id, task_id, tool_name, nonce, truncated}`. If that doesn't fit either, drop the event.
7. **Exit.** Exit 0, print nothing the agent would read as a decision, and never block longer than a 2 s send timeout.

## Examples

One line per event, as an adapter sends it over the socket (`surface_id` and `nonce` left out).

```jsonl
{"v":1,"agent":"claude","event":"session_start","session_id":"s1","cwd":"/w","plugin_version":"0.1.0","model":"opus","source":"startup"}
{"v":1,"agent":"claude","event":"prompt_submit","session_id":"s1","cwd":"/w","query":"fix the bug"}
{"v":1,"agent":"codex","event":"tool_start","session_id":"t1","cwd":"/w","tool_name":"Bash","tool_use_id":"call_1","tool_input":{"command":"git push"}}
{"v":1,"agent":"codex","event":"permission_seen","session_id":"t1","cwd":"/w","tool_name":"Bash","tool_input":{"command":"git push"}}
{"v":1,"agent":"codex","event":"tool_ran","session_id":"t1","cwd":"/w","tool_name":"Bash","tool_use_id":"call_1","tool_input":{"command":"git push"}}
{"v":1,"agent":"codex","event":"tool_done","session_id":"t1","cwd":"/w","tool_name":"Bash","tool_use_id":"call_1","tool_input":{"command":"git push"}}
{"v":1,"agent":"claude","event":"tool_failed","session_id":"s1","tool_name":"Edit","tool_use_id":"tu2","tool_input":{"file_path":"/w/a.rs"}}
{"v":1,"agent":"claude","event":"notification","session_id":"s1","notification_type":"permission_prompt","message":"Claude needs your permission"}
{"v":1,"agent":"codex","event":"question_asked","session_id":"t1"}
{"v":1,"agent":"claude","event":"question_answered","session_id":"s1","summary":"picked option 2"}
{"v":1,"agent":"claude","event":"task_created","session_id":"s1","task_id":"3","task_subject":"Write tests"}
{"v":1,"agent":"claude","event":"task_updated","session_id":"s1","task_id":"3","task_status":"in_progress"}
{"v":1,"agent":"codex","event":"todos_written","session_id":"t1","tool_count":3,"todos_done":1}
{"v":1,"agent":"claude","event":"plan_exit","session_id":"s1","summary":"three steps"}
{"v":1,"agent":"codex","event":"file_edited","session_id":"t1","tool_name":"apply_patch","tool_input":{"file_path":"/w/src/a.rs"}}
{"v":1,"agent":"codex","event":"subagent_spawn","session_id":"t1","agent_type":"default","description":"map_hooks"}
{"v":1,"agent":"codex","event":"subagent_start","session_id":"t1","agent_id":"th2","agent_type":"default"}
{"v":1,"agent":"codex","event":"subagent_tool","session_id":"t1","agent_id":"th2","agent_type":"default","tool_name":"Bash"}
{"v":1,"agent":"claude","event":"subagent_result","session_id":"s1","agent_id":"a1","agent_type":"Explore","description":"trace hooks","tool_count":14,"duration_ms":48000}
{"v":1,"agent":"codex","event":"subagent_stop","session_id":"t1","agent_id":"th2","agent_type":"default"}
{"v":1,"agent":"codex","event":"stop","session_id":"t1","cwd":"/w"}
{"v":1,"agent":"claude","event":"stop_failure","session_id":"s1"}
```
