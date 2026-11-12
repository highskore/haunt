# Haunt {{VERSION}}

A native macOS terminal for running many coding agents at once, built on libghostty, with a Rust core and sandboxed WASM plugins. For macOS 15 or later on Apple silicon.

Built from haunt {{COMMIT}}.

## What's included

- `haunt.app`, with the `haunt` CLI inside it at `haunt.app/Contents/Helpers/haunt`.
{{ADAPTERS}}

Plugins and themes are bundled but not installed. Choose them in the first-launch sheet, in Settings, or with `haunt setup --plugins <names>`.

### Plugins

{{PLUGINS}}

### Themes

The default is black and white with Claude orange. Bundled theme plugins:

{{THEMES}}

## Download

`{{ZIP}}`, sha256 `{{SHA256}}`. Check it with `shasum -a 256 -c {{ZIP}}.sha256`.

{{SIGNED}}.

## Install

Unzip, move `haunt.app` to `/Applications`, and open it from there. `haunt setup` refuses to run from a copy macOS has quarantined and moved aside.
{{GATEKEEPER}}
