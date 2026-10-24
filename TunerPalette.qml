import QtQuick

// Nordic palette shared with Tightbeam Chat and Harklight: linen off-white and
// off-black neutrals with a moss accent. No pure white or pure black.
// Colors with alpha use Qt's #AARRGGBB form.
QtObject {
    readonly property bool light: Application.styleHints.colorScheme === Qt.Light

    // Neutrals
    readonly property color window: light ? "#F1EEE9" : "#161514"
    readonly property color sidebar: light ? "#E6E1D8" : "#201F1D"
    readonly property color surface: light ? "#F1EEE9" : "#201F1D"
    readonly property color inset: light ? "#F1EFEB" : "#24221F"
    readonly property color field: light ? "#F1EFEB" : "#24221F"
    readonly property color loading: window

    // Text
    readonly property color foreground: light ? "#31302D" : "#DDD9D1"
    readonly property color heading: light ? "#5C5854" : "#9E9992"
    readonly property color secondary: heading
    readonly property color muted: heading
    readonly property color faint: heading

    // Lines
    readonly property color border: light ? "#DEDAD3" : "#2C2A27"
    readonly property color strongBorder: light ? "#2E3C2D1E" : "#2EF0E6D7"
    readonly property color fieldBorder: light ? "#2E3C2D1E" : "#2EF0E6D7"
    readonly property color divider: border
    readonly property color dividerHover: focus

    // Accent and states
    readonly property color focus: light ? "#526657" : "#A5BAA9"
    readonly property color hover: light ? "#123C2D1E" : "#1AF0E6D7"
    readonly property color selection: light ? "#DCE3DA" : "#26302A"
    readonly property color pickerSelection: selection
    readonly property color error: light ? "#A63A2A" : "#EE8B75"
    readonly property color accent: focus
    readonly property color onAccent: light ? "#F3F0EA" : "#19211B"
    readonly property color placeholder: secondary

    // Floating glass controls, matching Chat's composer
    readonly property color button: light ? "#BDFAF6EE" : "#BD2E2A25"
    readonly property color buttonBorder: light ? "#1A3C2D1E" : "#1AF0E6D7"

    // Dims the window behind the picker and settings
    readonly property color scrim: light ? "#8C31302D" : "#B80B0A0A"
}
