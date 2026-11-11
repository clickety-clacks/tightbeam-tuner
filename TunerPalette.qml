import QtQuick

// Nordic palette shared with Tightbeam Chat and Harklight: linen off-white and
// off-black neutrals with a moss accent. No pure white or pure black.
// Colors with alpha use Qt's #AARRGGBB form.
QtObject {
    readonly property bool light: Application.styleHints.colorScheme === Qt.Light

    // Neutrals
    readonly property color window: light ? "#F0EAE0" : "#1C1917"
    readonly property color sidebar: light ? "#FDF6EE" : "#292524"
    readonly property color surface: light ? "#FDF6EE" : "#292524"
    readonly property color inset: light ? "#FDF6EE" : "#292524"
    readonly property color field: light ? "#FDF6EE" : "#292524"
    readonly property color loading: window

    // Text
    readonly property color foreground: light ? "#3D3429" : "#E8E4E0"
    readonly property color heading: light ? "#5B5046" : "#ADA39A"
    readonly property color secondary: heading
    readonly property color muted: heading
    readonly property color faint: heading

    // Lines
    readonly property color border: light ? "#E2DAD0" : "#33302E"
    readonly property color strongBorder: border
    readonly property color fieldBorder: border
    readonly property color divider: border
    readonly property color dividerHover: focus

    // Accent and states
    readonly property color focus: light ? "#A3553E" : "#E07A5F"
    readonly property color hover: light ? "#1FA3553E" : "#1FE07A5F"
    readonly property color selection: light ? "#B8CEAF" : "#2D3B2A"
    readonly property color pickerSelection: selection
    readonly property color error: light ? "#8E2F22" : "#F08C78"
    readonly property color accent: focus
    readonly property color onAccent: light ? "#F7F3EB" : "#1C1917"
    readonly property color placeholder: light ? "#584E45" : "#D9D2CA"

    // Floating glass controls, matching Chat's composer
    readonly property color button: light ? "#BDFFFFFF" : "#BD2C2825"
    readonly property color buttonBorder: light ? "#99FFFFFF" : "#1FFFFFFF"

    // Dims the window behind the picker and settings
    readonly property color scrim: light ? "#8C31302D" : "#B80B0A0A"
}
