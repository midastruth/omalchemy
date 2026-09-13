#!/usr/bin/env bash
set -uo pipefail

notification_id=${1-}
event_token=${2-}
urgency=${3-normal}
icon=${4-}
title=${5-}
body=${6-}

[[ $notification_id =~ ^[0-9]+$ ]] || exit 2
[[ $urgency == low || $urgency == normal || $urgency == critical ]] || urgency=normal

# A bar widget instance is created for every monitor. Serialize notifications
# per pane so all instances observing the same state-file transition emit one
# desktop notification rather than one notification per monitor.
umask 077
runtime_dir=${XDG_RUNTIME_DIR:-/tmp/omalchemy-${UID}}
cache_dir=$runtime_dir/omalchemy-notifications
mkdir -p "$cache_dir" || exit 1
stamp_file=$cache_dir/$notification_id.stamp
lock_file=$cache_dir/$notification_id.lock

exec 9>"$lock_file" || exit 1
flock -x 9 || exit 1

now=$(date +%s)
last_token=
last_sent_at=0
if [[ -r $stamp_file ]]; then
  IFS=$'\t' read -r last_token last_sent_at < "$stamp_file" || true
fi
[[ $last_sent_at =~ ^[0-9]+$ ]] || last_sent_at=0

# changedAt (or the document generation time as a fallback) makes the token
# stable for one transition. The time bound avoids suppressing a future event
# forever if a producer has no usable timestamps.
if [[ -n $event_token && $event_token == "$last_token" ]] && (( now - last_sent_at < 30 )); then
  exit 0
fi

if notify-send --app-name=omalchemy --replace-id="$notification_id" \
    --urgency="$urgency" --icon="$icon" "$title" "$body" >/dev/null; then
  printf '%s\t%s\n' "$event_token" "$now" > "$stamp_file"
fi
