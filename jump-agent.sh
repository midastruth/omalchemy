#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=server.sh
. "$SCRIPT_DIR/server.sh"
selected_socket=${1-}
expected_server_pid=${2-}
pane_id=${3-}
session_id=${4-}
session_name=${5-}
popup_host_client=${6-}
popup_host_session_id=${7-}
popup_host_window_id=${8-}
popup_host_pane_id=${9-}

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
if ! bind_tmux_server "$selected_socket" "$expected_server_pid"; then
  exit 1
fi
[[ $pane_id =~ ^%[0-9]+$ && $session_id =~ ^\$[0-9]+$ ]] \
  || fail "The state row has no immutable pane/session identity"
tmux_server has-session -t "$session_id" 2>/dev/null || fail "tmux session no longer exists: $session_name"
if ! pane_context=$(tmux_server display-message -p -t "$pane_id" $'#{session_id}\037#{session_name}' 2>/dev/null); then
  fail "tmux pane no longer exists: $pane_id"
fi
IFS=$'\037' read -r pane_session_id session_name <<< "$pane_context"
[[ $pane_session_id == "$session_id" ]] || fail "tmux pane moved to another session; refresh first"
target=$pane_id

# popupHost is a persistent presentation preference; popupActive is only a
# hint because tmux cannot run cleanup traps after every kind of popup exit.
# The live nested tmux attachment is verified below before popupActive is used.
popup_active=false
recorded_host_window_exists=false
if $popup_host_valid; then
  context_separator=$'\037'
  if recorded_window_context=$(tmux_server display-message -p -t "$popup_host_window_id" \
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

# A managed popup's nested tmux client is launched by the tmux server. Our
# restored popups additionally have popup-agent.sh as their direct parent.
# Verify those process relationships instead of trusting the persistent tmux
# option: an interrupted popup can leave @agent_popup_active set to on.
tmux_server_pid=$server_pid
is_popup_attachment() {
  local process_pid=$1 parent argument index depth
  local -a arguments=()
  [[ $process_pid =~ ^[0-9]+$ && -r /proc/$process_pid/status ]] || return 1
  for ((depth = 0; depth < 8; depth++)); do
    parent=$(awk '/^PPid:/ { print $2; exit }' "/proc/$process_pid/status" 2>/dev/null || true)
    [[ $parent =~ ^[0-9]+$ && $parent -gt 1 ]] || break
    [[ $tmux_server_pid =~ ^[0-9]+$ && $parent == "$tmux_server_pid" ]] && return 0
    if ((depth == 0)) && [[ -r /proc/$parent/cmdline ]]; then
      while IFS= read -r -d '' argument; do
        arguments+=("$argument")
      done < "/proc/$parent/cmdline"
      for ((index = 0; index + 3 < ${#arguments[@]}; index++)); do
        if [[ ${arguments[$index]} == */popup-agent.sh &&
          ${arguments[$((index + 1))]} == "$server_socket" &&
          ${arguments[$((index + 2))]} == "$server_pid" &&
          ${arguments[$((index + 3))]} == "$session_id" ]]; then
          return 0
        fi
      done
    fi
    process_pid=$parent
  done
  return 1
}

# Prefer the recorded graphical host of an existing popup. Focusing that
# terminal leaves its outer tmux client unchanged, so the agent stays nested in
# the popup. Without a live popup host, prefer a client already displaying the
# target pane, then one in the target session, then another graphical client.
# Headless clients are only eligible outside Hyprland.
target_pane_id=$pane_id

# A direct tmux switch does not emit tmux-argos' Seen event. Tell the configured
# daemon that a successfully opened done pane has been viewed, so its
# authoritative state changes to idle just like opening it through the picker.
mark_target_pane_seen() {
  if ! bash "$SCRIPT_DIR/seen-agent.sh" "$server_socket" "$server_pid" "$target_pane_id"; then
    return 1
  fi
  return 0
}

refresh_client_context() {
  local wanted_client="$1" rows tty _pid _activity host_session_id _session window pane
  rows=$(tmux_server list-clients -F \
    $'#{client_tty}\t#{client_pid}\t#{client_activity}\t#{session_id}\t#{session_name}\t#{window_id}\t#{pane_id}' \
    2>/dev/null) || return 1
  while IFS=$'\t' read -r tty _pid _activity host_session_id _session window pane; do
    [[ $tty == "$wanted_client" ]] || continue
    [[ $host_session_id =~ ^\$[0-9]+$ && $window =~ ^@[0-9]+$ && $pane =~ ^%[0-9]+$ ]] \
      || return 1
    client_session_id=$host_session_id
    client_window_id=$window
    client_pane_id=$pane
    return 0
  done <<< "$rows"
  return 1
}

open_agent_popup() {
  local host_client="$1" host_session_id="$2" host_window_id="$3" host_pane_id="$4"
  local popup_width popup_height popup_command
  local display_popup_pid
  popup_width=$(tmux_server show-option -gqv @agent_popup_width 2>/dev/null) || fail "Could not read popup width"
  popup_height=$(tmux_server show-option -gqv @agent_popup_height 2>/dev/null) || fail "Could not read popup height"
  [[ -n $popup_width ]] || popup_width=90%
  [[ -n $popup_height ]] || popup_height=90%

  if ! tmux_server set-option -t "$session_id" @agent_popup_host_client "$host_client" \
    \; set-option -t "$session_id" @agent_popup_host_session_id "$host_session_id" \
    \; set-option -t "$session_id" @agent_popup_host_window_id "$host_window_id" \
    \; set-option -t "$session_id" @agent_popup_host_pane_id "$host_pane_id"; then
    fail "Could not record popup host for $session_name"
  fi
  # Only one popup can exist on a tmux client. Close the currently displayed
  # popup before restoring this agent's popup presentation.
  tmux_server display-popup -C -c "$host_client" >/dev/null 2>&1 || fail "Could not close host popup"
  tmux_server set-option -t "$session_id" @agent_popup_active on 2>/dev/null \
    || fail "Could not mark popup active for $session_name"

  printf -v popup_command '%q %q %q %q' "$SCRIPT_DIR/popup-agent.sh" "$server_socket" "$server_pid" "$session_id"
  tmux_server display-popup -c "$host_client" -w "$popup_width" -h "$popup_height" \
    -E "$popup_command" </dev/null >/dev/null 2>&1 &
  display_popup_pid=$!
  sleep 0.05
  if ! kill -0 "$display_popup_pid" 2>/dev/null; then
    if ! wait "$display_popup_pid"; then
      tmux_server set-option -u -t "$session_id" @agent_popup_active 2>/dev/null || true
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
popup_attachment_active=false
while IFS=$'\t' read -r tty pid activity current_session_id current_session current_window current_pane; do
  [[ -n $tty && $pid =~ ^[0-9]+$ ]] || continue
  [[ $activity =~ ^[0-9]+$ ]] || activity=0

  if $popup_host_valid && [[ $current_session == "$session_name" ]] &&
    is_popup_attachment "$pid"; then
    popup_attachment_active=true
  fi

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
done < <(tmux_server list-clients -F $'#{client_tty}\t#{client_pid}\t#{client_activity}\t#{session_id}\t#{session_name}\t#{window_id}\t#{pane_id}' 2>/dev/null || true)

if $popup_attachment_active; then
  popup_active=true
elif $popup_host_valid; then
  # Repair a stale producer hint so the exposed state catches up as well.
  tmux_server set-option -u -t "$session_id" @agent_popup_active 2>/dev/null || true
fi

if [[ -z $client_tty ]]; then
  command -v omarchy-launch-terminal >/dev/null 2>&1 \
    || fail "No desktop tmux client and no terminal launcher found"
  omarchy-launch-terminal bash "$SCRIPT_DIR/attach-agent.sh" "$server_socket" "$server_pid" "$pane_id" "$session_id" >/dev/null 2>&1 &
  exit 0
fi

open_popup=false
if $popup_host_valid; then
  if ! $popup_active || ! $client_is_popup_host; then
    open_popup=true
  fi
elif ! $client_is_popup_host; then
  # A direct presentation must not remain hidden behind another agent's popup.
  tmux_server display-popup -C -c "$client_tty" >/dev/null 2>&1 || fail "Could not close client popup"
  tmux_server switch-client -c "$client_tty" -t "$target" 2>/dev/null \
    || fail "Could not switch a tmux client to $session_name"
fi

if $open_popup && $recorded_host_window_exists &&
  [[ $client_session_id != "$popup_host_session_id" ||
    $client_window_id != "$popup_host_window_id" ]]; then
  tmux_server switch-client -c "$client_tty" -t "$popup_host_window_id" 2>/dev/null \
    || fail "Could not restore popup host window $popup_host_window_id"
  refresh_client_context "$client_tty" \
    || fail "Could not read restored popup host context"
fi

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
if ! mark_target_pane_seen; then
  fail "Pane opened, but Seen could not be sent to its server"
fi
