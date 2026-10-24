import QtQuick
import QtQuick.Controls

// Button in the Nordic palette. Prominent buttons fill with the moss accent, like Chat's
// send button; others use the glass surface of Chat's floating controls.
Button {
    id: control
    property var theme
    property bool prominent: false

    padding: 8
    leftPadding: 14
    rightPadding: 14
    opacity: enabled ? 1 : 0.55

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.prominent ? control.theme.onAccent : control.theme.foreground
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        radius: height / 2
        color: control.prominent ? control.theme.accent
             : control.hovered ? control.theme.hover : control.theme.button
        border.color: control.visualFocus ? control.theme.focus
                    : control.prominent ? "transparent" : control.theme.buttonBorder
        border.width: control.visualFocus ? 2 : 1
    }
}
