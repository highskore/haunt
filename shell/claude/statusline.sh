#!/bin/bash
# Runs the user's normal Claude status line, recoloured to haunt's greys (cyan becomes the bright grey).
input=$(cat)
cmd=$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)
[ -z "$cmd" ] && exit 0
printf '%s' "$input" | bash -c "$cmd" \
  | sed -E $'s/\x1b\\[36m/\x1b[38;2;232;232;232m/g; s/\x1b\\[3[0-7]m/\x1b[38;2;111;111;111m/g'
