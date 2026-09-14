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

# Resolve compositor windows before choosing a tmux client. A session may also
# be attached through SSH; switching that client succeeds but cannot bring a
# desktop window into view.
hypr_available=false
declare -A hypr_address_by_pid=()
declare -A hypr_workspace_id_by_pid=()
declare -A hypr_workspace_name_by_pid=()
if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  hypr_clients=$(hyprctl -j clients 2>/dev/null || true)
  if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$hypr_clients"; then
    hypr_available=true
    while IFS=$'\t' read -r window_pid address workspace_id workspace_name; do
      [[ $window_pid =~ ^[0-9]+$ && -n $address ]] || continue
      hypr_address_by_pid[$window_pid]=$address
      hypr_workspace_id_by_pid[$window_pid]=$workspace_id
      hypr_workspace_name_by_pid[$window_pid]=$workspace_name
    done < <(jq -r '.[] | [.pid, .address, .workspace.id, .workspace.name] | @tsv' <<<"$hypr_clients")
  fi
fi

window_address=
window_workspace_id=
window_workspace_name=
find_hypr_window() {
  local process_pid=$1 parent
  window_address=
  window_workspace_id=
  window_workspace_name=

  while [[ $process_pid =~ ^[0-9]+$ ]] && (( process_pid > 1 )); do
    if [[ -n ${hypr_address_by_pid[$process_pid]+x} ]]; then
      window_address=${hypr_address_by_pid[$process_pid]}
      window_workspace_id=${hypr_workspace_id_by_pid[$process_pid]}
      window_workspace_name=${hypr_workspace_name_by_pid[$process_pid]}
      return 0
    fi
    [[ -r /proc/$process_pid/status ]] || break
    # /proc/<pid>/stat cannot be split safely because process names may
    # contain spaces (tmux uses "tmux: client").
    parent=$(awk '/^PPid:/ { print $2; exit }' "/proc/$process_pid/status" 2>/dev/null || true)
    [[ $parent =~ ^[0-9]+$ && $parent != "$process_pid" ]] || break
    process_pid=$parent
  done
  return 1
}

# Prefer the graphical client already displaying the target pane, then one in
# the target session, then another graphical tmux client. Headless clients are
# only eligible outside Hyprland, where there is no desktop window to focus.
target_pane_id=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || true)
client_tty=
client_activity=-1
client_priority=-1
client_address=
client_workspace_id=
client_workspace_name=
while IFS=$'\t' read -r tty pid activity current_session current_pane; do
  [[ -n $tty && $pid =~ ^[0-9]+$ ]] || continue
  [[ $activity =~ ^[0-9]+$ ]] || activity=0

  candidate_address=
  candidate_workspace_id=
  candidate_workspace_name=
  if $hypr_available; then
    find_hypr_window "$pid" || continue
    candidate_address=$window_address
    candidate_workspace_id=$window_workspace_id
    candidate_workspace_name=$window_workspace_name
  fi

  priority=0
  [[ $current_session == "$session_name" ]] && priority=1
  [[ -n $target_pane_id && $current_pane == "$target_pane_id" ]] && priority=2
  if (( priority > client_priority || (priority == client_priority && activity > client_activity) )); then
    client_tty=$tty
    client_activity=$activity
    client_priority=$priority
    client_address=$candidate_address
    client_workspace_id=$candidate_workspace_id
    client_workspace_name=$candidate_workspace_name
  fi
done < <(tmux list-clients -F $'#{client_tty}\t#{client_pid}\t#{client_activity}\t#{session_name}\t#{pane_id}' 2>/dev/null || true)

if [[ -z $client_tty ]]; then
  command -v omarchy-launch-terminal >/dev/null 2>&1 \
    || fail "No desktop tmux client and no terminal launcher found"
  omarchy-launch-terminal tmux attach-session -t "$target" >/dev/null 2>&1 &
  exit 0
fi

tmux switch-client -c "$client_tty" -t "$target" 2>/dev/null \
  || fail "Could not switch a tmux client to $session_name"

if $hypr_available && [[ -n $client_address ]]; then
  # Hyprland 0.56 dispatches Lua actions. Try that API first, while keeping
  # legacy dispatchers as fallbacks for older releases.
  workspace_target=
  if [[ $client_workspace_id =~ ^[0-9]+$ ]]; then
    workspace_target=$client_workspace_id
  elif [[ -n $client_workspace_name && $client_workspace_name != special:* ]]; then
    workspace_target="name:$client_workspace_name"
  fi
  if [[ -n $workspace_target ]]; then
    workspace_lua=$(jq -n --arg value "$workspace_target" '$value')
    hyprctl dispatch "hl.dsp.focus({ workspace = $workspace_lua })" >/dev/null 2>&1 \
      || hyprctl dispatch workspace "$workspace_target" >/dev/null 2>&1 \
      || true
  fi

  # Address is not a supported get_windows filter in Hyprland 0.56. Walk the
  # returned windows and pass the matching window object to the focus action.
  # Raise an error when it disappeared so the legacy fallback is attempted.
  address_lua=$(jq -n --arg value "$client_address" '$value')
  focus_lua="local address = $address_lua; for _, window in ipairs(hl.get_windows({})) do if window.address == address then hl.dispatch(hl.dsp.focus({ window = window })); return end end; error('window not found: ' .. address)"
  hyprctl eval "$focus_lua" >/dev/null 2>&1 \
    || hyprctl dispatch focuswindow "address:$client_address" >/dev/null 2>&1 \
    || true
fi
