import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine
import Quickshell
import Quickshell.Io

FloatingWindow {
    id: win
    title: selectedAgent ? "Tightbeam Tuner — " + selectedAgent.name : "Tightbeam Tuner"
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(640, 420)
    color: "#11151c"

    signal newWindowRequested()

    property var agents: []
    property var selectedAgent: null
    property bool sidebarOpen: false
    property int sidebarWidth: 270
    property string sidebarQuery: ""
    property var collapsed: ({})
    property var selectedArchetypes: ({})
    property bool archetypesExpanded: false
    property bool pickerOpen: true
    property int pickerIndex: 0
    property string rosterError: ""
    property var visibleRows: buildRows()
    property var archetypes: buildArchetypes()
    property var pickerMatches: buildPickerMatches()

    function buildArchetypes() {
        const found = {}
        for (const agent of agents) found[agent.archetype] = true
        return Object.keys(found).sort((a, b) => a.localeCompare(b))
    }

    function archetypeAllowed(agent) {
        const selected = Object.keys(selectedArchetypes).filter(k => selectedArchetypes[k])
        return selected.length === 0 || selected.indexOf(agent.archetype) !== -1
    }

    function buildRows() {
        const query = sidebarQuery.trim().toLocaleLowerCase()
        const archetypeFilterActive = Object.keys(selectedArchetypes).some(k => selectedArchetypes[k])
        const byKey = {}
        const children = {}
        const roots = []
        for (const agent of agents) {
            byKey[agent.key] = agent
            children[agent.key] = []
        }
        for (const agent of agents) {
            if (agent.parent && byKey[agent.parent] && agent.parent !== agent.key)
                children[agent.parent].push(agent)
            else roots.push(agent)
        }
        const compare = (a, b) => a.name.localeCompare(b.name)
        roots.sort(compare)
        for (const key of Object.keys(children)) children[key].sort(compare)
        const result = []
        const visited = {}
        function visit(agent, depth) {
            if (visited[agent.key]) return false
            visited[agent.key] = true
            const start = result.length
            const row = { agent: agent, depth: depth, hasChildren: children[agent.key].length > 0,
                          contextOnly: false }
            result.push(row)
            const ownMatch = win.archetypeAllowed(agent) &&
                (!query || agent.name.toLocaleLowerCase().includes(query))
            let descendantMatch = false
            if (query || archetypeFilterActive || !win.collapsed[agent.key]) {
                for (const child of children[agent.key]) {
                    if (visit(child, depth + 1)) descendantMatch = true
                }
            }
            if (!ownMatch && !descendantMatch) {
                result.splice(start)
                return false
            }
            row.contextOnly = !ownMatch
            return true
        }
        for (const root of roots) visit(root, 0)
        return result
    }

    function buildPickerMatches() {
        const query = pickerInput.text.trim().toLocaleLowerCase()
        const matches = agents.filter(agent => agent.name.toLocaleLowerCase().includes(query))
        matches.sort((a, b) => {
            const ap = a.name.toLocaleLowerCase().startsWith(query) ? 0 : 1
            const bp = b.name.toLocaleLowerCase().startsWith(query) ? 0 : 1
            return ap - bp || a.name.localeCompare(b.name)
        })
        return matches.slice(0, 12)
    }

    function selectAgent(agent) {
        selectedAgent = agent
        pickerOpen = false
        pickerInput.text = ""
        chat.forceActiveFocus()
    }

    function showPicker() {
        pickerOpen = true
        pickerIndex = 0
        pickerInput.text = ""
        Qt.callLater(() => pickerInput.forceActiveFocus())
    }

    function showSidebarSearch() {
        sidebarOpen = true
        Qt.callLater(() => sidebarInput.forceActiveFocus())
    }

    function toggleArchetype(archetype) {
        const next = Object.assign({}, selectedArchetypes)
        next[archetype] = !next[archetype]
        selectedArchetypes = next
    }

    Component.onCompleted: Qt.callLater(() => pickerInput.forceActiveFocus())
    onVisibleChanged: if (!visible) destroy()

    Shortcut { sequence: "Ctrl+N"; context: Qt.WindowShortcut; onActivated: win.newWindowRequested() }
    Shortcut { sequence: "Ctrl+Space"; context: Qt.WindowShortcut; onActivated: win.showPicker() }
    Shortcut { sequence: "Ctrl+/"; context: Qt.WindowShortcut; onActivated: win.showSidebarSearch() }
    Shortcut { sequence: "Ctrl+\\"; context: Qt.WindowShortcut; onActivated: win.sidebarOpen = !win.sidebarOpen }

    Process {
        id: rosterProcess
        command: ["python3", Quickshell.shellDir + "/scripts/roster.py"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text)
                    if (data.error) {
                        win.rosterError = data.error
                    } else {
                        win.agents = data.agents
                        win.rosterError = ""
                    }
                } catch (error) {
                    win.rosterError = "Could not read the agent roster"
                }
            }
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: if (!rosterProcess.running) rosterProcess.running = true
    }

    Item {
        anchors.fill: parent

        Rectangle {
            id: sidebar
            visible: win.sidebarOpen
            width: win.sidebarOpen ? win.sidebarWidth : 0
            height: parent.height
            color: "#19212c"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "AGENTS"; color: "#aebbd0"; font.pixelSize: 12; font.bold: true; font.letterSpacing: 1.5 }
                    Item { Layout.fillWidth: true }
                    Text { text: String(win.visibleRows.length); color: "#7e91a8"; font.pixelSize: 12 }
                }

                ListView {
                    id: agentList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: win.visibleRows
                    spacing: 2
                    delegate: Rectangle {
                        required property var modelData
                        readonly property var row: modelData
                        width: agentList.width
                        height: 34
                        radius: 7
                        color: win.selectedAgent && win.selectedAgent.key === row.agent.key ? "#30465f" :
                               mouse.containsMouse ? "#253141" : "transparent"

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Math.min(row.depth, 8) * 14 + 4
                            spacing: 4
                            Rectangle {
                                width: 20; height: 30; color: "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: row.hasChildren ? (win.collapsed[row.agent.key] && !sidebarInput.text ? "▸" : "▾") : ""
                                    color: "#91a5bd"; font.pixelSize: 15
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: row.hasChildren
                                    onClicked: {
                                        const next = Object.assign({}, win.collapsed)
                                        next[row.agent.key] = !next[row.agent.key]
                                        win.collapsed = next
                                    }
                                }
                            }
                            Text {
                                width: Math.max(60, agentList.width - parent.anchors.leftMargin - 32)
                                height: 30
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                text: row.agent.name
                                color: row.contextOnly ? "#8295ad" : "#e9eef5"
                                font.pixelSize: 14
                            }
                        }
                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            anchors.leftMargin: Math.min(row.depth, 8) * 14 + 28
                            hoverEnabled: true
                            onClicked: win.selectAgent(row.agent)
                        }
                    }
                }

                TextField {
                    id: sidebarInput
                    Layout.fillWidth: true
                    placeholderText: "Filter agents"
                    text: win.sidebarQuery
                    onTextChanged: win.sidebarQuery = text
                    color: "#eef4fc"
                    selectByMouse: true
                    background: Rectangle { radius: 7; color: "#101923"; border.color: sidebarInput.activeFocus ? "#79b7ec" : "#3b4b5f" }
                    Keys.onUpPressed: agentList.positionViewAtBeginning()
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: archetypeColumn.implicitHeight + 12
                    radius: 7
                    color: "#101923"
                    border.color: "#3b4b5f"
                    Column {
                        id: archetypeColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6
                        spacing: 2
                        Rectangle {
                            width: parent.width; height: 27; color: "transparent"
                            Text {
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                text: "Archetypes"; color: "#afc0d4"; font.pixelSize: 12
                            }
                            Text {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                text: win.archetypesExpanded ? "▴" : "▾"; color: "#afc0d4"
                            }
                            MouseArea { anchors.fill: parent; onClicked: win.archetypesExpanded = !win.archetypesExpanded }
                        }
                        Repeater {
                            model: win.archetypesExpanded ? win.archetypes : []
                            delegate: CheckBox {
                                required property string modelData
                                text: modelData
                                width: archetypeColumn.width
                                checked: !!win.selectedArchetypes[modelData]
                                onClicked: win.toggleArchetype(modelData)
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            id: divider
            visible: win.sidebarOpen
            x: sidebar.width
            width: 6
            height: parent.height
            color: drag.containsMouse ? "#6593b9" : "#2e3c4c"
            MouseArea {
                id: drag
                anchors.fill: parent
                cursorShape: Qt.SplitHCursor
                hoverEnabled: true
                property real lastX: 0
                onPressed: lastX = mapToItem(win.contentItem, mouseX, 0).x
                onPositionChanged: if (pressed) {
                    const currentX = mapToItem(win.contentItem, mouseX, 0).x
                    win.sidebarWidth = Math.max(190, Math.min(480, win.sidebarWidth + currentX - lastX))
                    lastX = currentX
                }
            }
        }

        Item {
            id: rightPane
            x: win.sidebarOpen ? win.sidebarWidth + divider.width : 0
            width: parent.width - x
            height: parent.height

            WebEngineView {
                id: chat
                anchors.fill: parent
                visible: !!win.selectedAgent
                url: win.selectedAgent ? win.selectedAgent.url : "about:blank"
            }

            Rectangle {
                anchors.fill: parent
                visible: !win.selectedAgent
                color: "#11151c"
                Text {
                    anchors.centerIn: parent
                    text: win.rosterError ? win.rosterError : "Choose an agent to open Chat"
                    color: "#8ea2b8"; font.pixelSize: 16
                }
            }

            Rectangle {
                x: 12; y: 12; width: 34; height: 34
                radius: 8; color: "#263648"; border.color: "#4c6884"
                Text { anchors.centerIn: parent; text: win.sidebarOpen ? "◀" : "☰"; color: "#eef4fc"; font.pixelSize: 16 }
                MouseArea { anchors.fill: parent; onClicked: win.sidebarOpen = !win.sidebarOpen }
            }
        }

        Rectangle {
            anchors.fill: parent
            visible: win.pickerOpen
            z: 10
            color: "#a8000000"
            MouseArea { anchors.fill: parent; onClicked: if (win.selectedAgent) win.pickerOpen = false }

            Rectangle {
                width: Math.min(parent.width - 48, 600)
                height: Math.min(parent.height - 70, pickerColumn.implicitHeight + 24)
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.min(110, parent.height * 0.16)
                radius: 14
                color: "#1d2733"
                border.color: "#63809d"
                clip: true

                Column {
                    id: pickerColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 4

                    TextField {
                        id: pickerInput
                        width: parent.width
                        height: 46
                        placeholderText: "Find an agent…"
                        color: "#f4f8ff"; font.pixelSize: 18
                        selectByMouse: true
                        background: Rectangle { radius: 8; color: "#111923" }
                        onTextChanged: win.pickerIndex = 0
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Down) {
                                win.pickerIndex = Math.min(win.pickerIndex + 1, win.pickerMatches.length - 1)
                                event.accepted = true
                            } else if (event.key === Qt.Key_Up) {
                                win.pickerIndex = Math.max(0, win.pickerIndex - 1)
                                event.accepted = true
                            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                if (win.pickerMatches.length) win.selectAgent(win.pickerMatches[win.pickerIndex])
                                event.accepted = true
                            } else if (event.key === Qt.Key_Escape && win.selectedAgent) {
                                win.pickerOpen = false
                                event.accepted = true
                            }
                        }
                    }

                    Repeater {
                        model: win.pickerMatches
                        delegate: Rectangle {
                            required property int index
                            required property var modelData
                            width: pickerColumn.width
                            height: 36
                            radius: 7
                            color: index === win.pickerIndex ? "#36516c" : "transparent"
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                verticalAlignment: Text.AlignVCenter
                                text: modelData.name
                                color: "#eaf2fb"; font.pixelSize: 14
                                elide: Text.ElideRight
                            }
                            MouseArea { anchors.fill: parent; onClicked: win.selectAgent(modelData) }
                        }
                    }

                    Text {
                        visible: win.pickerMatches.length === 0
                        text: win.rosterError ? win.rosterError : "No matching agents"
                        color: "#a9b7c7"; font.pixelSize: 13
                        leftPadding: 10; topPadding: 9; bottomPadding: 9
                    }
                }
            }
        }
    }
}
