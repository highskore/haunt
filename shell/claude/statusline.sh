#!/bin/bash
# Runs the user's normal Claude status line (statusLine.command in ~/.claude/settings.json),
# recoloured to haunt's greys (cyan becomes the bright grey).
settings=$HOME/.claude/settings.json
stamp=$(stat -f '%i %Fm %z' "$settings" 2>/dev/null) || exit 0
# The command, cached per settings file version in the private per-user TMPDIR, so a refresh runs no jq.
cache=${TMPDIR:+${TMPDIR%/}/haunt-statusline.$UID}
cmd=
if [ -n "$cache" ] && [ -f "$cache" ] && [ ! -L "$cache" ] && [ -O "$cache" ] \
  && { IFS= read -r first && IFS= read -r -d '' cmd; [ "$first" = "$stamp" ]; } < "$cache"; then
  :
else
  cmd=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null)
  if [ -n "$cache" ] && tmp=$(mktemp "$cache.XXXXXX" 2>/dev/null); then
    printf '%s\n%s' "$stamp" "$cmd" > "$tmp" && mv -f "$tmp" "$cache" || rm -f "$tmp"
  fi
fi
[ -n "$cmd" ] || exit 0
bash -c "$cmd" \
  | sed -E $'s/\x1b\\[36m/\x1b[38;2;232;232;232m/g; s/\x1b\\[3[0-7]m/\x1b[38;2;111;111;111m/g'
