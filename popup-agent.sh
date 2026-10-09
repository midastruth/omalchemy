#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=server.sh
. "$SCRIPT_DIR/server.sh"

selected_socket=${1-}
expected_server_pid=${2-}
session_id=${3-}
if [[ ! "$session_id" =~ ^\$[0-9]+$ ]]; then
  printf 'midas.omalchemy: popup requires an immutable session identity\n' >&2
  exit 1
fi
if ! bind_tmux_server "$selected_socket" "$expected_server_pid"; then
  exit 1
fi

mark_popup_inactive() {
  # The queue guard refuses cleanup on a same-socket replacement server.
  if ! tmux_server set-option -u -t "$session_id" @agent_popup_active; then
    printf 'midas.omalchemy: could not clear popup state on its original server\n' >&2
    return 1
  fi
}
trap mark_popup_inactive EXIT HUP INT TERM

if ! tmux_server attach-session -t "$session_id"; then
  exit 1
fi
