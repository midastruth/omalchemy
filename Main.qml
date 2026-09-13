import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Display-only adapter for tmux-argos. It never inspects panes or infers a
// state: every row and count comes directly from the normalized JSON file.
Item {
    id: root
    visible: false

    property var settings: ({})
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string configuredPath: String(setting("stateFile", "~/.cache/tmux-argos/state.json"))
    readonly property string statePath: expandPath(configuredPath)
    readonly property int pollIntervalMs: Math.max(1000, Number(setting("pollIntervalMs", 2000)) || 2000)
    readonly property bool showCount: setting("showCount", true) !== false
    readonly property bool notificationsEnabled: setting("notifications", true) !== false

    property var agents: []
    property var previousStates: ({})
    property bool initialized: false
    property string errorText: ""
    property double generatedAt: 0
    property string dataSignature: ""
    property int revision: 0

    readonly property var status: Model.summary(agents)
    readonly property var counts: status.counts
    readonly property string dominantState: status.state
    readonly property int dominantCount: status.count
    readonly property string tooltipText: Model.tooltip(agents)

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined;
        return value === undefined || value === null ? fallback : value;
    }

    function expandPath(path) {
        var value = String(path || "").trim();
        if (value === "~")
            return home;
        if (value.indexOf("~/") === 0)
            return home + value.substring(1);
        if (value.indexOf("$HOME/") === 0)
            return home + value.substring(5);
        return value;
    }

    function localPath(url) {
        var value = String(url || "");
        if (value.indexOf("file://") === 0)
            value = value.substring(7);
        try {
            return decodeURIComponent(value);
        } catch (e) {
            return value;
        }
    }

    function refresh() {
        stateFile.reload();
    }

    function applyDocument(content) {
        var document;
        try {
            document = JSON.parse(String(content || ""));
            if (!document || !Array.isArray(document.panes))
                throw new Error("missing panes array");
        } catch (error) {
            errorText = "Invalid tmux-argos state: " + error;
            console.warn("midas.omalchemy:", errorText);
            return;
        }

        var next = Model.normalize(document);
        var signature = JSON.stringify(next);
        if (initialized && signature === dataSignature) {
            generatedAt = Number(document.generatedAt || 0);
            errorText = "";
            return;
        }

        if (initialized && notificationsEnabled) {
            var notices = Model.transitionNotices(previousStates, next);
            for (var i = 0; i < notices.length; i++)
                enqueueNotification(notices[i]);
        }

        previousStates = Model.stateMap(next);
        dataSignature = signature;
        agents = next;
        generatedAt = Number(document.generatedAt || 0);
        initialized = true;
        errorText = "";
        revision++;
    }

    function notificationBody(row) {
        var location = row.currentPath !== "" ? row.currentPath : "Unknown project";
        var tmuxLocation = row.sessionName;
        if (row.windowIndex >= 0)
            tmuxLocation += ":" + row.windowIndex + "." + row.paneIndex;
        return location + (tmuxLocation !== "" ? "\n" + tmuxLocation : "");
    }

    // Every monitor has a widget instance. A stable replace id makes their
    // identical transition notifications collapse into one desktop toast.
    function notificationId(row) {
        var value = String(row.key || row.sessionName || "agent");
        var hash = 5381;
        for (var i = 0; i < value.length; i++)
            hash = ((hash * 33) ^ value.charCodeAt(i)) >>> 0;
        return 700000 + (hash % 1000000000);
    }

    property var notificationQueue: []

    function enqueueNotification(row) {
        notificationQueue = notificationQueue.concat([row]);
        runNextNotification();
    }

    function runNextNotification() {
        if (notificationProcess.running || notificationQueue.length === 0)
            return;
        var row = notificationQueue[0];
        notificationQueue = notificationQueue.slice(1);
        var icon = localPath(Qt.resolvedUrl("assets/" + Model.iconFile(row.state)));
        notificationProcess.command = ["notify-send", "--app-name=omalchemy", "--replace-id=" + notificationId(row), "--urgency=" + (row.state === "blocked" ? "critical" : "normal"), "--icon=" + icon, row.agentName + " " + row.state, notificationBody(row)];
        notificationProcess.running = true;
    }

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.applyDocument(text())
        onLoadFailed: root.errorText = "State file not found: " + root.statePath
    }

    // FileView handles normal writes. This low-frequency fallback also covers
    // producers which replace the file inode atomically or create it later.
    Timer {
        interval: root.pollIntervalMs
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Process {
        id: notificationProcess
        running: false
        onExited: root.runNextNotification()
    }

    Component.onCompleted: root.refresh()
}
