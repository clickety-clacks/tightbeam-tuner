import QtQuick

QtObject {
    readonly property bool light: Application.styleHints.colorScheme === Qt.Light

    readonly property color window: light ? "#f5f7fb" : "#11151c"
    readonly property color sidebar: light ? "#e9eef5" : "#19212c"
    readonly property color surface: light ? "#ffffff" : "#1d2733"
    readonly property color inset: light ? "#f8fafc" : "#101923"
    readonly property color field: light ? "#ffffff" : "#192634"
    readonly property color loading: light ? "#f5f7fb" : "#111923"
    readonly property color foreground: light ? "#172537" : "#eef4fc"
    readonly property color heading: light ? "#263c53" : "#aebbd0"
    readonly property color secondary: light ? "#41546a" : "#aebed0"
    readonly property color muted: light ? "#63788e" : "#8297ad"
    readonly property color faint: light ? "#6e8195" : "#7e91a8"
    readonly property color border: light ? "#bac8d6" : "#3b4b5f"
    readonly property color strongBorder: light ? "#9bb2c9" : "#63809d"
    readonly property color fieldBorder: light ? "#a9b9c9" : "#42576d"
    readonly property color focus: light ? "#2476b4" : "#79b7ec"
    readonly property color hover: light ? "#dfeaf4" : "#253141"
    readonly property color selection: light ? "#cce3f5" : "#30465f"
    readonly property color pickerSelection: light ? "#cce3f5" : "#36516c"
    readonly property color divider: light ? "#b4c3d3" : "#2e3c4c"
    readonly property color dividerHover: light ? "#729dc0" : "#6593b9"
    readonly property color button: light ? "#d7e8f6" : "#263648"
    readonly property color buttonBorder: light ? "#95b7d0" : "#4c6884"
    readonly property color error: light ? "#a43c2a" : "#f0ad9d"
}
