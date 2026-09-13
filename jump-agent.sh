#!/usr/bin/env bash
set -uo pipefail

pane_id=${1-}
session_name=${2-}
window_index=${3-0}
pane_index=${4-0}

fail() {
  notify-send --app-name=omalchemy --urgency=normal \
    "Unable to open agent" "$1" >/dev/null 2>&1 || true
  printf 'midas.omalchemy: %s\n' "$1" >&2
  exit 1
}

command -v tmux >/dev/null 2>&1 || fail "tmux is not installed"
[[ -n $session_name ]] || fail "The state row has no tmux session"
tmux has-session -t "$session_name" 2>/dev/null || fail "tmux session no longer exists: $session_name"

target="${session_name}:${window_index}.${pane_index}"
if [[ -n $pane_id ]]; then
  pane_session=$(tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null || true)
  [[ $pane_session == "$session_name" ]] && target=$pane_id
fi

# Prefer the client already showing this session. Otherwise reuse the most
# recently active tmux client, avoiding a new terminal for every panel click.
client_tty=
client_pid=
client_activity=-1
fallback_tty=
fallback_pid=
fallback_activity=-1
while IFS=$'\t' read -r tty pid activity current_session; do
  [[ -n $tty && $pid =~ ^[0-9]+$ ]] || continue
  [[ $activity =~ ^[0-9]+$ ]] || activity=0
  if (( activity > fallback_activity )); then
    fallback_tty=$tty
    fallback_pid=$pid
    fallback_activity=$activity
  fi
  if [[ $current_session == "$session_name" && $activity -gt $client_activity ]]; then
    client_tty=$tty
    client_pid=$pid
    client_activity=$activity
  fi
done < <(tmux list-clients -F $'#{client_tty}\t#{client_pid}\t#{client_activity}\t#{session_name}' 2>/dev/null || true)

if [[ -z $client_tty ]]; then
  client_tty=$fallback_tty
  client_pid=$fallback_pid
fi

if [[ -z $client_tty ]]; then
  command -v omarchy-launch-terminal >/dev/null 2>&1 \
    || fail "No attached tmux client and no terminal launcher found"
  omarchy-launch-terminal tmux attach-session -t "$target" >/dev/null 2>&1 &
  exit 0
fi

tmux switch-client -c "$client_tty" -t "$target" 2>/dev/null \
  || fail "Could not switch a tmux client to $session_name"

# Focus the exact terminal containing that tmux client. The tmux client is a
# descendant of the compositor window's process on ordinary terminal setups.
if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [[ $client_pid =~ ^[0-9]+$ ]]; then
  declare -A ancestors=()
  pid=$client_pid
  while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    ancestors[$pid]=1
    [[ -r /proc/$pid/stat ]] || break
    parent=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || true)
    [[ $parent =~ ^[0-9]+$ && $parent != "$pid" ]] || break
    pid=$parent
  done

  while IFS=$'\t' read -r window_pid address; do
    if [[ -n ${ancestors[$window_pid]+x} && -n $address ]]; then
      hyprctl dispatch focuswindow "address:$address" >/dev/null 2>&1 || true
      break
    fi
  done < <(hyprctl -j clients 2>/dev/null | jq -r '.[] | [.pid, .address] | @tsv' 2>/dev/null)
fi
