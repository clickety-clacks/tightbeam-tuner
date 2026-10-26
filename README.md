# Tightbeam Tuner

Tuner has desktop and native iOS/iPadOS apps. The mobile project is in [`ios/`](ios/).

Tightbeam Tuner is a Quickshell desktop app for browsing an agent tree and opening the existing Tightbeam Chat in the same window. It uses a normal floating window, so it works under both Omarchy and Scottland.

## What it does

- Lists active agents by display name under their current parent. Parent rows can collapse their descendants.
- Opens the selected agent's existing Chat page in the right pane.
- Opens links from Chat in the system browser.
- Opens connection settings as a modal with `Ctrl+,`; a new installation opens there automatically.
- Reloads the current Chat page with `Ctrl+R`.
- Resizes or hides the sidebar. The button at the upper left of the chat pane toggles it.
- Filters the sidebar by agent name. Matches inside collapsed branches remain visible with their ancestors.
- Filters the sidebar by one or more archetypes. The Spotlight picker searches every active agent and matches all query words in any order.
- Opens each window with an empty selection and a focused Spotlight picker. Every window has its own selection and UI state.
- Remembers the last chosen text size for later windows and launches. Open windows keep their own size. The embedded Chat page uses WebEngine zoom.
- Follows the desktop's light or dark appearance for its sidebar, picker, and connection settings, including changes while the app is open.
- Uses the Nordic palette shared with Tightbeam Chat and Harklight: linen off-white and off-black neutrals with a moss accent, on desktop and iOS.

| Shortcut | Action |
| --- | --- |
| `Ctrl+N` | Open an independent Tuner window with the picker focused |
| `Ctrl+Space` | Open the Spotlight picker |
| `Ctrl+/` | Open the sidebar and focus its name filter |
| `Ctrl+\` | Toggle the sidebar |
| `Ctrl+=` | Increase sidebar, picker, and Chat size |
| `Ctrl+-` | Decrease sidebar, picker, and Chat size |
| `Ctrl+,` | Open or close connection settings |
| `Ctrl+R` | Reload the current Chat page |

## Requirements

- Quickshell 0.3.1 with Qt WebEngine initialization support. Stock Quickshell 0.3.1 crashes when `WebEngineView` is instantiated. This repo includes `patches/quickshell-0.3.1-webengine.patch`, which links Qt WebEngine Quick, initializes it before the GUI application, and supplies the program name Qt WebEngine needs. [Upstream WebView work](https://github.com/quickshell-mirror/quickshell/pull/351) is still open.
- Qt 6 WebEngine QML module, Python 3, and an authorized Tightbeam CLI installation.
- Network access to the existing private Tightbeam Chat service and the selected gateway.

## Configure

On first launch, Tuner opens Connection settings. Open them again with `Ctrl+,`.

- Enter the origin of a provisioned Chat service. If the gateway URL or Tightbeam user is blank when you save, Tuner fills it from the server's published defaults when available. **Find from Chat** previews those values; otherwise enter them manually.
- Enter where the Tightbeam CLI is installed, such as `tightbeam` if it is on `PATH` or `/path/to/tightbeam`. Enter the user whose agents you want to browse. If the CLI runs on another host, use a prefix such as `ssh host /path/to/tightbeam`. Tuner splits this prefix into arguments, appends `list --as-user <user>`, and runs it without a shell.
- Choose **Save and connect**. Tuner reads the roster before opening the agent picker. Connection errors remain visible in settings.

Chat currently opens one selected conversation and does not publish a browsable agent roster. Tuner uses the configured CLI for agent names, archetypes, and parent relationships. Set up CLI access separately. Do not enter passwords or tokens in Tuner.

Settings are saved with mode `0600` at `$XDG_CONFIG_HOME/tightbeam-tuner/config.json` (normally `~/.config/tightbeam-tuner/config.json`). `config.example.json` shows the file format, and `TIGHTBEAM_TUNER_CONFIG` can select another path. Tuner passes the exact session key in Chat's `gateway` and `session` query parameters; Chat handles its own server-side connection.

The last chosen text size is saved in `$XDG_STATE_HOME/tightbeam-tuner/preferences.json` (normally `~/.local/state/tightbeam-tuner/preferences.json`). New windows read it when they open.

Run `quickshell -p /path/to/tightbeam-tuner` with the WebView-enabled Quickshell binary. The roster refreshes every 30 seconds.

To build the compatible binary without replacing your desktop's Quickshell installation, check out the Quickshell `v0.3.1` tag in a separate directory, apply the included patch with `git apply`, and build it with CMake and Ninja. The build requires Qt WebEngine Quick and Quickshell's normal build dependencies. Run the resulting `build/src/quickshell` binary with `-p /path/to/tightbeam-tuner`.

## Development

`scripts/roster.py` is the small CLI adapter. It reads active sessions, names, archetypes and parent keys, then constructs Chat URLs. The Quickshell interface is in `shell.qml` and `TunerWindow.qml`.

## iPhone and iPad

Open `ios/TightbeamTuner.xcodeproj` in Xcode 27.1 or later. The bundle identifier is `co.clicketyclacks.tightbeam-tuner`. The project can also be regenerated from `ios/project.yml` with XcodeGen. It targets iOS 26 or later, for the system Liquid Glass controls, and uses the iOS 27.1 SDK's adaptive navigation on iPhone Duo. The layout responds to available space as the device folds or resizes, with no device-specific dimensions or orientation checks. It also runs on iPad. Appearance follows the system by default; Settings can choose light or dark explicitly.

On first launch, enter:

- The HTTPS Chat server and its HTTP or HTTPS gateway origin. **Find gateway from Chat** reads the server's published default when available.
- The SSH host, port, login, Tightbeam CLI path, and Tightbeam user. Tuner runs `<path> list --as-user <user>` over SSH to obtain the agent tree.
- The server's public `ssh-ed25519` host key. Tuner pins this key and rejects a different one. Obtain and verify it with the server administrator before pasting it.

Tuner creates an Ed25519 client key in the device Keychain. Copy its public key from Settings and authorize it for the SSH login on the server. The private key stays on the device. The app does not ask for an SSH password. The SSH login must be able to run the configured Tightbeam CLI without an interactive prompt.

The mobile sidebar puts the most recently selected active agents (ten by default; Settings sets the number, from none to 50) above the parent/child agent tree. Each agent shows its archetype as a caption under its name. Parents start expanded and can be collapsed; native sidebar search filters both sections by name, and a toolbar menu filters them by archetype. Selecting an agent opens the existing Chat UI in an embedded WebKit view and closes the sidebar in compact layouts. The chat extends behind the toolbar, with message and composer spacing around side controls in landscape. SwiftUI's split view provides sidebar navigation, and Reload Chat is a standard detail toolbar item. When the agent list floats over the chat, as in portrait, choosing an agent closes it, and opening it puts the keyboard away. Once Chat hands its composer to Tuner, the native message field shows Chat's connection dot at its left; tap it for connection details. The send button sits concentric with the field's rounded right end. Swiping down on the conversation hides the keyboard; tapping the conversation or Latest messages leaves it up. Chat keeps a conversation at the bottom as the keyboard or the message field changes the room it has. If iOS discards the chat page while Tuner is in the background, Tuner reloads it on return. An unsent message is kept per agent, through reloads, quitting Tuner, and iOS ending it in the background. Links open in the system browser. Pull to refresh the roster. There is no Spotlight picker on mobile.

After an update, a What's New sheet lists what changed since the last build the device opened, once; Settings keeps every release's notes under Release Notes. Each release adds an entry at the top of `ios/TightbeamTuner/ReleaseNotes.swift`, numbered with the build it ships as. An entry numbered past the installed build stays hidden until that build arrives.
