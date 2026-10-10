#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=server.sh
. "$SCRIPT_DIR/server.sh"

pane_id=${3-}
session_id=${4-}
# Desktop launchers may expand dollar-prefixed argv through systemd-run.
# Accept the numeric transport form as well as the original immutable ID.
if [[ $session_id =~ ^[0-9]+$ ]]; then
  session_id="\$$session_id"
fi
if [[ ! "$pane_id" =~ ^%[0-9]+$ || ! "$session_id" =~ ^\$[0-9]+$ ]]; then
  printf 'midas.omalchemy: attachment requires immutable pane/session IDs\n' >&2
  exit 1
fi
# Terminal launch is asynchronous. Revalidate here, not just in jump-agent.
if ! bind_tmux_server "${1-}" "${2-}"; then
  exit 1
fi
if ! actual_session=$(tmux_server display-message -p -t "$pane_id" '#{session_id}'); then
  exit 1
fi
if [[ "$actual_session" != "$session_id" ]]; then
  printf 'midas.omalchemy: pane disappeared or changed session before attachment\n' >&2
  exit 1
fi
printf -v seen_command '%q %q %q %q %q' bash "$SCRIPT_DIR/seen-agent.sh" "$server_socket" "$server_pid" "$pane_id"
if ! tmux_server attach-session -t "$pane_id" \; run-shell -b "$seen_command"; then
  exit 1
fi
