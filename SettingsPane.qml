import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts

Rectangle {
    id: pane
    color: pane.theme.raisedSurface
    gradient: Gradient {
        GradientStop {
            position: 0
            color: pane.theme.raisedSurfaceTop
            Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
        }
        GradientStop {
            position: 1
            color: pane.theme.raisedSurfaceBottom
            Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
        }
    }
    radius: pane.theme.overlayRadius
    border.color: pane.theme.strongBorder
    Behavior on border.color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
    layer.enabled: true
    layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: pane.theme.panelShadow
        shadowBlur: 0.65
        blurMax: 20
        shadowVerticalOffset: 4
    }

    property real textScale: 1.0
    property var theme
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
        contentHeight: form.implicitHeight + 80
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: form
            x: Math.max(24, (parent.width - 640) / 2)
            y: 40
            width: Math.min(parent.width - 48, 640)
            spacing: pane.theme.baseSpacing

            Text {
                Layout.fillWidth: true
                text: pane.setupRequired ? "Connect Tightbeam Tuner" : "Connection settings"
                color: pane.theme.foreground
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(28 * pane.textScale)
                font.bold: true
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Enter your Chat server URL, gateway, and the Tightbeam CLI used to list agents."
                color: pane.theme.secondary
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(15 * pane.textScale)
            }

            Text { text: "Chat server URL"; color: pane.theme.foreground; font.family: pane.theme.fontFamily; font.pixelSize: Math.round(13 * pane.textScale) }
            TextField {
                id: chatInput
                Layout.fillWidth: true
                placeholderText: "https://chat.example.com"
                color: pane.theme.foreground
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(15 * pane.textScale)
                placeholderTextColor: pane.theme.placeholder
                selectByMouse: true
                background: Rectangle {
                    radius: pane.theme.smallRadius
                    color: pane.theme.field
                    border.color: chatInput.activeFocus ? pane.theme.focus : pane.theme.fieldBorder
                    Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Text { text: "Gateway URL"; color: pane.theme.foreground; font.family: pane.theme.fontFamily; font.pixelSize: Math.round(13 * pane.textScale) }
                Item { Layout.fillWidth: true }
                TunerButton {
                    theme: pane.theme
                    text: "Find from Chat"
                    font.pixelSize: Math.round(13 * pane.textScale)
                    onClicked: pane.discoverRequested()
                }
            }
            TextField {
                id: gatewayInput
                Layout.fillWidth: true
                placeholderText: "https://gateway.example.com"
                color: pane.theme.foreground
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(15 * pane.textScale)
                placeholderTextColor: pane.theme.placeholder
                selectByMouse: true
                background: Rectangle {
                    radius: pane.theme.smallRadius
                    color: pane.theme.field
                    border.color: gatewayInput.activeFocus ? pane.theme.focus : pane.theme.fieldBorder
                    Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                }
            }

            Text { text: "Tightbeam CLI location"; color: pane.theme.foreground; font.family: pane.theme.fontFamily; font.pixelSize: Math.round(13 * pane.textScale) }
            TextField {
                id: cliInput
                Layout.fillWidth: true
                placeholderText: "tightbeam or /path/to/tightbeam"
                color: pane.theme.foreground
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(15 * pane.textScale)
                placeholderTextColor: pane.theme.placeholder
                selectByMouse: true
                background: Rectangle {
                    radius: pane.theme.smallRadius
                    color: pane.theme.field
                    border.color: cliInput.activeFocus ? pane.theme.focus : pane.theme.fieldBorder
                    Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                }
            }
            Text { text: "Tightbeam user"; color: pane.theme.foreground; font.family: pane.theme.fontFamily; font.pixelSize: Math.round(13 * pane.textScale) }
            TextField {
                id: userInput
                Layout.fillWidth: true
                placeholderText: "your-name"
                color: pane.theme.foreground
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(15 * pane.textScale)
                placeholderTextColor: pane.theme.placeholder
                selectByMouse: true
                background: Rectangle {
                    radius: pane.theme.smallRadius
                    color: pane.theme.field
                    border.color: userInput.activeFocus ? pane.theme.focus : pane.theme.fieldBorder
                    Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                }
                onAccepted: pane.saveRequested()
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Tuner runs the CLI to read the agent tree. For a remote installation, use a prefix like ssh host /path/to/tightbeam. Do not enter passwords or tokens."
                color: pane.theme.muted
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(12 * pane.textScale)
            }

            Text {
                Layout.fillWidth: true
                visible: pane.message.length > 0
                wrapMode: Text.WordWrap
                text: pane.message
                color: pane.theme.error
                font.family: pane.theme.fontFamily
                font.pixelSize: Math.round(13 * pane.textScale)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: pane.theme.smallRadius
                TunerButton {
                    theme: pane.theme
                    prominent: true
                    text: pane.saving ? "Connecting…" : "Save and connect"
                    enabled: !pane.saving
                    font.pixelSize: Math.round(15 * pane.textScale)
                    onClicked: pane.saveRequested()
                }
                TunerButton {
                    theme: pane.theme
                    visible: !pane.setupRequired
                    text: "Back to chat"
                    font.pixelSize: Math.round(15 * pane.textScale)
                    onClicked: pane.closeRequested()
                }
            }
        }
    }
}
