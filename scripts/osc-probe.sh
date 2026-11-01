#!/bin/bash
# Run inside a haunt surface: emits the hook plugin's real sequences, then OSC 777 bodies of growing size.
set -u
HOOK="${HOOK:-$HOME/code/haunt-reference/pawr/code/pawr/claude-plugin/scripts/qs-hook.sh}"
export WARP_CLI_AGENT_PROTOCOL_VERSION=1
base='"session_id":"probe","cwd":"/tmp/probe","hook_event_name":"x"'
mark() { printf '\033]777;notify;probe-mark;%s\007' "$1"; sleep 1.1; }

hooks() {
  echo "{$base,\"task_id\":7,\"task_subject\":\"write the parser\"}" | bash "$HOOK" task_created; sleep "$1"
  echo "{$base,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"Explore\",\"description\":\"map the repo\"}}" | bash "$HOOK" pre_tool; sleep "$1"
  echo "{$base,\"tool_name\":\"TaskUpdate\",\"tool_input\":{\"taskId\":\"7\",\"status\":\"completed\"}}" | bash "$HOOK" post_tool; sleep "$1"
  echo "{$base,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cargo test -p haunt-core\"}}" | bash "$HOOK" post_tool; sleep "$1"
  echo "{$base,\"agent_id\":\"a1\",\"agent_type\":\"Explore\"}" | bash "$HOOK" subagent_start; sleep "$1"
  echo "{$base,\"agent_id\":\"a1\",\"agent_type\":\"Explore\"}" | bash "$HOOK" subagent_stop; sleep "$1"
}

# 1. Burst, as Claude Code fires them: 6 hook calls, 8 sequences.
mark burst; hooks 0; sleep 1.1
# 2. Same calls spaced past Ghostty's 1/s notification limit.
mark spaced; hooks 1.1

# 3. Sizes; body length is exact and ends in END!",...
mark sizes
for n in 200 250 255 256 300 1000 1500 2048 2100 4096 65536; do
  # Size first, so truncated bodies still differ (Ghostty drops identical ones within 5 s).
  head="{\"size\":$n,\"v\":1,\"agent\":\"claude\",\"session_id\":\"size\",\"event\":\"plan_exit\",\"summary\":\""
  tail='"}'
  pad=$(( n - ${#head} - ${#tail} - 4 ))
  body="$head$(printf 'x%.0s' $(seq 1 $pad))END!$tail"
  printf '\033]777;notify;warp://cli-agent;%s\007' "$body"
  sleep 1.1
done
mark done
echo "probe done"
