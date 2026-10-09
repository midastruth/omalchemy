#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=server.sh
. "$SCRIPT_DIR/server.sh"

pane_id=${3-}
if [[ ! "$pane_id" =~ ^%[0-9]+$ ]]; then
  printf 'midas.omalchemy: Seen requires an immutable pane identity\n' >&2
  exit 1
fi
if ! bind_tmux_server "${1-}" "${2-}"; then
  exit 1
fi
if ! daemon_binary=$(tmux_server show-option -gqv @agent_daemon_binary); then
  exit 1
fi
if [[ -z "$daemon_binary" ]]; then
  exit 0
fi
if [[ ! -x "$daemon_binary" ]]; then
  printf 'midas.omalchemy: configured Argos daemon is not executable\n' >&2
  exit 1
fi
if ! actual_pid=$(tmux_server display-message -p '#{pid}'); then
  exit 1
fi
if [[ "$actual_pid" != "$server_pid" ]]; then
  printf 'midas.omalchemy: server restarted before Seen\n' >&2
  exit 1
fi
printf -v request '{"type":"Seen","pane_id":"%s"}' "$pane_id"
if ! TMUX="$server_socket,$server_pid,0" "$daemon_binary" send "$request"; then
  printf 'midas.omalchemy: Seen failed on its original server\n' >&2
  exit 1
fi
