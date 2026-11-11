import QtQuick
import QtQuick.Controls

// Quiet action button shared by Tuner's desktop settings and picker affordances.
Button {
    id: control
    property var theme
    property bool prominent: false

    padding: 8
    leftPadding: 14
    rightPadding: 14
    font.family: control.theme.fontFamily

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.enabled
               ? (control.prominent ? control.theme.onAccent : control.theme.foreground)
               : control.theme.disabledText
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        radius: control.theme.smallRadius
        color: !control.enabled ? control.theme.disabledButton
             : control.prominent ? (control.down ? control.theme.accentPressed
                                  : control.hovered ? control.theme.accentHover : control.theme.accent)
             : control.down ? control.theme.buttonPressed
             : control.hovered ? control.theme.buttonHover : control.theme.button
        border.color: control.visualFocus ? control.theme.focus
                    : control.prominent ? "transparent" : control.theme.buttonBorder
        border.width: control.visualFocus ? 2 : 1
        Behavior on border.color {
            ColorAnimation { duration: 200; easing.type: Easing.InOutQuad }
        }

        Behavior on color {
            ColorAnimation { duration: 200; easing.type: Easing.InOutQuad }
        }
    }
}
