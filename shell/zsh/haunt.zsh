# haunt shell setup. Source near the top of ~/.zshrc; does nothing outside haunt.

haunt_active() { [[ $HAUNT == 1 ]] }

haunt_active || return 0

# p10k's cached instant prompt would flash its coloured prompt before starship takes over.
typeset -g POWERLEVEL9K_INSTANT_PROMPT=off

typeset -g HAUNT_SHELL_DIR=${${(%):-%x}:A:h:h}

export STARSHIP_CONFIG=$HAUNT_SHELL_DIR/starship.toml

# Your own status line command, read once per shell so a refresh runs no jq.
export HAUNT_USER_STATUSLINE=$(jq -r '.statusLine.command // empty' ~/.claude/settings.json 2>/dev/null)
if [[ -n $HAUNT_USER_STATUSLINE ]]; then
  alias claude="command claude --settings '{\"theme\":\"custom:haunt\",\"statusLine\":{\"type\":\"command\",\"command\":\"$HAUNT_SHELL_DIR/claude/statusline.sh\"}}'"
else
  alias claude="command claude --settings '{\"theme\":\"custom:haunt\"}'"
fi

# zsh-syntax-highlighting resets an empty list to (main) when sourced, so clear it once the first prompt is about to draw.
_haunt_plain_commands() {
  ZSH_HIGHLIGHT_HIGHLIGHTERS=()
  # p10k rebuilds PROMPT in its own precmd, overriding starship; drop it and keep starship's prompt.
  if (( $+functions[_p9k_precmd] )); then
    (( $+functions[prompt_powerlevel10k_teardown] )) && prompt_powerlevel10k_teardown
    _p9k_precmd() { : }
    (( $+commands[starship] )) && eval "$(starship init zsh)"
  fi
  add-zsh-hook -d precmd _haunt_plain_commands
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _haunt_plain_commands
