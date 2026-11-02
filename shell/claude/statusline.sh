#!/bin/bash
# Runs the user's normal Claude status line (HAUNT_USER_STATUSLINE, set by haunt.zsh), recoloured
# to haunt's greys (cyan becomes the bright grey).
[ -n "${HAUNT_USER_STATUSLINE:-}" ] || exit 0
bash -c "$HAUNT_USER_STATUSLINE" \
  | sed -E $'s/\x1b\\[36m/\x1b[38;2;232;232;232m/g; s/\x1b\\[3[0-7]m/\x1b[38;2;111;111;111m/g'
