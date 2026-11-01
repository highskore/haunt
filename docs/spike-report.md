# Phase 0 spike report

2026-11-01. Ghostty v1.4.0 @ `83fb956`, Zig 0.17.0, Xcode 16.3 (Swift 6.1, macOS 15.4 SDK), macOS 15.6, Apple Silicon (10 cores).

Timings were taken while other sessions kept the machine at load average 30+ on 10 cores; treat them as upper bounds (roughly 2–3x a quiet machine).

## Answers

| question | answer | numbers |
|---|---|---|
| Toolchain works on Xcode 16.3? | **Yes**, with 4 small vendor patches | see below |
| libghostty builds from official source? | **Yes** | 531 s Zig build (incl. dependency fetch); `libghostty.a` 26.5 MB stripped (`strip -S`); `_ghostty_init` present |
| Bare window + one surface + login shell? | **Yes** | `docs/spike/window-1.png`: zsh login shell with the user's prompt, Metal rendering, cursor |
| UniFFI core reachable from Swift? | **Yes** | `parseOsc` / `PluginHandle` called from the app |
| Hook events via `DESKTOP_NOTIFICATION`? | **Partly. Blocker.** | 255-byte body cap, 1 notification/s app-wide, OSC > ~2 KB dropped |
| wasmtime component plugin? | **Yes** | +13.6 MB stripped; 44 ms cold compile, 0.8 ms cached load, ~30 µs per event |

## Toolchain on Xcode 16.3

Zig needs nothing from Xcode beyond the SDK. The vendored Ghostty Swift wrapper (`macos/Sources/Ghostty` plus 37 helper files, copied by `macos/vendor.sh`) compiles on Swift 6.1 once 4 patches are applied, all in `vendor.sh`:

1. `UUID(CFUUID)` is missing from the 15.4 SDK. Shim in `macos/Sources/Compat.swift`.
2. `Glass` (macOS 26 SDK): wrapped in `#if compiler(>=6.2)` in `Backport.swift`.
3. `ConcentricRectangle` (macOS 26 SDK): same guard in `SurfaceView.swift`, falling back to `RoundedRectangle`.
4. `"\(x, default: "?")"` interpolation is Swift 6.2 (SE-0477). Rewritten as `x.map(String.init) ?? "?"`.

Two more files had to be vendored beyond Gutter's list (`KeyboardShortcut+Extension.swift`, `NSWorkspace+Extension.swift`). Gutter shims those instead because it builds with the Command Line Tools. The indices-based `ForEach` patch Gutter needs for the Swift 6.3 type-checker is applied too.

Verdict: **stay on Xcode 16.3** for now. Xcode 26 would drop patches 1–4, and the guards are written so they become no-ops there.

Zig build note: libtool printed `duplicate member name 'ext.o'` and a "failed command" line, but `zig build` exited 0 and the library links and runs. Gutter documents a related archive-alignment bug on Xcode 26's libtool. Check again on the next bump.

## Build times and sizes

| step | time |
|---|---|
| `scripts/update-ghostty.sh` (Zig, ReleaseFast, native xcframework; first run, includes fetching Zig packages) | 531 s |
| Rust core clean (`haunt-ffi` release, wasmtime, thin LTO, cgu=1) + bindgen + hello plugin | 195 s |
| Rust core incremental (touch `event.rs`) | 80 s (LTO bound; a dev profile without LTO would fix it) |
| Swift `-O` clean (single `swiftc` invocation, 70 files + 2 UniFFI files) | 54 s |
| Swift `-O` after touching one file | 45 s (no incremental: one `swiftc` call recompiles everything) |
| Swift `-Onone` | 38 s |
| `macos/typecheck.sh` (needs no `libghostty.a`) | 25 s |
| hello plugin (`wasm32-wasip2`, release, first build) | 14 s |

Real incremental Swift builds need the plan's xcodegen project (or `swiftc -incremental` with an output file map). Today every Swift change costs about 45 s.

| artefact | size |
|---|---|
| `build/haunt.app` | 37 MB |
| `Contents/MacOS/Haunt` (stripped `-x`) | 34 MB, of which wasmtime is about 13.6 MB (measured on a Swift smoke binary with and without the `plugins` feature: 15 MB vs 1.4 MB stripped) |
| `Resources/ghostty` (themes + shell integration) | 3.3 MB |
| `macos/deps/` committed (lib + headers + share trimmed to shell-integration, themes, terminfo) | 29 MB |
| hello plugin component | 50.6 KB; 207 KB serialised `.cwasm` |

## Disk used

All inside `~/code/haunt` unless noted.

| path | size |
|---|---|
| `.toolchain/` (Zig 419 MB + tarball 51 MB) | 470 MB |
| `deps-src/ghostty` (shallow clone + `zig-out` + xcframework) | 653 MB |
| `deps-src/gutter` (reference source only) | 51 MB |
| `.cache/` (Zig local cache 1.0 GB, global 149 MB, install prefix 20 MB) | 1.2 GB |
| `target/release` (debug dir removed after use; it was 2.5 GB) | 1.3 GB |
| `examples/hello/target` | 128 MB |
| `build/` (bindings, smoke binaries, app) | 133 MB |
| `.git` | 17 MB |
| **total in repo dir** | about 4 GB now; 6.5 GB at peak |
| outside: `~/.rustup/toolchains/1.98.0-aarch64-apple-darwin`, created by the `rust-toolchain.toml` pin (a duplicate of `stable`, which is also 1.98.0), including the `wasm32-wasip2` target (103 MB) | 1.4 GB |
| outside: crates in `~/.cargo/registry` | not measured separately |
| outside: `~/.haunt/` (logs, plugin cache) | 208 KB |

Safe to delete when space is short: `.cache/zig-local` (rebuilt on the next Ghostty bump) and `target/`.

## OSC 777 findings (blocker)

I measured this in the running app with `scripts/osc-probe.sh`, typed into the surface's pty through `SurfaceConfiguration.initialInput` (no GUI automation). The raw log is in `docs/spike/probe-events.log`. The probe runs the real `qs-hook.sh` (copy at `~/code/haunt-reference/pawr/code/pawr/claude-plugin/scripts/`) and then bodies of fixed sizes.

All three limits live in Ghostty core (Zig), not the Swift wrapper, so we can't patch them away in `Vendor/`:

1. **Fixed-size payload.** `apprt/surface.zig` `DesktopNotification { title: [63:0]u8, body: [255:0]u8 }`. Bodies are cut at 255 bytes (on a UTF-8 boundary) without warning. Measured: 200, 250 and 255 bytes arrive intact. 256, 300, 1,000 and 1,500 arrive as exactly 255 bytes, which then fail JSON parsing.
2. **Rate limit.** `Surface.zig` `showDesktopNotification` allows one notification per second **per app** and drops identical title+body within 5 s. Measured: in a burst of 6 hook calls (8 sequences), only the first arrived. Spaced 1.1 s apart, all 6 calls arrived, but only the first sequence of each multi-sequence call (`pre_tool` for Agent emits `tool_start` + `subagent_spawn`; the second is lost).
3. **OSC length.** A whole OSC over about 2,048 bytes never reaches the action callback. Bodies of 2,048, 2,100, 4,096 and 65,536 bytes produced nothing; 1,500 (plus the 24-byte `notify;warp://cli-agent;` prefix) did arrive, truncated as in 1.

Real hook bodies today are 168–249 bytes, so size alone is borderline. The rate limit makes OSC 777 unusable as the primary transport: Claude Code fires several hooks per second during tool use.

**Needs a decision.** Recommended: bring the plan's Phase 3 Unix-socket intake (`~/.haunt/sock`, events carrying `HAUNT_SURFACE_ID` + nonce) forward to Phase 1 as the hook transport. Keep OSC 777 as a status-only fallback for the official Warp plugin. That needs zero Ghostty patches. The alternative, a Ghostty patch (bigger body, rate-limit exemption for the `cli-agent` title), breaks the zero-fork rule. Growing the body array also grows every surface mailbox message, so upstream is unlikely to take it.

What did work end to end: OSC 777 → libghostty → `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` → a one-line `desktopNotificationHook` patch in the vendored `Ghostty.App.swift` → `HauntBridge` → Rust `parse_osc` (UniFFI) → WASM plugin `on-event` → decoration back in Swift. The event is swallowed so no macOS notification appears. Non-agent titles fall through to Ghostty's normal notification path.

## UniFFI ergonomics

Good. The core types carry `#[cfg_attr(feature = "ffi", derive(uniffi::Record/Enum/Error))]`. `EventKind` (an enum with payloads), `Option`, `Result` with a typed error, and an `Object` with a constructor (`PluginHandle.load`) all come out as idiomatic Swift (`EventKind.taskCreated(taskId:subject:)`, `catch ParseError.NotAgentTitle`). Costs found:

- Two crates using UniFFI (`haunt-core` with derives, `haunt-ffi` with exports) generate two Swift files and two C headers. Compiled into one Swift module they don't clash, but they need a combined modulemap (written by `scripts/build-core.sh`).
- Library-mode bindgen works on the `.a` directly. The bindings must be regenerated whenever features change; a feature mismatch only shows up as link errors.
- The generated Swift is about 2,000 lines for this tiny API, which is fine.
- `wasmtime::Store` isn't `Sync`, so the exported object wraps it in a `Mutex`.

## wasmtime

- WIT sketch `wit/haunt-plugin.wit` (`haunt:plugin@0.1.0`: `on-event(agent-event) -> option<decoration>`, import `log`). The hello plugin is in `examples/hello/` (wit-bindgen 0.63, `wasm32-wasip2`).
- `wasm32-wasip2` std components import WASI (`wasi:io/poll` etc.) even when they use none of it. The host links `wasmtime-wasi` p2 with an empty `WasiCtx` (no dirs, env or sockets), as the plan intends.
- Binary cost: about 13.6 MB stripped (wasmtime 50 with cranelift, component-model and runtime, plus wasmtime-wasi p2). The plan's target was under 25 MB: **met**.
- Load: cold compile 40–45 ms for a 50 KB component (target under 300 ms: **met**). Cached load via our own `Component::serialize` → `deserialize_file` keyed on wasm hash + engine compatibility hash: 0.3–2 ms. Instantiate 0.2–0.5 ms. `on-event` call 24–37 µs. Larger real plugins will compile roughly in proportion to size; this hasn't been measured yet.
- Engine creation is under 1 ms.

## Not done / deviations

- **Signing**: the bundle is signed ad hoc. The plan wants a self-signed "haunt Dev" certificate, but creating one changes the login keychain, so it is left to the user. `make-app.sh` picks the certificate up automatically once it exists.
- **⌘Q**: the menu item exists. It was exercised through an AppleScript `quit` event, not a keystroke (no GUI keystroke automation).
- **Real `claude` run in the surface**: not done (needs interactive use). Colours, mouse and IME are therefore unverified beyond the prompt rendering in the screenshot.
- **Self-built vs Gutter**: per the instruction, nothing from Gutter's committed binaries or `Vendor/` was used. `vendor.sh` copies from our own Ghostty checkout, and the shims follow Gutter's shapes (credited in the files).
- `rust-toolchain.toml` pins `1.98.0`, which made rustup install a second copy of the toolchain (1.4 GB) next to `stable`. Pinning `stable` would avoid that at the cost of reproducibility.

## Blockers

1. **OSC 777 transport** (above): decide between bringing the socket intake forward (recommended) and patching Ghostty.
2. None for the toolchain. Xcode 26 isn't required.
