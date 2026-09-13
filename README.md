# Agent Status for Omarchy Shell

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

The tooltip contains the complete state totals.

## Panel and controls

The panel lists each Pi, Codex, or Claude pane with its project path, tmux
target, visibility, attachment state, and state-change time.

- Left-click the bar icon: open/close the panel
- `j` / `k`: select an agent
- Enter, Space, or click a row: jump to its tmux pane
- `r`: reload the state file
- Esc: close the panel

Jumping reuses the tmux client already attached to the selected session, or
the most recently active tmux client. If no client is attached, it opens a
terminal and attaches to the target.

A desktop notification is sent only when a pane transitions to `blocked` or
`done`. Existing states are seeded silently when the plugin starts. Disable
notifications from the widget settings if desired.

## Install

Copy this directory to the user plugin path and rescan:

```bash
mkdir -p ~/.config/omarchy/plugins/midas.tmux-argos
cp -a . ~/.config/omarchy/plugins/midas.tmux-argos/
omarchy-shell shell rescanPlugins
omarchy plugin enable midas.tmux-argos
omarchy bar move midas.tmux-argos --section right
```

The plugin supports these inline `shell.json` settings:

```json
{
  "id": "midas.tmux-argos",
  "stateFile": "~/.cache/tmux-argos/state.json",
  "pollIntervalMs": 2000,
  "notifications": true
}
```
