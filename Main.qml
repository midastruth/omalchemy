pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Display is file-driven. Only explicit row operations invoke tmux.
Item {
    id: root
    visible: false

    property var settings: ({})
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string configuredSocket: expandPath(String(setting("tmuxSocket", "")))
    readonly property string sourcePath: configuredSocket.charAt(0) === "/" ? home + "/.cache/tmux-argos/sources/" + Model.socketHash(configuredSocket) + ".json" : ""
    readonly property int pollIntervalMs: Math.max(1000, Number(setting("pollIntervalMs", 2000)) || 2000)
    readonly property bool showCount: setting("showCount", true) !== false
    readonly property bool notificationsEnabled: setting("notifications", true) !== false

    property var source: null
    property FileView sourceFile: null
    property FileView stateReader: null
    property bool ready: false
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
    readonly property string tooltipText: errorText !== "" ? errorText : Model.tooltip(agents)

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
        } catch (error) {
            return value;
        }
    }

    function clearAgents() {
        agents = [];
        previousStates = ({});
        notificationQueue = [];
        initialized = false;
        generatedAt = 0;
        dataSignature = "";
        revision++;
    }

    function discardStateReader() {
        if (stateReader) {
            stateReader.destroy();
            stateReader = null;
        }
    }

    function invalidateSource(message) {
        discardStateReader();
        source = null;
        clearAgents();
        errorText = message;
    }

    function resetSourceReader() {
        if (sourceFile) {
            sourceFile.destroy();
            sourceFile = null;
        }
        invalidateSource("Configure an absolute tmuxSocket to select a server");
        if (sourcePath !== "") {
            errorText = "Loading Argos source…";
            sourceFile = sourceReaderComponent.createObject(root, {
                path: sourcePath,
                requestedSocket: configuredSocket
            });
        }
    }

    function refresh() {
        if (sourceFile)
            sourceFile.reload();
        if (stateReader)
            stateReader.reload();
    }

    function applySource(content, requestedSocket) {
        if (requestedSocket !== configuredSocket)
            return;
        var next;
        try {
            next = JSON.parse(String(content || ""));
            if (!Model.sameServer(next, next) || next.serverSocket !== configuredSocket ||
                !(next.stateFile === null || (typeof next.stateFile === "string" && next.stateFile.charAt(0) === "/")))
                throw new Error("invalid source identity or state path");
        } catch (error) {
            invalidateSource("Invalid Argos source: " + error);
            return;
        }

        if (!Model.sameServer(source, next) || source.stateFile !== next.stateFile) {
            discardStateReader();
            clearAgents();
            source = next;
            if (next.stateFile !== null) {
                errorText = "Loading Argos state…";
                // createObject supplies a value, not a binding to root.source.
                // Pending loads keep their original server/path identity.
                stateReader = stateReaderComponent.createObject(root, { context: next });
            }
        }
        if (next.stateFile === null)
            errorText = "File exposure is disabled for the selected tmux server";
    }

    function applyDocument(content, context) {
        if (!Model.sameServer(context, source) || context.stateFile !== source.stateFile)
            return;
        var document;
        try {
            document = JSON.parse(String(content || ""));
            if (!document || !Array.isArray(document.panes))
                throw new Error("missing panes array");
            if (!Model.sameServer(document, context))
                throw new Error("snapshot belongs to another server generation");
        } catch (error) {
            clearAgents();
            errorText = "Invalid tmux-argos state: " + error;
            return;
        }

        var next = Model.normalize(document, context);
        var signature = JSON.stringify(next);
        if (initialized && signature === dataSignature) {
            generatedAt = Number(document.generatedAt || 0);
            errorText = "";
            return;
        }
        if (initialized && notificationsEnabled) {
            var notices = Model.transitionNotices(previousStates, next);
            for (var i = 0; i < notices.length; i++)
                enqueueNotification(notices[i], Number(document.generatedAt || 0));
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

    function notificationId(row) {
        var value = String(row.key);
        var hash = 5381;
        for (var i = 0; i < value.length; i++)
            hash = ((hash * 33) ^ value.charCodeAt(i)) >>> 0;
        return 700000 + (hash % 1000000000);
    }

    property var notificationQueue: []

    function enqueueNotification(row, documentGeneratedAt) {
        var eventTime = Number(row.changedAt || documentGeneratedAt || 0);
        notificationQueue = notificationQueue.concat([{
            row: row,
            eventToken: row.state + ":" + String(eventTime)
        }]);
        runNextNotification();
    }

    function runNextNotification() {
        if (notificationProcess.running || notificationQueue.length === 0)
            return;
        var notice = notificationQueue[0];
        var row = notice.row;
        notificationQueue = notificationQueue.slice(1);
        var icon = localPath(Qt.resolvedUrl("assets/" + Model.iconFile(row.state)));
        var urgency = row.state === "blocked" ? "critical" : "normal";
        notificationProcess.command = ["bash", localPath(Qt.resolvedUrl("notify-agent.sh")), String(notificationId(row)), notice.eventToken, urgency, icon, row.agentName + " " + row.state, notificationBody(row)];
        notificationProcess.running = true;
    }

    Component {
        id: sourceReaderComponent
        FileView {
            property string requestedSocket: ""
            watchChanges: true
            printErrors: false
            onFileChanged: reload()
            onLoaded: root.applySource(text(), requestedSocket)
            onLoadFailed: {
                if (requestedSocket === root.configuredSocket)
                    root.invalidateSource("Argos source file not found: " + path);
            }
            Component.onCompleted: reload()
        }
    }

    Component {
        id: stateReaderComponent
        FileView {
            property var context: null
            path: context ? context.stateFile : ""
            watchChanges: true
            printErrors: false
            onFileChanged: reload()
            onLoaded: root.applyDocument(text(), context)
            onLoadFailed: {
                if (Model.sameServer(context, root.source) && context.stateFile === root.source.stateFile) {
                    root.clearAgents();
                    root.errorText = "State file not found: " + path;
                }
            }
            Component.onCompleted: reload()
        }
    }

    // Reload files only: covers atomic inode replacement and late creation.
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

    // The host injects settings after creation. Wait for the derived path:
    // configuredSocket can change before sourcePath has been recomputed.
    onSourcePathChanged: {
        if (ready)
            resetSourceReader();
    }
    Component.onCompleted: {
        ready = true;
        resetSourceReader();
    }
}
