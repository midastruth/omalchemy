function text(value, fallback) {
  if (value === undefined || value === null) return fallback || ""
  return String(value)
}

function bool(value) {
  return value === true
}

function number(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : (fallback || 0)
}

function normalizedState(value) {
  var state = text(value, "idle").toLowerCase()
  return ["blocked", "working", "done", "idle"].indexOf(state) >= 0 ? state : "idle"
}

function normalizedPopupHost(value) {
  if (!value) return null
  var client = text(value.client)
  var sessionId = text(value.sessionId)
  var windowId = text(value.windowId)
  var paneId = text(value.paneId)
  if (client === "" || sessionId === "" || windowId === "" || paneId === "") return null
  return {
    client: client,
    sessionId: sessionId,
    windowId: windowId,
    paneId: paneId
  }
}

function rowKey(pane) {
  var paneId = text(pane.paneId)
  if (paneId !== "") return paneId
  return text(pane.sessionName) + ":" + text(pane.windowId) + "." + text(pane.paneIndex)
}

function projectName(path) {
  var clean = text(path).replace(/\/+$/, "")
  if (clean === "") return "Unknown project"
  if (clean === "/") return "/"
  var parts = clean.split("/")
  return parts[parts.length - 1] || clean
}

function agentName(agent) {
  var id = text(agent, "agent").toLowerCase()
  if (id === "pi") return "Pi"
  if (id === "codex") return "Codex"
  if (id === "claude") return "Claude"
  return id.charAt(0).toUpperCase() + id.slice(1)
}

function stateRank(state) {
  if (state === "blocked") return 0
  if (state === "working") return 1
  if (state === "done") return 2
  return 3
}

function normalize(document) {
  var panes = document && Array.isArray(document.panes) ? document.panes : []
  var rows = []
  for (var i = 0; i < panes.length; i++) {
    var pane = panes[i]
    if (!pane || pane.agent === undefined || pane.agent === null || text(pane.agent) === "") continue
    var state = normalizedState(pane.agentState)
    var path = text(pane.currentPath)
    rows.push({
      key: rowKey(pane),
      agent: text(pane.agent).toLowerCase(),
      agentName: agentName(pane.agent),
      state: state,
      activity: text(pane.activity, "idle"),
      changedAt: number(pane.changedAt),
      currentPath: path,
      projectName: projectName(path),
      command: text(pane.command),
      paneId: text(pane.paneId),
      paneIndex: number(pane.paneIndex),
      paneTitle: text(pane.paneTitle),
      windowId: text(pane.windowId),
      windowIndex: number(pane.windowIndex),
      windowName: text(pane.windowName),
      sessionId: text(pane.sessionId),
      sessionName: text(pane.sessionName),
      paneActive: bool(pane.paneActive),
      windowActive: bool(pane.windowActive),
      visible: bool(pane.visible),
      sessionAttached: bool(pane.sessionAttached),
      popupHost: normalizedPopupHost(pane.popupHost),
      popupActive: bool(pane.popupActive)
    })
  }

  rows.sort(function(a, b) {
    var stateOrder = stateRank(a.state) - stateRank(b.state)
    if (stateOrder !== 0) return stateOrder
    if (a.changedAt !== b.changedAt) return b.changedAt - a.changedAt
    return a.sessionName.localeCompare(b.sessionName)
  })
  return rows
}

function counts(rows) {
  var result = { blocked: 0, working: 0, done: 0, idle: 0, total: 0 }
  for (var i = 0; i < rows.length; i++) {
    var state = normalizedState(rows[i].state)
    result[state]++
    result.total++
  }
  return result
}

// A single bar mark needs one state. Urgency wins first, then live work, then
// completed work; idle and an empty list both use the neutral mark.
function summary(rows) {
  var value = counts(rows)
  if (value.blocked > 0) return { state: "blocked", count: value.blocked, counts: value }
  if (value.working > 0) return { state: "working", count: value.working, counts: value }
  if (value.done > 0) return { state: "done", count: value.done, counts: value }
  return { state: "idle", count: 0, counts: value }
}

function stateLabel(state) {
  var value = normalizedState(state)
  return value.charAt(0).toUpperCase() + value.slice(1)
}

function stateColor(state, idleColor) {
  var value = normalizedState(state)
  if (value === "blocked") return "#F14729"
  if (value === "working") return "#FDE012"
  if (value === "done") return "#17AE65"
  return idleColor
}

function iconFile(state) {
  var value = normalizedState(state)
  return value === "idle" ? "icon.svg" : value + ".svg"
}

function target(row) {
  if (!row) return ""
  var session = text(row.sessionName)
  if (session === "") return ""
  return session + ":" + String(number(row.windowIndex)) + "." + String(number(row.paneIndex))
}

function tooltip(rows) {
  var value = counts(rows)
  if (value.total === 0) return "No agents running"
  var parts = []
  if (value.blocked) parts.push(value.blocked + " blocked")
  if (value.working) parts.push(value.working + " working")
  if (value.done) parts.push(value.done + " done")
  if (value.idle) parts.push(value.idle + " idle")
  return parts.join(" · ")
}

function transitionNotices(previous, rows) {
  var notices = []
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var oldState = previous[row.key]
    if (oldState === row.state) continue
    if (row.state === "blocked" || row.state === "done") notices.push(row)
  }
  return notices
}

function stateMap(rows) {
  var result = ({})
  for (var i = 0; i < rows.length; i++) result[rows[i].key] = rows[i].state
  return result
}
