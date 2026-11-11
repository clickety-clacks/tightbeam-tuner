import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import QtWebEngine
import Quickshell
import Quickshell.Io

FloatingWindow {
    id: win
    title: settingsOpen && settingsKnown ? "Tightbeam Tuner — Connection settings" :
           selectedAgent ? "Tightbeam Tuner — " + selectedAgent.name : "Tightbeam Tuner"
    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(640, 420)
    color: colors.window

    TunerPalette { id: colors }

    signal newWindowRequested()

    property var agents: []
    property var selectedAgent: null
    property bool sidebarOpen: false
    property int sidebarWidth: 270
    property string sidebarQuery: ""
    property var collapsed: ({})
    property var selectedArchetypes: ({})
    property bool archetypesExpanded: false
    property bool pickerOpen: false
    property int pickerIndex: 0
    property string rosterError: ""
    property bool configured: false
    property bool settingsOpen: true
    property bool settingsKnown: false
    property bool connecting: false
    property var pendingSettings: ({})
    property var currentSettings: ({})
    property real textScale: 1.0
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
        const words = pickerInput.text.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean)
        const matches = agents.filter(agent => {
            const name = agent.name.toLocaleLowerCase()
            return words.every(word => name.includes(word))
        })
        matches.sort((a, b) => {
            const firstWord = words[0] || ""
            const ap = a.name.toLocaleLowerCase().startsWith(firstWord) ? 0 : 1
            const bp = b.name.toLocaleLowerCase().startsWith(firstWord) ? 0 : 1
            return ap - bp || a.name.localeCompare(b.name)
        })
        return matches.slice(0, 12)
    }

    function selectAgent(agent) {
        selectedAgent = agent
        pickerOpen = false
        settingsOpen = false
        pickerInput.text = ""
        chat.forceActiveFocus()
    }

    function showPicker() {
        if (!configured) {
            openSettings()
            return
        }
        settingsOpen = false
        pickerOpen = true
        pickerIndex = 0
        pickerInput.text = ""
        Qt.callLater(() => pickerInput.forceActiveFocus())
    }

    function showSidebarSearch() {
        if (!configured) {
            openSettings()
            return
        }
        sidebarOpen = true
        Qt.callLater(() => sidebarInput.forceActiveFocus())
    }

    function toggleArchetype(archetype) {
        const next = Object.assign({}, selectedArchetypes)
        next[archetype] = !next[archetype]
        selectedArchetypes = next
    }

    function changeTextScale(steps) {
        const next = Math.max(0.7, Math.min(2.0, Math.round((textScale + steps * 0.1) * 10) / 10))
        if (next === textScale) return
        textScale = next
        preferences.setText(JSON.stringify({ textScale: next }))
    }

    function restoreTextScale() {
        try {
            const saved = JSON.parse(preferences.text())
            if (typeof saved.textScale === "number" && isFinite(saved.textScale))
                textScale = Math.max(0.7, Math.min(2.0, Math.round(saved.textScale * 10) / 10))
        } catch (error) {
            // The default size applies until a preference has been saved.
        }
    }

    function openExternalLink(url) {
        const target = url.toString()
        if (/^https?:\/\//i.test(target) && !Qt.openUrlExternally(target))
            console.warn("Could not open link in the browser")
    }

    function openSettings() {
        if (!settingsOpen && configured) {
            settingsPane.chatBase = currentSettings.chatBase || ""
            settingsPane.gatewayOrigin = currentSettings.gatewayOrigin || ""
            settingsPane.cliCommand = currentSettings.cliCommand || "tightbeam"
            settingsPane.rosterUser = currentSettings.rosterUser || ""
            settingsPane.message = ""
        }
        pickerOpen = false
        settingsOpen = true
        settingsPane.focusFirst()
    }

    function toggleSettings() {
        if (!settingsOpen || !configured || connecting) {
            openSettings()
        } else if (selectedAgent) {
            settingsOpen = false
            chat.forceActiveFocus()
        } else {
            showPicker()
        }
    }

    function startRoster() {
        connecting = true
        settingsPane.saving = true
        settingsPane.message = "Reading agents…"
        rosterProcess.running = false
        Qt.callLater(() => rosterProcess.running = true)
    }

    function saveSettings() {
        if (settingsSave.running || connecting) return
        pendingSettings = {
            chatBase: settingsPane.chatBase,
            gatewayOrigin: settingsPane.gatewayOrigin,
            cliCommand: settingsPane.cliCommand,
            rosterUser: settingsPane.rosterUser
        }
        settingsPane.saving = true
        settingsPane.message = ""
        settingsSave.running = true
    }

    function discoverGateway() {
        if (settingsDiscover.running) return
        settingsPane.message = "Checking Chat server…"
        settingsDiscover.running = true
    }

    onVisibleChanged: if (!visible) destroy()

    Shortcut { sequence: "Ctrl+N"; context: Qt.WindowShortcut; onActivated: win.newWindowRequested() }
    Shortcut { sequence: "Ctrl+Space"; context: Qt.WindowShortcut; onActivated: win.showPicker() }
    Shortcut { sequence: "Ctrl+/"; context: Qt.WindowShortcut; onActivated: win.showSidebarSearch() }
    Shortcut { sequence: "Ctrl+\\"; context: Qt.WindowShortcut; onActivated: win.sidebarOpen = !win.sidebarOpen }
    Shortcut { sequence: "Ctrl+="; context: Qt.WindowShortcut; onActivated: win.changeTextScale(1) }
    Shortcut { sequence: "Ctrl+-"; context: Qt.WindowShortcut; onActivated: win.changeTextScale(-1) }
    Shortcut { sequence: "Ctrl+,"; context: Qt.WindowShortcut; onActivated: win.toggleSettings() }
    Shortcut { sequence: "Ctrl+R"; context: Qt.WindowShortcut; onActivated: if (win.selectedAgent) chat.reload() }

    FileView {
        id: preferences
        path: Quickshell.statePath("preferences.json")
        blockLoading: true
        blockWrites: true
        printErrors: false
        onLoaded: win.restoreTextScale()
    }

    Process {
        id: settingsRead
        command: ["python3", Quickshell.shellDir + "/scripts/settings.py", "show"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text)
                    settingsPane.chatBase = data.chatBase || ""
                    settingsPane.gatewayOrigin = data.gatewayOrigin || ""
                    settingsPane.cliCommand = data.cliCommand || "tightbeam"
                    settingsPane.rosterUser = data.rosterUser || ""
                    win.configured = !!data.configured
                    win.settingsKnown = true
                    if (win.configured) {
                        win.currentSettings = data
                        win.settingsOpen = false
                        win.startRoster()
                    }
                    else {
                        settingsPane.message = data.error || "Enter your connection settings to start."
                        win.openSettings()
                    }
                } catch (error) {
                    win.settingsKnown = true
                    settingsPane.message = "Could not read connection settings"
                    win.openSettings()
                }
            }
        }
    }

    Process {
        id: settingsSave
        command: ["python3", Quickshell.shellDir + "/scripts/settings.py", "save"]
        stdinEnabled: true
        onStarted: write(JSON.stringify(win.pendingSettings) + "\n")
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text)
                    if (data.error) {
                        settingsPane.message = data.error
                        settingsPane.saving = false
                    } else {
                        win.configured = true
                        const changed = data.chatBase !== win.currentSettings.chatBase ||
                            data.gatewayOrigin !== win.currentSettings.gatewayOrigin ||
                            data.cliCommand !== win.currentSettings.cliCommand ||
                            data.rosterUser !== win.currentSettings.rosterUser
                        win.currentSettings = data
                        settingsPane.chatBase = data.chatBase
                        settingsPane.gatewayOrigin = data.gatewayOrigin
                        settingsPane.cliCommand = data.cliCommand
                        settingsPane.rosterUser = data.rosterUser
                        if (changed) {
                            win.selectedAgent = null
                            win.agents = []
                            win.startRoster()
                        } else {
                            settingsPane.saving = false
                            if (win.selectedAgent) {
                                win.settingsOpen = false
                                chat.forceActiveFocus()
                            } else win.showPicker()
                        }
                    }
                } catch (error) {
                    settingsPane.message = "Could not save connection settings"
                    settingsPane.saving = false
                }
            }
        }
    }

    Process {
        id: settingsDiscover
        command: ["python3", Quickshell.shellDir + "/scripts/settings.py", "discover"]
        stdinEnabled: true
        onStarted: write(JSON.stringify({ chatBase: settingsPane.chatBase }) + "\n")
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text)
                    if (data.error) settingsPane.message = data.error
                    else {
                        settingsPane.gatewayOrigin = data.gatewayOrigin
                        if (!settingsPane.rosterUser && data.rosterUser)
                            settingsPane.rosterUser = data.rosterUser
                        settingsPane.message = ""
                    }
                } catch (error) {
                    settingsPane.message = "Could not read Chat server settings"
                }
            }
        }
    }

    Process {
        id: rosterProcess
        command: ["python3", Quickshell.shellDir + "/scripts/roster.py"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(this.text)
                    if (data.error) {
                        win.rosterError = data.error
                        if (win.connecting) {
                            win.connecting = false
                            settingsPane.saving = false
                            win.openSettings()
                            settingsPane.message = data.error
                        }
                    } else {
                        win.agents = data.agents
                        win.rosterError = ""
                        if (win.connecting) {
                            win.connecting = false
                            settingsPane.saving = false
                            settingsPane.message = ""
                            win.showPicker()
                        }
                    }
                } catch (error) {
                    win.rosterError = "Could not read the agent roster"
                    if (win.connecting) {
                        win.connecting = false
                        settingsPane.saving = false
                        win.openSettings()
                        settingsPane.message = win.rosterError
                    }
                }
            }
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: if (win.configured && !rosterProcess.running) rosterProcess.running = true
    }

    Item {
        anchors.fill: parent

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop {
                    position: 0
                    color: colors.canvasTop
                    Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
                }
                GradientStop {
                    position: 1
                    color: colors.canvasBottom
                    Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
                }
            }
        }

        Canvas {
            id: canvasGrain
            anchors.fill: parent
            enabled: false
            opacity: colors.light ? 0.06 : 0.08

            function nextNoise(seed) {
                return (seed * 1664525 + 1013904223) >>> 0
            }

            onPaint: {
                const context = getContext("2d")
                context.clearRect(0, 0, width, height)
                context.globalAlpha = 1
                const pointCount = Math.floor(width * height / 80)
                let seed = 18473
                for (let i = 0; i < pointCount; i++) {
                    seed = canvasGrain.nextNoise(seed)
                    const x = seed % Math.max(1, Math.floor(width))
                    seed = canvasGrain.nextNoise(seed)
                    const y = seed % Math.max(1, Math.floor(height))
                    context.fillStyle = (seed & 1) ? "#FFFFFF" : "#3D3429"
                    context.fillRect(x, y, 1, 1)
                }
            }

            Component.onCompleted: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
        }

        Rectangle {
            id: sidebar
            visible: win.sidebarOpen
            width: win.sidebarOpen ? win.sidebarWidth : 0
            height: parent.height
            color: colors.surface
            Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: colors.baseSpacing
                spacing: colors.compactSpacing

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "AGENTS"; color: colors.secondary; font.family: colors.fontFamily; font.pixelSize: Math.round(12 * win.textScale); font.bold: true; font.letterSpacing: 1.5 }
                    Item { Layout.fillWidth: true }
                    Text { text: String(win.visibleRows.length); color: colors.secondary; font.family: colors.fontFamily; font.pixelSize: Math.round(12 * win.textScale) }
                }

                ListView {
                    id: agentList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: win.visibleRows
                    spacing: 4
                    delegate: Rectangle {
                        required property var modelData
                        readonly property var row: modelData
                        width: agentList.width
                        height: Math.round(36 * win.textScale)
                        radius: colors.rowRadius
                        color: win.selectedAgent && win.selectedAgent.key === row.agent.key ? colors.selection :
                               mouse.pressed ? colors.buttonPressed : mouse.containsMouse ? colors.hover : "transparent"
                        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Math.min(row.depth, 8) * 12 * win.textScale + 4
                            spacing: 4
                            Rectangle {
                                width: 24 * win.textScale; height: 32 * win.textScale; color: "transparent"
                                Text {
                                    anchors.centerIn: parent
                                    text: row.hasChildren ? (win.collapsed[row.agent.key] && !sidebarInput.text ? "▸" : "▾") : ""
                                    color: colors.muted; font.family: colors.fontFamily; font.pixelSize: Math.round(15 * win.textScale)
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
                                width: Math.max(60, agentList.width - parent.anchors.leftMargin - 36)
                                height: 32 * win.textScale
                                verticalAlignment: Text.AlignVCenter
                                elide: Text.ElideRight
                                text: row.agent.name
                                color: row.contextOnly ? colors.secondary : colors.foreground
                                font.family: colors.fontFamily
                                font.pixelSize: Math.round(17 * win.textScale)
                            }
                        }
                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            anchors.leftMargin: Math.min(row.depth, 8) * 12 * win.textScale + 32 * win.textScale
                            hoverEnabled: true
                            onClicked: win.selectAgent(row.agent)
                        }
                    }
                }

                TextField {
                    id: sidebarInput
                    Layout.fillWidth: true
                    placeholderText: "Filter agents"
                    placeholderTextColor: colors.placeholder
                    text: win.sidebarQuery
                    onTextChanged: win.sidebarQuery = text
                    color: colors.foreground
                    font.family: colors.fontFamily
                    font.pixelSize: Math.round(15 * win.textScale)
                    selectByMouse: true
                    background: Rectangle {
                        radius: colors.smallRadius
                        color: colors.field
                        border.color: sidebarInput.activeFocus ? colors.focus : colors.fieldBorder
                        Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                    }
                    Keys.onUpPressed: agentList.positionViewAtBeginning()
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: archetypeColumn.implicitHeight + colors.baseSpacing
                    radius: colors.cardRadius
                    color: colors.surface
                    border.color: colors.fieldBorder
                    Column {
                        id: archetypeColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 8
                        spacing: 4
                        Rectangle {
                            id: archetypeHeader
                            width: parent.width; height: 32 * win.textScale
                            radius: 8
                            color: archetypeHeaderMouse.pressed ? colors.buttonPressed
                                 : archetypeHeaderMouse.containsMouse ? colors.hover : "transparent"
                            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                            Text {
                                anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                                text: "Archetypes"; color: colors.secondary; font.family: colors.fontFamily; font.pixelSize: Math.round(13 * win.textScale)
                            }
                            Text {
                                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                text: win.archetypesExpanded ? "▴" : "▾"; color: colors.secondary
                                font.family: colors.fontFamily; font.pixelSize: Math.round(13 * win.textScale)
                            }
                            MouseArea {
                                id: archetypeHeaderMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: win.archetypesExpanded = !win.archetypesExpanded
                            }
                        }
                        Repeater {
                            model: win.archetypesExpanded ? win.archetypes : []
                            delegate: CheckBox {
                                id: archetypeCheckBox
                                required property string modelData
                                text: modelData
                                width: archetypeColumn.width
                                implicitHeight: Math.round(32 * win.textScale)
                                leftPadding: 0
                                rightPadding: 0
                                spacing: 8
                                font.pixelSize: Math.round(13 * win.textScale)
                                font.family: colors.fontFamily
                                checked: !!win.selectedArchetypes[modelData]
                                onClicked: win.toggleArchetype(modelData)

                                indicator: Rectangle {
                                    x: archetypeCheckBox.leftPadding
                                    y: archetypeCheckBox.height / 2 - height / 2
                                    implicitWidth: 16
                                    implicitHeight: 16
                                    radius: 4
                                    color: archetypeCheckBox.checked
                                           ? (archetypeCheckBox.down ? colors.accentPressed : colors.accent)
                                           : colors.surface
                                    border.color: archetypeCheckBox.visualFocus ? colors.focus
                                                  : archetypeCheckBox.checked ? colors.accent : colors.border
                                    border.width: archetypeCheckBox.visualFocus ? 2 : 1
                                    Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                                    Text {
                                        anchors.centerIn: parent
                                        visible: archetypeCheckBox.checked
                                        text: "✓"
                                        color: colors.onAccent
                                        font.family: colors.fontFamily
                                        font.pixelSize: 11
                                    }
                                }

                                contentItem: Text {
                                    anchors.fill: parent
                                    text: archetypeCheckBox.text
                                    font: archetypeCheckBox.font
                                    color: archetypeCheckBox.enabled ? colors.foreground : colors.disabledText
                                    verticalAlignment: Text.AlignVCenter
                                    leftPadding: archetypeCheckBox.indicator.width + archetypeCheckBox.spacing
                                    elide: Text.ElideRight
                                }
                                background: Rectangle {
                                    radius: 8
                                    color: archetypeCheckBox.down ? colors.buttonPressed
                                         : archetypeCheckBox.hovered ? colors.hover : "transparent"
                                    Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                                }
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
            color: drag.containsMouse ? colors.dividerHover : colors.divider
            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
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
                zoomFactor: win.textScale
                onNavigationRequested: request => {
                    if (request.navigationType === WebEngineNavigationRequest.LinkClickedNavigation) {
                        request.reject()
                        win.openExternalLink(request.url)
                    }
                }
                onNewWindowRequested: request => win.openExternalLink(request.requestedUrl)
            }

            Rectangle {
                anchors.fill: parent
                visible: !win.selectedAgent && win.settingsKnown
                color: "transparent"
                Text {
                    anchors.centerIn: parent
                    text: win.rosterError ? win.rosterError :
                          win.connecting ? "Reading agents…" : "Choose an agent to open Chat"
                    color: win.rosterError ? colors.error : colors.secondary
                    font.family: colors.fontFamily
                    font.pixelSize: Math.round(17 * win.textScale)
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: !win.settingsKnown
                color: "transparent"
                Text {
                    anchors.centerIn: parent
                    text: "Loading connection settings…"
                    color: colors.secondary
                    font.family: colors.fontFamily
                    font.pixelSize: Math.round(15 * win.textScale)
                }
            }

            Rectangle {
                x: 12; y: 12; width: 34; height: 34
                visible: !win.settingsOpen
                radius: colors.smallRadius
                color: sidebarToggleMouse.pressed ? colors.buttonPressed
                     : sidebarToggleMouse.containsMouse ? colors.buttonHover : colors.button
                border.color: colors.buttonBorder
                Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                Text { anchors.centerIn: parent; text: win.sidebarOpen ? "◀" : "☰"; color: colors.foreground; font.family: colors.fontFamily; font.pixelSize: Math.round(16 * win.textScale) }
                MouseArea { id: sidebarToggleMouse; anchors.fill: parent; hoverEnabled: true; onClicked: win.sidebarOpen = !win.sidebarOpen }
            }
        }

        Rectangle {
            anchors.fill: parent
            visible: win.pickerOpen
            z: 10
            color: colors.scrim
            MouseArea { anchors.fill: parent; onClicked: if (win.selectedAgent) win.pickerOpen = false }

            Rectangle {
                width: Math.min(parent.width - 48, 600)
                height: Math.min(parent.height - 70, pickerColumn.implicitHeight + 48)
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.min(110, parent.height * 0.16)
                radius: colors.overlayRadius
                color: colors.raisedSurface
                gradient: Gradient {
                    GradientStop {
                        position: 0
                        color: colors.raisedSurfaceTop
                        Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
                    }
                    GradientStop {
                        position: 1
                        color: colors.raisedSurfaceBottom
                        Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
                    }
                }
                border.color: colors.strongBorder
                Behavior on border.color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
                clip: true
                layer.enabled: true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: colors.panelShadow
                    shadowBlur: 0.65
                    blurMax: 20
                    shadowVerticalOffset: 4
                }

                Column {
                    id: pickerColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: colors.panelPadding
                    spacing: 8

                    TextField {
                        id: pickerInput
                        width: parent.width
                        height: Math.round(48 * win.textScale)
                        placeholderText: "Find an agent…"
                        placeholderTextColor: colors.placeholder
                        color: colors.foreground; font.family: colors.fontFamily; font.pixelSize: Math.round(17 * win.textScale)
                        selectByMouse: true
                        background: Rectangle {
                            radius: colors.smallRadius
                            color: colors.field
                            Behavior on color { ColorAnimation { duration: 300; easing.type: Easing.InOutQuad } }
                            border.color: pickerInput.activeFocus ? colors.focus : colors.fieldBorder
                            Behavior on border.color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                        }
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
                            height: Math.round(36 * win.textScale)
                            radius: colors.smallRadius
                            color: index === win.pickerIndex ? colors.pickerSelection
                                 : pickerRowMouse.pressed ? colors.buttonPressed
                                 : pickerRowMouse.containsMouse ? colors.hover : "transparent"
                            Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 16
                                verticalAlignment: Text.AlignVCenter
                                text: modelData.name
                                color: colors.foreground; font.family: colors.fontFamily; font.pixelSize: Math.round(17 * win.textScale)
                                elide: Text.ElideRight
                            }
                            MouseArea { id: pickerRowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: win.selectAgent(modelData) }
                        }
                    }

                    Text {
                        visible: win.pickerMatches.length === 0
                        text: win.rosterError ? win.rosterError : "No matching agents"
                        color: win.rosterError ? colors.error : colors.secondary
                        font.family: colors.fontFamily
                        font.pixelSize: Math.round(15 * win.textScale)
                        leftPadding: 10; topPadding: 9; bottomPadding: 9
                    }
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            visible: win.settingsOpen && win.settingsKnown
            z: 20
            color: colors.scrim
            MouseArea { anchors.fill: parent; onClicked: {} }

            SettingsPane {
                id: settingsPane
                width: Math.min(parent.width - 48, 720)
                height: Math.min(parent.height - 48, 640)
                anchors.centerIn: parent
                textScale: win.textScale
                theme: colors
                setupRequired: !win.configured
                onSaveRequested: win.saveSettings()
                onCloseRequested: win.toggleSettings()
                onDiscoverRequested: win.discoverGateway()
            }
        }
    }
}
