# Tightbeam Tuner

Tightbeam Tuner is a Quickshell desktop app for browsing an agent tree and opening the existing Tightbeam Chat in the same window. It uses a normal floating window, so it works under both Omarchy and Scottland.

## What it does

- Lists active agents by display name under their current parent. Parent rows can collapse their descendants.
- Opens the selected agent's existing Chat page in the right pane.
- Resizes or hides the sidebar. The button at the upper left of the chat pane toggles it.
- Filters the sidebar by agent name. Matches inside collapsed branches remain visible with their ancestors.
- Filters the sidebar by one or more archetypes. The Spotlight picker always searches every active agent.
- Opens each window with an empty selection and a focused Spotlight picker. Every window has its own selection and UI state.
- Adjusts text size independently in each window. The embedded Chat page uses WebEngine zoom.

| Shortcut | Action |
| --- | --- |
| `Ctrl+N` | Open an independent Tuner window with the picker focused |
| `Ctrl+Space` | Open the Spotlight picker |
| `Ctrl+/` | Open the sidebar and focus its name filter |
| `Ctrl+\` | Toggle the sidebar |
| `Super+=` | Increase sidebar, picker, and Chat size |
| `Super+-` | Decrease sidebar, picker, and Chat size |

## Requirements

- Quickshell 0.3.1 with Qt WebEngine initialization support. Stock Quickshell 0.3.1 crashes when `WebEngineView` is instantiated. This repo includes `patches/quickshell-0.3.1-webengine.patch`, which links Qt WebEngine Quick, initializes it before the GUI application, and supplies the program name Qt WebEngine needs. [Upstream WebView work](https://github.com/quickshell-mirror/quickshell/pull/351) is still open.
- Qt 6 WebEngine QML module, Python 3, and an authorized `tightbeam list` CLI context.
- Network access to the existing private Tightbeam Chat service and the selected gateway.

## Configure

Copy `config.example.json` to `~/.config/tightbeam-tuner/config.json` and edit these values:

- `rosterCommand`: an argument array that runs `tightbeam list --as-user <user>` in an authorized context. It may start with `ssh` when the CLI is on another machine. No shell expansion is performed.
- `chatBase`: the origin of the already provisioned Chat service.
- `gatewayOrigin`: the canonical origin of the gateway registered with that Chat service.

The config file is local and must not contain credentials. Tuner passes the exact session key in Chat's `gateway` and `session` query parameters. Chat handles its own server-side connection.

Run `quickshell -p /path/to/tightbeam-tuner` with the WebView-enabled Quickshell binary. The roster refreshes every 30 seconds. Set `TIGHTBEAM_TUNER_CONFIG` to use another config path.

To build the compatible binary without replacing your desktop's Quickshell installation, check out the Quickshell `v0.3.1` tag in a separate directory, apply the included patch with `git apply`, and build it with CMake and Ninja. The build requires Qt WebEngine Quick and Quickshell's normal build dependencies. Run the resulting `build/src/quickshell` binary with `-p /path/to/tightbeam-tuner`.

## Development

`scripts/roster.py` is the small CLI adapter. It reads active sessions, names, archetypes and parent keys, then constructs Chat URLs. The Quickshell interface is in `shell.qml` and `TunerWindow.qml`.
