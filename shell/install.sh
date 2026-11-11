#!/bin/bash
# Installs the Claude theme and prints the ~/.zshrc lines; never edits ~/.zshrc itself.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$HOME/.claude/themes"
cp "$dir/claude/haunt-theme.json" "$HOME/.claude/themes/haunt.json"
echo "Copied Claude theme to ~/.claude/themes/haunt.json"

cat <<MSG

Add this near the top of ~/.zshrc, above the ASCII-art banner:

  source "$dir/zsh/haunt.zsh"

Then skip the banner inside haunt by adding '! haunt_active' to its condition:

  if [[ \$- == *i* ]] && [ -z "\$TMUX" ] && ! haunt_active; then
MSG
