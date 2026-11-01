# haunt shell setup

Makes zsh and Claude Code look like haunt when running inside it. Every piece is gated on `HAUNT=1`, which haunt sets in its shells; in any other terminal the snippet returns immediately.

## Install

```sh
./shell/install.sh
```

It copies the Claude theme to `~/.claude/themes/haunt.json` and prints the lines to add to `~/.zshrc`. It does not edit `~/.zshrc`.

1. Source the snippet near the top of `~/.zshrc`, above the banner:

   ```sh
   source /path/to/haunt/shell/zsh/haunt.zsh
   ```

2. Skip the ASCII-art banner inside haunt by adding `! haunt_active` to its condition:

   ```sh
   if [[ $- == *i* ]] && [ -z "$TMUX" ] && ! haunt_active; then
   ```

`haunt_active` is defined in every shell, so the banner condition works outside haunt too.

## What it does inside haunt

| Piece | Effect |
| --- | --- |
| `zsh/haunt.zsh` | Defines `haunt_active`; points `STARSHIP_CONFIG` at `starship.toml`; clears `ZSH_HIGHLIGHT_HIGHLIGHTERS` before the first prompt so commands are plain white; aliases `claude` to pass `--settings` with the haunt theme and status line. |
| `starship.toml` | Minimal prompt: dim `#6f6f6f` path and branch, `❯` in `#e8e8e8` on the next line. |
| `claude/haunt-theme.json` | Claude Code custom theme `custom:haunt`: greys with Claude orange. |
| `claude/statusline.sh` | Runs your normal `statusLine.command` from `~/.claude/settings.json` and recolours it to greys. |

The highlighters are cleared from a one-shot `precmd` hook because zsh-syntax-highlighting resets an empty list to `(main)` each time it is sourced.
