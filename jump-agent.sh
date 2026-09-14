#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pane_id=${1-}
session_name=${2-}
window_index=${3-0}
pane_index=${4-0}
popup_host_client=${5-}
popup_host_session_id=${6-}
popup_host_window_id=${7-}
popup_host_pane_id=${8-}
popup_active_from_state=${9-false}

popup_host_valid=false
if [[ -n $popup_host_client && $popup_host_session_id =~ ^\$[0-9]+$ &&
  $popup_host_window_id =~ ^@[0-9]+$ && $popup_host_pane_id =~ ^%[0-9]+$ ]]; then
  popup_host_valid=true
fi

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

popup_active=false
recorded_host_window_exists=false
if $popup_host_valid; then
  [[ $popup_active_from_state == true ]] && popup_active=true
  if current_popup_active=$(tmux show-options -qv -t "$session_name" \
    @agent_popup_active 2>/dev/null); then
    popup_active=false
    [[ $current_popup_active == on ]] && popup_active=true
  fi

  context_separator=$'\037'
  if recorded_window_context=$(tmux display-message -p -t "$popup_host_window_id" \
    "#{session_id}${context_separator}#{window_id}" 2>/dev/null); then
    IFS="$context_separator" read -r recorded_session_id recorded_window_id \
      <<< "$recorded_window_context"
    if [[ $recorded_session_id == "$popup_host_session_id" &&
      $recorded_window_id == "$popup_host_window_id" ]]; then
      recorded_host_window_exists=true
    fi
  fi
fi

# Resolve compositor windows before choosing a tmux client. A session may also
# be attached through SSH; switching that client succeeds but cannot bring a
# desktop window into view.
hypr_available=false
declare -A hypr_address_by_pid=()
declare -A hypr_workspace_id_by_pid=()
declare -A hypr_workspace_name_by_pid=()
declare -A hypr_pinned_by_pid=()
if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  hypr_clients=$(hyprctl -j clients 2>/dev/null || true)
  if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$hypr_clients"; then
    hypr_available=true
    while IFS=$'\t' read -r window_pid address workspace_id workspace_name pinned; do
      [[ $window_pid =~ ^[0-9]+$ && -n $address ]] || continue
      hypr_address_by_pid[$window_pid]=$address
      hypr_workspace_id_by_pid[$window_pid]=$workspace_id
      hypr_workspace_name_by_pid[$window_pid]=$workspace_name
      hypr_pinned_by_pid[$window_pid]=$pinned
    done < <(jq -r '.[] | [.pid, .address, .workspace.id, .workspace.name, .pinned] | @tsv' <<<"$hypr_clients")
  fi
fi

window_address=
window_workspace_id=
window_workspace_name=
window_pinned=false
find_hypr_window() {
  local process_pid=$1 parent
  window_address=
  window_workspace_id=
  window_workspace_name=
  window_pinned=false

  while [[ $process_pid =~ ^[0-9]+$ ]] && (( process_pid > 1 )); do
    if [[ -n ${hypr_address_by_pid[$process_pid]+x} ]]; then
      window_address=${hypr_address_by_pid[$process_pid]}
      window_workspace_id=${hypr_workspace_id_by_pid[$process_pid]}
      window_workspace_name=${hypr_workspace_name_by_pid[$process_pid]}
      window_pinned=${hypr_pinned_by_pid[$process_pid]}
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

# Prefer the recorded graphical host of an existing popup. Focusing that
# terminal leaves its outer tmux client unchanged, so the agent stays nested in
# the popup. Without a live popup host, prefer a client already displaying the
# target pane, then one in the target session, then another graphical client.
# Headless clients are only eligible outside Hyprland.
target_pane_id=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || true)

# A direct tmux switch does not emit tmux-argos' Seen event. Tell the configured
# daemon that a successfully opened done pane has been viewed, so its
# authoritative state changes to idle just like opening it through the picker.
mark_target_pane_seen() {
  local daemon_binary request
  [[ $target_pane_id =~ ^%[0-9]+$ ]] || return 0

  daemon_binary=$(tmux show-option -gqv @agent_daemon_binary 2>/dev/null || true)
  [[ -x $daemon_binary ]] || return 0

  printf -v request '{"type":"Seen","pane_id":"%s"}' "$target_pane_id"
  "$daemon_binary" send "$request" >/dev/null 2>&1 || true
}

refresh_client_context() {
  local wanted_client="$1" rows tty _pid _activity session_id _session window pane
  rows=$(tmux list-clients -F \
    $'#{client_tty}\t#{client_pid}\t#{client_activity}\t#{session_id}\t#{session_name}\t#{window_id}\t#{pane_id}' \
    2>/dev/null) || return 1
  while IFS=$'\t' read -r tty _pid _activity session_id _session window pane; do
    [[ $tty == "$wanted_client" ]] || continue
    [[ $session_id =~ ^\$[0-9]+$ && $window =~ ^@[0-9]+$ && $pane =~ ^%[0-9]+$ ]] \
      || return 1
    client_session_id=$session_id
    client_window_id=$window
    client_pane_id=$pane
    return 0
  done <<< "$rows"
  return 1
}

open_agent_popup() {
  local host_client="$1" host_session_id="$2" host_window_id="$3" host_pane_id="$4"
  local popup_width popup_height popup_script_q session_q popup_command
  local display_popup_pid
  popup_width=$(tmux show-option -gqv @agent_popup_width 2>/dev/null || true)
  popup_height=$(tmux show-option -gqv @agent_popup_height 2>/dev/null || true)
  [[ -n $popup_width ]] || popup_width=90%
  [[ -n $popup_height ]] || popup_height=90%

  if ! tmux set-option -t "$session_name" @agent_popup_host_client "$host_client" \
    \; set-option -t "$session_name" @agent_popup_host_session_id "$host_session_id" \
    \; set-option -t "$session_name" @agent_popup_host_window_id "$host_window_id" \
    \; set-option -t "$session_name" @agent_popup_host_pane_id "$host_pane_id"; then
    fail "Could not record popup host for $session_name"
  fi
  tmux set-option -t "$session_name" @agent_popup_active on 2>/dev/null \
    || fail "Could not mark popup active for $session_name"

  popup_script_q=$(printf '%q' "$SCRIPT_DIR/popup-agent.sh")
  session_q=$(printf '%q' "$session_name")
  popup_command="$popup_script_q $session_q"
  tmux display-popup -c "$host_client" -w "$popup_width" -h "$popup_height" \
    -E "$popup_command" </dev/null >/dev/null 2>&1 &
  display_popup_pid=$!
  sleep 0.05
  if ! kill -0 "$display_popup_pid" 2>/dev/null; then
    if ! wait "$display_popup_pid"; then
      tmux set-option -u -t "$session_name" @agent_popup_active 2>/dev/null || true
      fail "Could not open popup for $session_name"
    fi
  fi
}

client_tty=
client_activity=-1
client_priority=-1
client_address=
client_workspace_id=
client_workspace_name=
client_pinned=false
client_is_popup_host=false
client_session_id=
client_window_id=
client_pane_id=
while IFS=$'\t' read -r tty pid activity current_session_id current_session current_window current_pane; do
  [[ -n $tty && $pid =~ ^[0-9]+$ ]] || continue
  [[ $activity =~ ^[0-9]+$ ]] || activity=0

  candidate_address=
  candidate_workspace_id=
  candidate_workspace_name=
  candidate_pinned=false
  if $hypr_available; then
    find_hypr_window "$pid" || continue
    candidate_address=$window_address
    candidate_workspace_id=$window_workspace_id
    candidate_workspace_name=$window_workspace_name
    candidate_pinned=$window_pinned
  fi

  candidate_is_popup_host=false
  priority=0
  [[ $current_session == "$session_name" ]] && priority=1
  [[ -n $target_pane_id && $current_pane == "$target_pane_id" ]] && priority=2
  if $popup_host_valid && [[ $tty == "$popup_host_client" ]]; then
    priority=3
    if [[ $current_session_id == "$popup_host_session_id" &&
      $current_window == "$popup_host_window_id" &&
      $current_pane == "$popup_host_pane_id" ]]; then
      candidate_is_popup_host=true
    fi
  fi
  if (( priority > client_priority || (priority == client_priority && activity > client_activity) )); then
    client_tty=$tty
    client_activity=$activity
    client_priority=$priority
    client_address=$candidate_address
    client_workspace_id=$candidate_workspace_id
    client_workspace_name=$candidate_workspace_name
    client_pinned=$candidate_pinned
    client_is_popup_host=$candidate_is_popup_host
    client_session_id=$current_session_id
    client_window_id=$current_window
    client_pane_id=$current_pane
  fi
done < <(tmux list-clients -F $'#{client_tty}\t#{client_pid}\t#{client_activity}\t#{session_id}\t#{session_name}\t#{window_id}\t#{pane_id}' 2>/dev/null || true)

if [[ -z $client_tty ]]; then
  command -v omarchy-launch-terminal >/dev/null 2>&1 \
    || fail "No desktop tmux client and no terminal launcher found"
  omarchy-launch-terminal tmux attach-session -t "$target" >/dev/null 2>&1 &
  mark_target_pane_seen
  exit 0
fi

open_popup=false
if $popup_host_valid; then
  if ! $popup_active || ! $client_is_popup_host; then
    open_popup=true
  fi
elif ! $client_is_popup_host; then
  tmux switch-client -c "$client_tty" -t "$target" 2>/dev/null \
    || fail "Could not switch a tmux client to $session_name"
fi

if $open_popup && $recorded_host_window_exists &&
  [[ $client_session_id != "$popup_host_session_id" ||
    $client_window_id != "$popup_host_window_id" ]]; then
  tmux switch-client -c "$client_tty" -t "$popup_host_window_id" 2>/dev/null \
    || fail "Could not restore popup host window $popup_host_window_id"
  refresh_client_context "$client_tty" \
    || fail "Could not read restored popup host context"
fi
mark_target_pane_seen

if $hypr_available && [[ -n $client_address ]]; then
  # Hyprland 0.56 dispatches Lua actions. Try that API first, while keeping
  # legacy dispatchers as fallbacks for older releases.
  workspace_target=
  # Omarchy pop-out windows are pinned and already follow the current
  # workspace, so focusing one must not jump back to its original workspace.
  if [[ $client_pinned != true && $client_workspace_id =~ ^[0-9]+$ ]]; then
    workspace_target=$client_workspace_id
  elif [[ $client_pinned != true && -n $client_workspace_name && $client_workspace_name != special:* ]]; then
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
  focus_lua="local address = $address_lua; for _, window in ipairs(hl.get_windows({})) do if window.address == address then hl.dispatch(hl.dsp.focus({ window = window })); hl.dispatch(hl.dsp.window.bring_to_top({ window = window })); return end end; error('window not found: ' .. address)"
  hyprctl eval "$focus_lua" >/dev/null 2>&1 \
    || hyprctl dispatch focuswindow "address:$client_address" >/dev/null 2>&1 \
    || true
fi

if $open_popup; then
  open_agent_popup "$client_tty" "$client_session_id" "$client_window_id" "$client_pane_id"
fi
