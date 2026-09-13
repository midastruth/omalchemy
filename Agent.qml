import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
    id: root
    moduleName: "midas.omalchemy"
    ipcTarget: "midas.omalchemy"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    property var agentState: null
    readonly property var barIdentity: hostWidget || root

    readonly property color foreground: Color.popups.text
    readonly property color dim: Util.alpha(foreground, 0.58)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    readonly property var agents: agentState ? agentState.agents : []
    readonly property var counts: agentState ? agentState.counts : ({
            blocked: 0,
            working: 0,
            done: 0,
            idle: 0,
            total: 0
        })

    property int selectedIndex: 0
    property double nowSeconds: Date.now() / 1000
    property string jumpError: ""
    property bool settingsOpen: false

    readonly property bool showCount: setting("showCount", true) !== false
    readonly property bool notificationsEnabled: setting("notifications", true) !== false

    function persistWidgetSettings(overrides) {
        var entry = { id: root.moduleName };
        var current = settings && typeof settings === "object" && !Array.isArray(settings) ? settings : {};
        for (var key in current) {
            if (key !== "id" && key !== "__proto__" && key !== "constructor" && key !== "prototype")
                entry[key] = current[key];
        }
        for (var overrideKey in overrides) {
            if (overrideKey !== "id" && overrideKey !== "__proto__" && overrideKey !== "constructor" && overrideKey !== "prototype")
                entry[overrideKey] = overrides[overrideKey];
        }

        root.settings = entry;
        if (hostWidget && "settings" in hostWidget)
            hostWidget.settings = entry;
        if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
            bar.shell.updateEntryInline(root.moduleName, entry);
    }

    function setShowCount(enabled) {
        persistWidgetSettings({ showCount: enabled === true });
    }

    function setNotificationsEnabled(enabled) {
        persistWidgetSettings({ notifications: enabled === true });
    }

    function clampSelection() {
        if (agents.length === 0)
            selectedIndex = 0;
        else
            selectedIndex = Math.max(0, Math.min(selectedIndex, agents.length - 1));
    }

    function moveSelection(delta) {
        if (agents.length === 0)
            return;
        selectedIndex = ((selectedIndex + delta) % agents.length + agents.length) % agents.length;
        Qt.callLater(ensureSelectionVisible);
    }

    function ensureSelectionVisible() {
        var item = agentRepeater.itemAt(selectedIndex);
        if (!item)
            return;
        var top = item.y;
        var bottom = top + item.height;
        if (top < listFlick.contentY)
            listFlick.contentY = top;
        else if (bottom > listFlick.contentY + listFlick.height)
            listFlick.contentY = Math.max(0, bottom - listFlick.height);
    }

    function refresh() {
        if (agentState)
            agentState.refresh();
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

    function jump(row) {
        if (!row || jumpProcess.running)
            return;
        jumpError = "";
        jumpProcess.command = ["bash", localPath(Qt.resolvedUrl("jump-agent.sh")), row.paneId, row.sessionName, String(row.windowIndex), String(row.paneIndex)];
        jumpProcess.running = true;
        close();
    }

    function jumpSelected() {
        if (agents.length > 0)
            jump(agents[selectedIndex]);
    }

    function statusColor(state) {
        return Model.stateColor(state, dim);
    }

    function statusSummary() {
        if (!counts || counts.total === 0)
            return "No agents running";
        var parts = [];
        if (counts.blocked)
            parts.push(counts.blocked + " blocked");
        if (counts.working)
            parts.push(counts.working + " working");
        if (counts.done)
            parts.push(counts.done + " done");
        if (counts.idle)
            parts.push(counts.idle + " idle");
        return parts.join(" · ");
    }

    function changedText(seconds) {
        var value = Number(seconds || 0);
        if (!(value > 0))
            return "changed time unknown";
        var age = Math.floor(nowSeconds - value);
        if (age >= 0 && age < 60)
            return "changed " + Math.max(0, age) + "s ago";
        if (age >= 60 && age < 3600)
            return "changed " + Math.floor(age / 60) + "m ago";
        if (age >= 3600 && age < 86400)
            return "changed " + Math.floor(age / 3600) + "h ago";
        return "changed " + new Date(value * 1000).toLocaleString(Qt.locale(), "MMM d HH:mm");
    }

    function locationText(row) {
        if (!row)
            return "";
        var target = row.sessionName + ":" + row.windowIndex + "." + row.paneIndex;
        var flags = [];
        flags.push(row.visible ? "visible" : "hidden");
        flags.push(row.sessionAttached ? "attached" : "detached");
        return target + " · " + flags.join(" · ") + " · " + changedText(row.changedAt);
    }

    onOpenedChanged: {
        if (opened) {
            refresh();
            clampSelection();
            nowSeconds = Date.now() / 1000;
            Qt.callLater(function () {
                keyCatcher.forceActiveFocus();
                root.ensureSelectionVisible();
            });
        } else {
            settingsOpen = false;
        }
    }

    Connections {
        target: root.agentState
        enabled: !!root.agentState
        function onAgentsChanged() {
            root.clampSelection();
            Qt.callLater(root.ensureSelectionVisible);
        }
    }

    Timer {
        interval: 30000
        running: root.opened
        repeat: true
        onTriggered: root.nowSeconds = Date.now() / 1000
    }

    Process {
        id: jumpProcess
        running: false
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.jumpError = String(text || "").trim()
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(440))
        contentHeight: panel.fittedContentHeight(Math.min(fixedHeader.implicitHeight + Style.space(10) + contentColumn.implicitHeight, Style.space(620)))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent

            onMoveRequested: function (dx, dy) {
                if (dy !== 0)
                    root.moveSelection(dy);
            }
            onActivateRequested: if (!root.settingsOpen) root.jumpSelected()
            onCloseRequested: root.close()
            onTabRequested: function (direction) {
                root.switchPanel(direction);
            }
            onTextKey: function (text) {
                if ((text === "r" || text === "R") && !root.settingsOpen)
                    root.refresh();
                else if (text === "s" || text === "S")
                    root.settingsOpen = !root.settingsOpen;
            }

            Column {
                id: fixedHeader
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(10)

                Item {
                    width: parent.width
                    height: Math.max(titleColumn.implicitHeight, headerActions.implicitHeight)

                    Column {
                        id: titleColumn
                        anchors.left: parent.left
                        anchors.right: headerActions.left
                        anchors.rightMargin: Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)

                        Text {
                            width: parent.width
                            text: root.settingsOpen ? "SETTINGS" : "OMALCHEMY"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                            font.letterSpacing: 1.4
                        }

                        Text {
                            width: parent.width
                            text: root.settingsOpen ? "Display and notification preferences" : root.statusSummary()
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        id: headerActions
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)

                        PanelActionButton {
                            visible: !root.settingsOpen
                            iconText: "󰑐"
                            tooltipText: "Reload state (r)"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.refresh()
                        }

                        PanelActionButton {
                            iconText: root.settingsOpen ? "󰁍" : "󰒓"
                            tooltipText: root.settingsOpen ? "Back to agents" : "Settings (s)"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.settingsOpen = !root.settingsOpen
                        }
                    }
                }

                PanelSeparator {
                    width: parent.width
                    foreground: root.foreground
                }
            }

            Flickable {
                id: listFlick
                anchors.top: fixedHeader.bottom
                anchors.topMargin: Style.space(10)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                contentWidth: width
                contentHeight: contentColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                QQC.ScrollBar.vertical: QQC.ScrollBar {
                    policy: QQC.ScrollBar.AsNeeded
                }

                Column {
                    id: contentColumn
                    width: listFlick.width
                    spacing: Style.space(10)

                    Column {
                        visible: root.settingsOpen
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSectionHeader {
                            text: "STATUS BAR"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        Toggle {
                            width: parent.width
                            label: "Show agent count"
                            description: "Show the dominant state count next to the status icon."
                            checked: root.showCount
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.setShowCount(!root.showCount)
                        }

                        PanelSectionHeader {
                            text: "NOTIFICATIONS"
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                        }

                        Toggle {
                            width: parent.width
                            label: "Enable notifications"
                            description: "Notify when an agent becomes blocked or done."
                            checked: root.notificationsEnabled
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.setNotificationsEnabled(!root.notificationsEnabled)
                        }

                        Text {
                            width: parent.width
                            topPadding: Style.space(4)
                            text: "Changes apply immediately · s back · Esc close"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    Text {
                        visible: !root.settingsOpen && root.agents.length === 0
                        width: parent.width
                        topPadding: Style.space(24)
                        bottomPadding: Style.space(24)
                        text: root.agentState && root.agentState.errorText !== "" ? root.agentState.errorText : "No Pi, Codex, or Claude panes are running."
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                    }

                    Repeater {
                        id: agentRepeater
                        model: root.settingsOpen ? [] : root.agents

                        BorderSurface {
                            id: agentRow
                            required property var modelData
                            required property int index

                            width: contentColumn.width
                            implicitHeight: rowContent.implicitHeight + Style.space(20)
                            radius: Style.cornerRadius
                            color: index === root.selectedIndex ? Style.selectedFillFor(root.foreground, Color.accent) : rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : Style.normalFillFor(root.foreground, Color.accent)
                            borderSpec: index === root.selectedIndex ? Border.controlSpec("hover-cursor", root.foreground, Color.accent) : Border.none()

                            Column {
                                id: rowContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Style.space(12)
                                anchors.rightMargin: Style.space(12)
                                spacing: Style.space(5)

                                Item {
                                    width: parent.width
                                    height: Math.max(agentTitle.implicitHeight, stateLabel.implicitHeight)

                                    Text {
                                        id: agentTitle
                                        anchors.left: parent.left
                                        anchors.right: stateLabel.left
                                        anchors.rightMargin: Style.space(10)
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.agentName + "  ·  " + modelData.projectName
                                        color: root.foreground
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        id: stateLabel
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "●  " + Model.stateLabel(modelData.state)
                                        color: root.statusColor(modelData.state)
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        font.bold: true
                                    }
                                }

                                Text {
                                    width: parent.width
                                    text: modelData.currentPath || "Unknown project"
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    elide: Text.ElideMiddle
                                }

                                Text {
                                    width: parent.width
                                    text: root.locationText(modelData)
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    elide: Text.ElideRight
                                }
                            }

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.selectedIndex = index
                                onClicked: root.jump(modelData)
                            }
                        }
                    }

                    Text {
                        visible: !root.settingsOpen && root.agents.length > 0
                        width: parent.width
                        topPadding: Style.space(2)
                        text: "j/k select · Enter/click jump · r reload · s settings · Esc close"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }
        }
    }
}
