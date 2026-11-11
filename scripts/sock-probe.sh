#!/bin/bash
# Run inside a haunt surface: real hook bodies, a burst, a large body and forgeries over $HAUNT_SOCK.
set -u
HOOK="${HAUNT_CLAUDE_ADAPTER:-$(cd "$(dirname "$0")/../.." && pwd)/haunt-plugins/haunt-claude}/scripts/haunt-hook.sh"
TMP=$(mktemp -d)
base='"session_id":"probe","cwd":"/tmp/probe","hook_event_name":"x"'

# The hook writes OSC sequences to HAUNT_HOOK_TTY; split them back into bodies and tag the surface.
bodies() {
  HAUNT_HOOK_TTY="$TMP/tty" bash "$HOOK" "$1" >/dev/null
  tr '\007' '\n' < "$TMP/tty" | sed 's/^.*haunt:\/\/cli-agent;//' | grep -v '^$' \
    | jq -c --arg s "$HAUNT_SURFACE_ID" '. + {surface_id:$s}'
  rm -f "$TMP/tty"
}
send() { nc -U "$HAUNT_SOCK"; }

{
  echo "{$base,\"task_id\":7,\"task_subject\":\"write the parser\"}" | bodies task_created
  echo "{$base,\"tool_name\":\"Agent\",\"tool_use_id\":\"t1\",\"tool_input\":{\"subagent_type\":\"Explore\",\"description\":\"map the repo\"}}" | bodies pre_tool
  echo "{$base,\"tool_name\":\"TaskUpdate\",\"tool_input\":{\"taskId\":\"7\",\"status\":\"completed\"}}" | bodies post_tool
  echo "{$base,\"agent_id\":\"a1\",\"agent_type\":\"Explore\"}" | bodies subagent_start
} | send
echo "hooks sent"

# Burst: 300 events in one connection; the default bucket is 200 burst + 50/s.
for i in $(seq 1 300); do
  echo "{\"v\":1,\"event\":\"tool_ran\",\"tool_name\":\"Read\",\"surface_id\":\"$HAUNT_SURFACE_ID\",\"nonce\":\"$HAUNT_HOOK_NONCE\",\"i\":$i}"
done | send
sleep 1
# 10 KB body (OSC would drop it) and a 100 KB line (over the 64 KB cap), then forgeries.
big=$(printf 'x%.0s' $(seq 1 10000))
huge=$(printf 'x%.0s' $(seq 1 100000))
{
  echo "{\"v\":1,\"event\":\"plan_exit\",\"summary\":\"$big\",\"surface_id\":\"$HAUNT_SURFACE_ID\",\"nonce\":\"$HAUNT_HOOK_NONCE\"}"
  echo "{\"v\":1,\"event\":\"plan_exit\",\"summary\":\"$huge\",\"surface_id\":\"$HAUNT_SURFACE_ID\"}"
  echo "{\"v\":1,\"event\":\"stop\",\"surface_id\":\"$HAUNT_SURFACE_ID\",\"nonce\":\"forged\"}"
  echo "{\"v\":1,\"event\":\"stop\",\"surface_id\":\"$HAUNT_SURFACE_ID\"}"
} | send
rm -rf "$TMP"
echo "sock probe done"
