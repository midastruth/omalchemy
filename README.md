# omalchemy

A display-only Quickshell bar plugin for
`~/.cache/tmux-argos/state.json`. It does not call `capture-pane` and does not
infer agent state; it only presents the normalized state written by
tmux-argos.

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

Jumping prefers the desktop tmux client already displaying the selected pane,
then another desktop client attached to the session, and focuses that client's
terminal workspace. SSH and other headless clients are ignored; if no desktop
client is attached, it opens a terminal and attaches to the target.

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
  "stateFile": "~/.cache/tmux-argos/state.json",
  "pollIntervalMs": 2000,
  "showCount": true,
  "notifications": true
}
```
