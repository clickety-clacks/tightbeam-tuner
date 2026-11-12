import QtQuick

// Shared semantic colors for the Tuner desktop interface.
// Alpha colors use Qt's #AARRGGBB form.
QtObject {
    readonly property bool light: Application.styleHints.colorScheme === Qt.Light
    readonly property FontLoader dmSansFont: FontLoader {
        source: Qt.resolvedUrl("ios/TightbeamTuner/Fonts/DM-Sans-Variable.ttf")
    }
    readonly property string fontFamily: dmSansFont.status === FontLoader.Ready
                                       ? dmSansFont.name : "sans-serif"

    // Canvas and surfaces
    readonly property color canvasTop: light ? "#F0EAE0" : "#1C1917"
    readonly property color canvasBottom: light ? "#E8E0D4" : "#141210"
    // The native window under Chat stays on Chat's page color; Tuner-owned
    // empty/loading surfaces use the Canvas and Surface roles below.
    readonly property color window: light ? "#F0EAE0" : "#1C1917"
    readonly property color surface: light ? "#F7F3EB" : "#1C1917"
    readonly property color raisedSurface: raisedSurfaceTop
    readonly property color raisedSurfaceTop: light ? "#F0EAE0" : "#1C1917"
    readonly property color raisedSurfaceBottom: light ? "#E8E0D4" : "#141210"
    readonly property color inset: surface
    readonly property color field: surface
    readonly property color loading: surface

    // Text
    readonly property color foreground: light ? "#3D3429" : "#E8E4E0"
    readonly property color heading: light ? "#5C4A3D" : "#D4C4B0"
    readonly property color secondary: heading
    readonly property color muted: light ? "#A69B8D" : "#8B8078"
    readonly property color faint: secondary
    readonly property color placeholder: secondary
    readonly property color disabledText: secondary

    // Lines and focus
    readonly property color border: light ? "#1A5D4A3D" : "#14FFFFFF"
    readonly property color strongBorder: border
    readonly property color fieldBorder: border
    readonly property color divider: border
    readonly property color focus: light ? "#8B3E2B" : "#E07A5F"
    readonly property color dividerHover: focus

    // Actions and states
    readonly property color accent: light ? "#8FA68A" : "#7BA376"
    readonly property color onAccent: light ? "#3D3429" : "#1C1917"
    readonly property color success: light ? "#405A3A" : "#8DB487"
    readonly property color caution: light ? "#614A18" : "#D4B67E"
    readonly property color error: light ? "#8E2F22" : "#F08C78"
    readonly property color errorText: error
    readonly property color infoCount: light ? "#5C4A3D" : "#D4C4B0"
    readonly property color hover: light ? "#F0EAE0" : "#292524"
    readonly property color pressed: light ? "#E8E0D4" : "#33302E"
    readonly property color buttonHoverOverlay: light ? "#14FFFFFF" : "#14000000"
    readonly property color buttonPressedOverlay: light ? "#29FFFFFF" : "#29000000"
    readonly property color selection: light ? "#C5D5C0" : "#2D3B2A"
    readonly property color pickerSelection: selection
    readonly property color button: surface
    readonly property color buttonHover: hover
    readonly property color buttonPressed: pressed
    readonly property color buttonBorder: border
    readonly property real disabledControlOpacity: 0.45

    // Elevation is reserved for floating desktop overlays.
    readonly property color panelShadow: light ? "#143C2D1E" : "#4D000000"
    readonly property color panelShadowHover: light ? "#1F3C2D1E" : "#66000000"
    readonly property color panelShadowContact: light ? "#0D3C2D1E" : "#33000000"
    readonly property color panelShadowContactHover: light ? "#143C2D1E" : "#4D000000"

    // Shape and spacing tokens in Qt logical units.
    readonly property int smallRadius: 12
    readonly property int rowRadius: 16
    readonly property int cardRadius: 16
    readonly property int overlayRadius: 24
    readonly property int compactSpacing: 12
    readonly property int baseSpacing: 16
    readonly property int comfortableSpacing: 20
    readonly property int panelPadding: 24

    // Dims the app behind picker and settings panels.
    readonly property color scrim: light ? "#993D3429" : "#B80B0A0A"
}
