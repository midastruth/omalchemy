#!/usr/bin/env bash
# Operations are bound to the immutable server identity carried by a row.
server_socket=''
server_pid=''

bind_tmux_server() {
  local selected_socket="$1" expected_pid="$2" identity resolved_socket resolved_pid pane extra
  if [[ "$selected_socket" != /* || ! "$expected_pid" =~ ^[0-9]+$ ]] || (( expected_pid <= 1 )); then
    printf 'midas.omalchemy: invalid server identity\n' >&2
    return 1
  fi
  if ! identity="$(command tmux -S "$selected_socket" display-message -p '#{socket_path},#{pid},0')"; then
    printf 'midas.omalchemy: selected tmux server is unavailable\n' >&2
    return 1
  fi
  IFS=, read -r resolved_socket resolved_pid pane extra <<< "$identity"
  if [[ "$resolved_socket" != "$selected_socket" || "$resolved_pid" != "$expected_pid" || "$pane" != 0 || -n "$extra" ]]; then
    printf 'midas.omalchemy: tmux server restarted; refresh before opening an agent\n' >&2
    return 1
  fi
  server_socket="$selected_socket"
  server_pid="$expected_pid"
}

tmux_server() {
  local current_pid argument quoted_argument queued_command=''
  if [[ -z "$server_socket" || -z "$server_pid" ]]; then
    printf 'midas.omalchemy: tmux server has not been bound\n' >&2
    return 1
  fi
  if ! current_pid="$(command tmux -S "$server_socket" display-message -p '#{pid}')"; then
    return 1
  fi
  if [[ "$current_pid" != "$server_pid" ]]; then
    printf 'midas.omalchemy: tmux server restarted; refresh before opening an agent\n' >&2
    return 1
  fi
  # PID validation must also happen in the server command queue. A separate
  # display-message alone leaves a restart race before the following operation.
  # Quote for tmux's command parser, not for a shell; ';' separates our commands.
  for argument in "$@"; do
    if [[ "$argument" == ';' ]]; then
      queued_command+=' ;'
    else
      quoted_argument=${argument//\'/\'\\\'\'}
      queued_command+=" '$quoted_argument'"
    fi
  done
  command tmux -S "$server_socket" if-shell -F "#{==:#{pid},$server_pid}" \
    "$queued_command" "display-message -p 'midas.omalchemy: tmux server restarted; refresh first'"
}
