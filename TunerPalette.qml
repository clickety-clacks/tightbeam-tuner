import QtQuick

// Shared semantic colors for the Tuner desktop interface.
// Alpha colors use Qt's #AARRGGBB form.
QtObject {
    readonly property bool light: Application.styleHints.colorScheme === Qt.Light
    readonly property string fontFamily: "DM Sans"

    // Canvas and surfaces
    readonly property color canvasTop: light ? "#E8E0D4" : "#0F0E0D"
    readonly property color canvasBottom: light ? "#D4C8BC" : "#1A1816"
    readonly property color window: canvasTop
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
    readonly property color focus: light ? "#C4785C" : "#E07A5F"
    readonly property color dividerHover: focus

    // Actions and states
    readonly property color accent: light ? "#8FA68A" : "#7BA376"
    readonly property color accentHover: light ? "#A4B99F" : "#8FB388"
    readonly property color accentPressed: light ? "#7C9477" : "#658B60"
    readonly property color onAccent: light ? "#3D3429" : "#1C1917"
    readonly property color success: accent
    readonly property color caution: light ? "#D4B896" : "#A69070"
    readonly property color error: light ? "#8B4D3B" : "#E8A89C"
    readonly property color errorSurface: light ? "#E8A89C" : "#C47A6E"
    readonly property color hover: light ? "#18C4785C" : "#24E07A5F"
    readonly property color selection: light ? "#C5D5C0" : "#2D3B2A"
    readonly property color pickerSelection: selection
    readonly property color button: surface
    readonly property color buttonHover: light ? "#E8C4B4" : "#2B2420"
    readonly property color buttonPressed: light ? "#C5D5C0" : "#2D3B2A"
    readonly property color buttonBorder: border
    readonly property color disabledButton: light ? "#E8E0D4" : "#292524"

    // Elevation is reserved for floating desktop overlays.
    readonly property color panelShadow: light ? "#143C2D1E" : "#4D000000"

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
