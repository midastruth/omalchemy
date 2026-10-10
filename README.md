# omalchemy

A Quickshell bar plugin for tmux-argos' normalized state. Configure an absolute
`tmuxSocket` path to select exactly one server. The display reads
`~/.cache/tmux-argos/sources/<socket_hash>.json` and watches the `stateFile` it
advertises. The hash is FNV-1a64 of the socket path's UTF-8 bytes, without the PID;
`Model.socketHash` mirrors Argos' `source_socket_hash`.

There is no periodic tmux/daemon discovery command and no `capture-pane` or state
inference. The fallback timer reloads files only, covering atomic replacement
and files created after startup. Missing/invalid descriptors, disabled file
exposure (`stateFile: null`), and source PID/path changes clear old rows and
notification history. Each reader captures its source identity; late loads or
snapshots with mismatched `serverSocket`/`serverPid` are rejected. A source file is
last-known state, not a live-server probe: an abrupt daemon crash may leave it
until the next daemon publication.

## Bar

The bar uses one status icon and one count, never project names. The dominant
state is selected in this order:

1. `blocked` — red icon, blocked count
2. `working` — yellow icon, working count
3. `done` — green icon, done count
4. all `idle`, or no agent panes — neutral icon with no count

The tooltip contains the complete state totals. The widget settings can hide
the count while keeping the status icon visible.

## Panel and controls

The panel lists each Pi, Codex, or Claude pane with its project path, tmux
target, visibility, attachment state, and state-change time.

- Left-click the bar icon: open/close the panel
- `j` / `k`: select an agent
- Enter, Space, or click a row: jump to its tmux pane
- `r`: reload the state file
- Click the gear button or press `s`: open/close settings
- Esc: close the panel

When tmux-argos reports that an agent is already displayed in a popup, jumping
focuses the popup's host terminal without switching its outer tmux client. If
the popup was closed and the agent is running in the background, jumping
restores the host client to the recorded outer tmux window and reopens the
popup there. If the original client disappeared but the recorded window still
exists, another graphical client is moved to that window before opening the
popup. Only a deleted recorded window causes a fallback to the replacement
client's current window; deleted tmux sessions are never recreated implicitly.
Agents without a popup preference retain the direct pane-switch behavior. After
opening the pane, omalchemy sends tmux-argos a
`Seen` event so a `done` state becomes `idle`. Only these explicit actions invoke
tmux: every operation is bound to the row's socket and PID, including popup
cleanup and Seen. Server restart rejects an old row even if the new server
reuses its pane/session IDs. Targets use `%pane` and `$session` IDs, never names
or indices; a renamed session remains usable, while a deleted ID is an error.
PID validation also runs in the tmux command queue to close the restart race.
Asynchronous terminal launch transports the session ID as its numeric suffix
so `systemd-run` cannot expand `$N` as an environment variable. `attach-agent.sh`
restores the immutable `$session` ID (and still accepts the original form),
then revalidates the server and pane; Seen is scheduled only after a successful
attachment. Pinned pop-out terminals are
raised on the current workspace instead of jumping back to their original
workspace. SSH and other headless clients are ignored; if no desktop client is
attached, it opens a terminal and attaches to the target.

A desktop notification is sent only when a pane transitions to `blocked` or
`done`. Existing states are seeded silently when the plugin starts, and the
same transition is deduplicated across per-monitor widget instances. The
widget settings page provides separate toggles for the count and notifications.
Open it from the gear button in the panel header or by pressing `s`.

## Install

Copy this directory to the user plugin path and rescan:

```bash
mkdir -p ~/.config/omarchy/plugins/midas.omalchemy
cp -a . ~/.config/omarchy/plugins/midas.omalchemy/
omarchy-shell shell rescanPlugins
omarchy plugin enable midas.omalchemy
omarchy bar move midas.omalchemy --section right
```

The plugin supports these inline `shell.json` settings:

```json
{
  "id": "midas.omalchemy",
  "tmuxSocket": "/tmp/tmux-1000/default",
  "pollIntervalMs": 2000,
  "showCount": true,
  "notifications": true
}
```

`tmuxSocket` is required; there is no implicit default server or inherited
`TMUX` selection. Configure the socket's exact absolute path (a leading `~/`
is expanded). Argos owns `stateFile`; omalchemy does not configure that path.
Use an Argos version that publishes source descriptors and snapshot identities.

## Verification

```bash
node tests/source_binding.mjs
python3 tests/server_binding.py
python3 tests/file_display.py # real Quickshell, offscreen
python3 tests/real_operations.py # real tmux with a pseudo-terminal
python3 tests/terminal_launch.py # real desktop launcher; briefly opens an isolated terminal
bash tests/jump-agent.sh
shellcheck -x -P . *.sh tests/*.sh
```
