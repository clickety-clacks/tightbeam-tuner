//@ pragma AppId tightbeam-tuner
import QtQuick
import Quickshell

ShellRoot {
    id: shell

    function newWindow() {
        windowComponent.createObject(shell)
    }

    Component {
        id: windowComponent
        TunerWindow {
            onNewWindowRequested: shell.newWindow()
        }
    }

    Component.onCompleted: newWindow()
}
