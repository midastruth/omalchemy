#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}/omalchemy-jump-tests.$$"
MOCK_BIN="$TMP_ROOT/bin"
MOCK_DAEMON="$MOCK_BIN/tmux-argos-daemon"
COMMAND_LOG="$TMP_ROOT/commands.log"
TMUX_STATE="$TMP_ROOT/tmux-state"
mkdir -p "$MOCK_BIN"
: >"$COMMAND_LOG"
: >"$TMUX_STATE"
active_popup_wrapper_pid=
cleanup() {
  if [[ ${active_popup_wrapper_pid:-} =~ ^[0-9]+$ ]]; then
    kill "$active_popup_wrapper_pid" 2>/dev/null || true
    wait "$active_popup_wrapper_pid" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat >"$MOCK_BIN/tmux" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} != -S || ${2:-} != /tmp/tmux-test ]]; then
  printf 'unbound tmux command\n' >&2
  exit 1
fi
shift 2
if [[ ${1:-} == if-shell ]]; then
  [[ ${2:-} == -F && ${3:-} == '#{==:#{pid},123}' ]] || exit 1
  mapfile -d '' -t queued_arguments < <(python3 -c 'import shlex,sys; sys.stdout.write("\0".join(shlex.split(sys.argv[1]))+"\0")' "$4")
  set -- "${queued_arguments[@]}"
fi
printf 'tmux' >>"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
command_name=${1:-}
shift || true
case "$command_name" in
has-session)
  exit 0
  ;;
display-message)
  format=${*: -1}
  target=
  client=
  previous=
  for argument in "$@"; do
    [[ $previous == -t ]] && target=$argument
    [[ $previous == -c ]] && client=$argument
    previous=$argument
  done
  if [[ $format == '#{socket_path},#{pid},0' ]]; then
    printf '%s' '/tmp/tmux-test,123,0'
  elif [[ $format == '#{pid}' ]]; then
    printf '%s' '123'
  elif [[ $format == $'#{session_id}\037#{session_name}' ]]; then
    printf '%s\037%s' '$1' 'agent-pi-project-1'
  elif [[ $format == *'#{session_id}'* && $format == *'#{window_id}'* ]]; then
    separator=$'\037'
    if [[ $target == @38 ]]; then
      [[ -n ${TMUX_MOCK_HOST_WINDOW_MISSING:-} ]] && exit 1
      printf '%s%s%s' '$0' "$separator" '@38'
    elif [[ -n $client ]]; then
      # display-message -c selects where a message is displayed; without -t,
      # pane formats still describe the invoking target rather than that client.
      printf '%s%s%s%s%s' '$2' "$separator" '@4' "$separator" '%7'
    fi
  else
    case "$format" in
    '#{session_name}') printf '%s' 'agent-pi-project-1' ;;
    '#{pane_id}') printf '%s' '%46' ;;
    esac
  fi
  ;;
show-option|show-options)
  option=${*: -1}
  if [[ $option == @agent_popup_active ]]; then
    printf '%s' "${TMUX_MOCK_POPUP_ACTIVE:-}"
  elif [[ $option == @agent_daemon_binary ]]; then
    printf '%s' "$MOCK_DAEMON"
  fi
  exit 0
  ;;
list-clients)
  [[ -n ${TMUX_MOCK_NO_CLIENTS:-} ]] && exit 0
  if [[ -s $TMUX_STATE ]]; then
    client_session_id='$0'
    client_window_id='@38'
    client_pane_id='%41'
  else
    client_session_id=${TMUX_MOCK_CLIENT_SESSION_ID:-\$0}
    client_window_id=${TMUX_MOCK_CLIENT_WINDOW_ID:-@38}
    client_pane_id=${TMUX_MOCK_CLIENT_PANE_ID:-%41}
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${TMUX_MOCK_CLIENT_TTY:-/dev/pts/1}" "$TEST_CLIENT_PID" '100' \
    "$client_session_id" 'work' "$client_window_id" "$client_pane_id"
  if [[ ${TMUX_MOCK_POPUP_CLIENT_PID:-} =~ ^[0-9]+$ ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      '/dev/pts/8' "$TMUX_MOCK_POPUP_CLIENT_PID" '101' '$1' \
      'agent-pi-project-1' '@9' '%46'
  fi
  ;;
switch-client)
  [[ " $* " == *' -t @38 '* ]] && printf 'restored\n' >"$TMUX_STATE"
  exit 0
  ;;
display-popup)
  [[ " $* " == *' -C '* ]] && exit 0
  if [[ -n ${TMUX_MOCK_POPUP_STARTED:-} ]]; then
    : >"$TMUX_MOCK_POPUP_STARTED"
    while [[ ! -e ${TMUX_MOCK_POPUP_RELEASE:-} ]]; do
      sleep 0.02
    done
  fi
  ;;
esac
MOCK

cat >"$MOCK_BIN/hyprctl" <<'MOCK'
#!/usr/bin/env bash
printf 'hyprctl' >>"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
if [[ ${1:-} == -j && ${2:-} == clients ]]; then
  printf '[{"pid":%s,"address":"0xabc","workspace":{"id":2,"name":"2"},"pinned":false}]\n' "$TEST_CLIENT_PID"
fi
MOCK

cat >"$MOCK_BIN/omarchy-launch-terminal" <<'MOCK'
#!/usr/bin/env bash
printf 'omarchy-launch-terminal' >>"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
MOCK

cat >"$MOCK_BIN/notify-send" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

cat >"$MOCK_DAEMON" <<'MOCK'
#!/usr/bin/env bash
printf 'daemon\tTMUX=%s' "${TMUX-}" >>"$COMMAND_LOG"
printf '\t%s' "$@" >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
MOCK

chmod +x "$MOCK_BIN"/*
export PATH="$MOCK_BIN:$PATH"
export COMMAND_LOG TMUX_STATE MOCK_DAEMON TEST_CLIENT_PID=$$

pass_count=0
fail_count=0
pass() {
  pass_count=$((pass_count + 1))
  printf 'ok - %s\n' "$1"
}
fail() {
  fail_count=$((fail_count + 1))
  printf 'not ok - %s\n' "$1" >&2
}
assert_contains() {
  local name=$1 needle=$2
  if grep -Fq "$needle" "$COMMAND_LOG"; then pass "$name"; else fail "$name"; fi
}
assert_not_contains() {
  local name=$1 needle=$2
  if grep -Fq "$needle" "$COMMAND_LOG"; then fail "$name"; else pass "$name"; fi
}

live_popup_dir="$TMP_ROOT/live-popup"
live_popup_pid_file="$live_popup_dir/client.pid"
mkdir -p "$live_popup_dir"
cat >"$live_popup_dir/popup-agent.sh" <<'MOCK'
#!/usr/bin/env bash
child=
cleanup_popup() {
  [[ ${child:-} =~ ^[0-9]+$ ]] && kill "$child" 2>/dev/null || true
  exit 0
}
trap cleanup_popup HUP INT TERM
sleep 300 &
child=$!
printf '%s\n' "$child" >"$4"
wait "$child"
MOCK
chmod +x "$live_popup_dir/popup-agent.sh"
bash "$live_popup_dir/popup-agent.sh" '/tmp/tmux-test' 123 '$1' "$live_popup_pid_file" &
active_popup_wrapper_pid=$!
for _ in $(seq 1 50); do
  [[ -s $live_popup_pid_file ]] && break
  sleep 0.02
done
export TMUX_MOCK_POPUP_CLIENT_PID
TMUX_MOCK_POPUP_CLIENT_PID=$(<"$live_popup_pid_file")

: >"$COMMAND_LOG"
export TMUX_MOCK_POPUP_ACTIVE=on
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1' \
  '/dev/pts/1' '$0' '@38' '%41' true
assert_not_contains \
  'jump-agent focuses an existing popup host without switching the outer tmux client' \
  $'tmux\tswitch-client'
assert_contains \
  'jump-agent focuses the terminal that hosts the existing popup' \
  $'hyprctl\teval'
assert_not_contains \
  'jump-agent does not open a duplicate for an active popup' \
  $'tmux\tdisplay-popup'

kill "$active_popup_wrapper_pid"
wait "$active_popup_wrapper_pid" 2>/dev/null || true
active_popup_wrapper_pid=
unset TMUX_MOCK_POPUP_CLIENT_PID
: >"$COMMAND_LOG"
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1' \
  '/dev/pts/1' '$0' '@38' '%41' true
assert_contains \
  'jump-agent ignores and repairs a stale popup-active hint' \
  $'tmux\tset-option\t-u\t-t\t$1\t@agent_popup_active'
assert_contains \
  'jump-agent restores a background popup even when its active hint is stale' \
  $'tmux\tdisplay-popup\t-c\t/dev/pts/1\t-w\t90%\t-h\t90%\t-E\t'
assert_contains \
  'jump-agent closes another popup on the host before restoring the selected one' \
  $'tmux\tdisplay-popup\t-C\t-c\t/dev/pts/1'
unset TMUX_MOCK_POPUP_ACTIVE

: >"$COMMAND_LOG"
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1' \
  '/dev/pts/1' '$0' '@38' '%41' false
assert_not_contains \
  'jump-agent reopens a background popup without switching the outer tmux client' \
  $'tmux\tswitch-client'
assert_contains \
  'jump-agent reopens a background agent in a popup' \
  $'tmux\tdisplay-popup\t-c\t/dev/pts/1\t-w\t90%\t-h\t90%\t-E\t'
assert_contains \
  'jump-agent clears the host popup before reopening a background popup' \
  $'tmux\tdisplay-popup\t-C\t-c\t/dev/pts/1'
assert_contains \
  'jump-agent marks a reopened popup active' \
  $'tmux\tset-option\t-t\t$1\t@agent_popup_active\ton'
assert_contains \
  'jump-agent delegates popup lifecycle cleanup to the popup command' \
  'popup-agent.sh'

: >"$COMMAND_LOG"
popup_started="$TMP_ROOT/popup-started"
popup_release="$TMP_ROOT/popup-release"
rm -f "$popup_started" "$popup_release"
export TMUX_MOCK_POPUP_STARTED="$popup_started"
export TMUX_MOCK_POPUP_RELEASE="$popup_release"
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1' \
  '/dev/pts/1' '$0' '@38' '%41' false &
nonblocking_jump_pid=$!
for _ in $(seq 1 50); do
  [[ -e $popup_started ]] && break
  sleep 0.02
done
sleep 0.1
if kill -0 "$nonblocking_jump_pid" 2>/dev/null; then
  fail 'jump-agent returns after opening popup so the active popup can be focused again'
else
  wait "$nonblocking_jump_pid"
  pass 'jump-agent returns after opening popup so the active popup can be focused again'
fi
touch "$popup_release"
wait "$nonblocking_jump_pid" 2>/dev/null || true
unset TMUX_MOCK_POPUP_STARTED TMUX_MOCK_POPUP_RELEASE

: >"$COMMAND_LOG"
bash "$ROOT/popup-agent.sh" '/tmp/tmux-test' 123 '$1'
assert_contains \
  'popup command marks a popup inactive again after it closes' \
  $'tmux\tset-option\t-u\t-t\t$1\t@agent_popup_active'

: >"$COMMAND_LOG"
: >"$TMUX_STATE"
export TMUX_MOCK_CLIENT_SESSION_ID=\$5
export TMUX_MOCK_CLIENT_WINDOW_ID=@50
export TMUX_MOCK_CLIENT_PANE_ID=%51
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1' \
  '/dev/pts/1' '$0' '@38' '%41' false
assert_contains \
  'jump-agent restores a moved popup host client to its recorded window before reopening' \
  $'tmux\tswitch-client\t-c\t/dev/pts/1\t-t\t@38'
assert_contains \
  'jump-agent reopens the popup on the restored original client' \
  $'tmux\tdisplay-popup\t-c\t/dev/pts/1'
assert_contains \
  'jump-agent records the restored work context instead of the invoking pane' \
  $'@agent_popup_host_session_id\t$0\t;\tset-option\t-t\t$1\t@agent_popup_host_window_id\t@38\t;\tset-option\t-t\t$1\t@agent_popup_host_pane_id\t%41'

: >"$COMMAND_LOG"
: >"$TMUX_STATE"
export TMUX_MOCK_CLIENT_TTY=/dev/pts/9
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1' \
  '/dev/pts/missing' '$0' '@38' '%41' false
assert_contains \
  'jump-agent uses another graphical client when the original host client disappeared' \
  $'tmux\tdisplay-popup\t-c\t/dev/pts/9'
assert_contains \
  'jump-agent switches the replacement client to the recorded work window before reopening' \
  $'tmux\tswitch-client\t-c\t/dev/pts/9\t-t\t@38'
assert_not_contains \
  'jump-agent never recreates a deleted tmux session implicitly' \
  $'tmux\tnew-session'

: >"$COMMAND_LOG"
: >"$TMUX_STATE"
export TMUX_MOCK_HOST_WINDOW_MISSING=1
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1' \
  '/dev/pts/missing' '$0' '@38' '%41' false
assert_not_contains \
  'jump-agent falls back only when the recorded work window no longer exists' \
  $'tmux\tswitch-client\t-c\t/dev/pts/9\t-t\t@38'
assert_contains \
  'jump-agent opens on the fallback client when the recorded work window is gone' \
  $'tmux\tdisplay-popup\t-c\t/dev/pts/9'
unset TMUX_MOCK_CLIENT_TTY TMUX_MOCK_CLIENT_SESSION_ID \
  TMUX_MOCK_CLIENT_WINDOW_ID TMUX_MOCK_CLIENT_PANE_ID \
  TMUX_MOCK_HOST_WINDOW_MISSING

: >"$COMMAND_LOG"
env -u TMUX bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' \$1 'agent-pi-project-1'
assert_contains \
  'jump-agent retains direct-pane behavior for agents without a popup preference' \
  $'tmux\tswitch-client\t-c\t/dev/pts/1\t-t\t%46'
assert_contains \
  'jump-agent closes an existing popup before directly displaying an agent' \
  $'tmux\tdisplay-popup\t-C\t-c\t/dev/pts/1'
assert_contains \
  'jump-agent uses the row server identity when reporting Seen from Quickshell' \
  $'daemon\tTMUX=/tmp/tmux-test,123,0\tsend\t{"type":"Seen","pane_id":"%46"}'

: >"$COMMAND_LOG"
export TMUX_MOCK_NO_CLIENTS=1
bash "$ROOT/jump-agent.sh" '/tmp/tmux-test' 123 '%46' '$1' 'agent-pi-project-1'
for _ in $(seq 1 50); do
  if grep -Fq 'attach-agent.sh' "$COMMAND_LOG"; then
    break
  fi
  sleep 0.02
done
assert_contains \
  'jump-agent retains detached-session terminal launch behavior' \
  $'omarchy-launch-terminal\tbash\t'"$ROOT"$'/attach-agent.sh\t/tmp/tmux-test\t123\t%46\t$1'

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
[[ $fail_count -eq 0 ]]
