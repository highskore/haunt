# haunt shell setup. Source near the top of ~/.zshrc; does nothing outside haunt.

haunt_active() { [[ $HAUNT == 1 ]] }

haunt_active || return 0

# p10k's cached instant prompt would flash its coloured prompt before starship takes over.
typeset -g POWERLEVEL9K_INSTANT_PROMPT=off

typeset -g HAUNT_SHELL_DIR=${${(%):-%x}:A:h:h}

export STARSHIP_CONFIG=$HAUNT_SHELL_DIR/starship.toml

alias claude="command claude --settings '{\"theme\":\"custom:haunt\",\"statusLine\":{\"type\":\"command\",\"command\":\"$HAUNT_SHELL_DIR/claude/statusline.sh\"}}'"

# zsh-syntax-highlighting resets an empty list to (main) when sourced, so clear it once the first prompt is about to draw.
_haunt_plain_commands() {
  ZSH_HIGHLIGHT_HIGHLIGHTERS=()
  add-zsh-hook -d precmd _haunt_plain_commands
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _haunt_plain_commands
