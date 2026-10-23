//@ pragma AppId tightbeam-tuner
//@ pragma StateDir $BASE/tightbeam-tuner
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
