import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: pane
    color: "#111923"
    radius: 14
    border.color: "#63809d"

    property real textScale: 1.0
    property bool setupRequired: false
    property bool saving: false
    property string message: ""
    property alias chatBase: chatInput.text
    property alias gatewayOrigin: gatewayInput.text
    property alias cliCommand: cliInput.text
    property alias rosterUser: userInput.text

    signal saveRequested()
    signal closeRequested()
    signal discoverRequested()

    MouseArea { anchors.fill: parent; onClicked: {} }

    function focusFirst() {
        Qt.callLater(() => chatInput.forceActiveFocus())
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: form.implicitHeight + 96
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: form
            x: Math.max(28, (parent.width - 640) / 2)
            y: 48
            width: Math.min(parent.width - 56, 640)
            spacing: 12

            Text {
                Layout.fillWidth: true
                text: pane.setupRequired ? "Connect Tightbeam Tuner" : "Connection settings"
                color: "#eef4fc"
                font.pixelSize: Math.round(26 * pane.textScale)
                font.bold: true
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Enter your Chat server URL, gateway, and the Tightbeam CLI used to list agents."
                color: "#aebed0"
                font.pixelSize: Math.round(14 * pane.textScale)
            }

            Text { text: "Chat server URL"; color: "#dce7f4"; font.pixelSize: Math.round(13 * pane.textScale) }
            TextField {
                id: chatInput
                Layout.fillWidth: true
                placeholderText: "https://chat.example.com"
                color: "#f3f7fd"
                font.pixelSize: Math.round(14 * pane.textScale)
                selectByMouse: true
                background: Rectangle { radius: 7; color: "#192634"; border.color: chatInput.activeFocus ? "#79b7ec" : "#42576d" }
            }

            RowLayout {
                Layout.fillWidth: true
                Text { text: "Gateway URL"; color: "#dce7f4"; font.pixelSize: Math.round(13 * pane.textScale) }
                Item { Layout.fillWidth: true }
                Button {
                    text: "Find from Chat"
                    font.pixelSize: Math.round(12 * pane.textScale)
                    onClicked: pane.discoverRequested()
                }
            }
            TextField {
                id: gatewayInput
                Layout.fillWidth: true
                placeholderText: "https://gateway.example.com"
                color: "#f3f7fd"
                font.pixelSize: Math.round(14 * pane.textScale)
                selectByMouse: true
                background: Rectangle { radius: 7; color: "#192634"; border.color: gatewayInput.activeFocus ? "#79b7ec" : "#42576d" }
            }

            Text { text: "Tightbeam CLI location"; color: "#dce7f4"; font.pixelSize: Math.round(13 * pane.textScale) }
            TextField {
                id: cliInput
                Layout.fillWidth: true
                placeholderText: "tightbeam or /path/to/tightbeam"
                color: "#f3f7fd"
                font.pixelSize: Math.round(14 * pane.textScale)
                selectByMouse: true
                background: Rectangle { radius: 7; color: "#192634"; border.color: cliInput.activeFocus ? "#79b7ec" : "#42576d" }
            }
            Text { text: "Tightbeam user"; color: "#dce7f4"; font.pixelSize: Math.round(13 * pane.textScale) }
            TextField {
                id: userInput
                Layout.fillWidth: true
                placeholderText: "your-name"
                color: "#f3f7fd"
                font.pixelSize: Math.round(14 * pane.textScale)
                selectByMouse: true
                background: Rectangle { radius: 7; color: "#192634"; border.color: userInput.activeFocus ? "#79b7ec" : "#42576d" }
                onAccepted: pane.saveRequested()
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Tuner runs the CLI to read the agent tree. For a remote installation, use a prefix like ssh host /path/to/tightbeam. Do not enter passwords or tokens."
                color: "#8297ad"
                font.pixelSize: Math.round(12 * pane.textScale)
            }

            Text {
                Layout.fillWidth: true
                visible: pane.message.length > 0
                wrapMode: Text.WordWrap
                text: pane.message
                color: "#f0ad9d"
                font.pixelSize: Math.round(13 * pane.textScale)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Button {
                    text: pane.saving ? "Connecting…" : "Save and connect"
                    enabled: !pane.saving
                    font.pixelSize: Math.round(14 * pane.textScale)
                    onClicked: pane.saveRequested()
                }
                Button {
                    visible: !pane.setupRequired
                    text: "Back to chat"
                    font.pixelSize: Math.round(14 * pane.textScale)
                    onClicked: pane.closeRequested()
                }
            }
        }
    }
}
