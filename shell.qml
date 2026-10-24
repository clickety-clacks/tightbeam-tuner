//@ pragma AppId tightbeam-tuner
//@ pragma StateDir $BASE/tightbeam-tuner
import QtQuick
import Quickshell

ShellRoot {
    id: shell

    property int openWindows: 0

    function newWindow() {
        openWindows += 1
        windowComponent.createObject(shell)
    }

    // Tuner is an app, not a shell: closing its last window quits it.
    function windowClosed() {
        openWindows -= 1
        if (openWindows <= 0) Qt.callLater(Qt.quit)
    }

    Component {
        id: windowComponent
        TunerWindow {
            onNewWindowRequested: shell.newWindow()
            Component.onDestruction: shell.windowClosed()
        }
    }

    Component.onCompleted: newWindow()
}
