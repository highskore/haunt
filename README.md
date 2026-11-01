# haunt

A macOS terminal for running many Claude Code agents side by side. It embeds
libghostty for the terminal, keeps its model in a UI-free Rust core
(`core/`, exposed to Swift through UniFFI in `ffi/`) and runs plugins as
sandboxed WASM components (wasmtime, `wit/haunt-plugin.wit`).

Status: Phase 0 spike. See `docs/spike-report.md`.

## Layout

- `core/` haunt-core: OSC event parser, plugin host
- `ffi/` haunt-ffi: UniFFI bindings for Swift
- `wit/` plugin API
- `examples/hello/` minimal WASM plugin
- `macos/` Swift app, `macos/deps/` built libghostty
- `scripts/` build scripts (`update-ghostty.sh` is the only Zig user)

Licence: MIT. See `NOTICE` for Ghostty.
