#!/usr/bin/env bash
set -uo pipefail

session_name=${1-}
[[ -n $session_name ]] || exit 1

mark_popup_inactive() {
  tmux set-option -u -t "$session_name" @agent_popup_active 2>/dev/null || true
}
trap mark_popup_inactive EXIT HUP INT TERM

tmux attach-session -t "$session_name"
