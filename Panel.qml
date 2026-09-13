import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
    id: root
    moduleName: "midas.tmux-argos"

    readonly property var panelItem: panelLoader.item
    readonly property bool opened: panelItem ? panelItem.opened === true : false
    readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

    function injectPanel() {
        var target = panelItem;
        if (!target)
            return;
        if ("bar" in target)
            target.bar = root.bar;
        if ("settings" in target)
            target.settings = root.settings;
        if ("anchorItem" in target)
            target.anchorItem = button;
        if ("hostWidget" in target)
            target.hostWidget = root;
        if ("agentState" in target)
            target.agentState = state;
    }

    function open() {
        if (panelItem)
            panelItem.open();
    }
    function close() {
        if (panelItem)
            panelItem.close();
    }
    function toggle() {
        if (panelItem)
            panelItem.toggle();
    }
    function refresh() {
        state.refresh();
    }
    function closeForPopoutSwitch() {
        if (panelItem)
            panelItem.closeForPopoutSwitch();
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Main {
        id: state
        settings: root.settings
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Agent.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    IpcHandler {
        target: "midas.tmux-argos"
        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
        function toggle(): void {
            root.toggle();
        }
        function refresh(): string {
            root.refresh();
            return "ok";
        }
        function status(): string {
            return state.tooltipText;
        }
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: " "
        labelVisible: false
        hasVisualContent: true
        tooltipText: state.tooltipText
        fixedWidth: root.vertical ? root.barSize : horizontalChip.implicitWidth + Style.spaceReal(17)
        fixedHeight: root.vertical ? verticalChip.implicitHeight + Style.space(8) : -1

        onPressed: function (mouseButton) {
            if (mouseButton === Qt.LeftButton)
                root.toggle();
        }

        Row {
            id: horizontalChip
            anchors.centerIn: parent
            spacing: Style.space(5)
            visible: !root.vertical

            AgentIcon {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(13)
                height: Style.space(16)
                color: button.foreground
            }

            Text {
                visible: state.dominantCount > 0
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: String(state.dominantCount)
                color: Model.stateColor(state.dominantState, button.foreground)
                font.family: button.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
            }
        }

        Column {
            id: verticalChip
            anchors.centerIn: parent
            spacing: Style.space(2)
            visible: root.vertical

            AgentIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(11)
                height: Style.space(14)
                color: button.foreground
            }

            Text {
                visible: state.dominantCount > 0
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: String(state.dominantCount)
                color: Model.stateColor(state.dominantState, button.foreground)
                font.family: button.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
            }
        }
    }
}
