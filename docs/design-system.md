# Tightbeam Tuner design system

**Status:** Phase 1 design target. The application code still uses its existing colors and control styling; this document defines the proposed Clawline-based visual system for a separately reviewed implementation. This change does not restyle the app.

## Scope and design intent

This system covers Tuner-owned desktop and iOS surfaces: the agent browser, its filters and navigation, connection settings, update notes, and the native message composer. The source is Clawline’s design-system document and its companion demo, read at commit e1fc034a4d3daf0e9c18f7adde8dbb39da05be8f.

Tuner’s purpose is to browse a live agent tree and open one agent’s existing Chat conversation. Its visual priority is therefore a calm, legible roster with clear selection and hierarchy. Clawline’s warm organic-modern colors, soft surfaces, spacing rhythm, and restrained depth carry over. Chat-specific message layout does not: Tuner’s conversation is hosted from Chat, and Tuner does not own its message bubbles, avatars, link previews, or transcript typography.

Use the following component entries as the target appearance while preserving the behaviors described. The token names are semantic design roles; the source files do not yet implement these target values.

## Foundations

### Color

Use semantic roles that switch as one palette. Do not mix light and dark values within a surface.

| Clawline palette token | Light | Dark |
| --- | --- | --- |
| Cream | #F7F3EB | #1C1917 |
| Terracotta | #C4785C | #E07A5F |
| Terracotta light | #E8C4B4 | #8B4D3B |
| Sage | #8FA68A | #7BA376 |
| Sage light | #C5D5C0 | #2D3B2A |
| Warm brown | #5C4A3D | #D4C4B0 |
| Soft coral | #E8A89C | #C47A6E |
| Muted gold | #D4B896 | #A69070 |
| Stone | #A69B8D | #8B8078 |
| Ink | #3D3429 | #E8E4E0 |

| Tuner semantic role | Light | Dark | Use |
| --- | --- | --- | --- |
| Canvas | #E8E0D4 to #D4C8BC | #0F0E0D to #1A1816 | Window background behind app surfaces |
| Surface | #F7F3EB | #1C1917 | Sidebar, forms, picker and plain cards |
| Raised surface | #F0EAE0 to #E8E0D4 | #1C1917 to #141210 | Floating desktop panels |
| Primary text | #3D3429 | #E8E4E0 | Names, values, and essential messages |
| Secondary text | #5C4A3D | #D4C4B0 | Labels and supporting descriptions |
| Muted text | #A69B8D | #8B8078 | Decorative or supplementary metadata only |
| Selection | #C5D5C0 | #2D3B2A | Selected rows and selected filter options |
| Primary action | #8FA68A | #7BA376 | Filled action controls; pair with Ink in light mode and Cream in dark mode |
| Warm accent | #C4785C | #E07A5F | Focus outline and small action icons, including Send |
| Success | #8FA68A | #7BA376 | Connection success, paired with a label or accessible name |
| Caution | #D4B896 | #A69070 | Reconnecting and stale-data status, paired with a label or symbol |
| Error | #E8A89C | #C47A6E | Error marker or supporting surface; error text uses a legible text role |
| Subtle border | rgba(93, 74, 61, 0.10) | rgba(255, 255, 255, 0.08) | Field boundaries and quiet dividers |

The Clawline self and other message colors remain reserved for Chat’s transcript: sage gradients (#B8CEAF to #C8D9C0 in light mode; #2D3B2A to #243322 in dark mode) and neutral message surfaces (#FFFDF9 to #FDF6EE; #292524 in dark mode). They are not roster-row colors. Never use muted text for a name, error, selected state, or other information required to operate Tuner. Color must not be the only indication of connection state, selection, or error.

Keep primary text on primary surfaces at or above 4.5:1 contrast. The muted role is supplementary only; counts, errors, connection state, and selection remain identifiable through text or symbols as well as color.

### Typography

Clawline’s reference family is DM Sans, variable from weight 300 to 700, with a system sans-serif fallback. Tuner has no bundled font file today. Keep native UI type accessible: use SwiftUI text styles and Dynamic Type on iOS, and the Qt/system UI sans on desktop unless a later implementation deliberately packages the reference font.

| Role | Reference treatment | Tuner use |
| --- | --- | --- |
| Screen title | 28 px, bold; subsection 20 px, semibold | Native navigation title on iOS; settings/picker headings on desktop |
| Body | 17 px, regular, 1.5 line height; 45–75 characters per line in reading content | Agent names, form values, instructions, and long error details |
| Compact body | 15 px, regular or medium, 1.5 line height | Inputs, button labels, compact settings text |
| Supporting label | 13 px footnote; 12 px semibold caption | Archetype captions, section counts, status and version metadata |
| Chat reference only | Short 22 px/600/1.3; medium 17 px/500/1.5; long 15 px/400/1.5 with 65ch measure; sender 12 px/600 | These content-aware roles belong to Chat, not the roster or Tuner chrome |

On iOS, prefer semantic system text styles over fixed point sizes so text grows with the user’s settings. On desktop, the current text-size preference scales from 0.7 to 2.0 in 0.1 steps and persists for later windows; keep the hierarchy intact at every scale. Long form instructions should wrap and remain selectable where the current control allows it.

### Spacing

Use a 4-unit base, interpreted in iOS points and Qt logical units:

| Token | Value | Typical use |
| --- | --- | --- |
| Tiny | 4 | Icon and symbol gaps |
| Small | 8 | Label-to-control and tight grouping |
| Compact | 12 | Input inset and compact form separation |
| Base | 16 | Standard component and row-group spacing |
| Comfortable | 20 | Horizontal breathing room |
| Generous | 24 | Panel and page padding |
| Large | 40 | Separation between major regions |

Use 12-unit spacing for compact iPhone transcript rhythm and 16 for iPad transcript rhythm only inside Chat-owned content. Prefer native list and form spacing where Tuner uses system controls. Do not scale hit areas down with type.

### Shape and radii

Use continuous, soft corners for Tuner-owned cards and panels: 12 units for compact fields, 16 for cards and selected row backgrounds, and 24 for larger overlays. This keeps dense roster and settings controls compact while carrying Clawline’s rounded forms into larger surfaces. Use capsules for count pills, compact chips, and the composer field; circular controls remain circular. Preserve system-provided shapes for iOS navigation, forms, menus, sheets, and glass controls.

Clawline’s 24–28 unit rounded message corners with a 4-unit directional corner, and its 28–32 unit organic bubble variations, apply to Chat message bubbles only. Do not put directional bubble corners on agent rows or Tuner panels.

### Elevation and material

Keep ordinary rows, list sections, and sidebar surfaces flat. Apply the warm, downward top-lit shadows only to floating desktop panels:

| Role | Light | Dark |
| --- | --- | --- |
| Floating panel | 0 4px 20px rgba(60,45,30,0.08), 0 1px 3px rgba(60,45,30,0.05) | 0 4px 20px rgba(0,0,0,0.30), 0 1px 3px rgba(0,0,0,0.20) |
| Hovered panel | 0 8px 30px rgba(60,45,30,0.12), 0 2px 6px rgba(60,45,30,0.08) | 0 8px 30px rgba(0,0,0,0.40), 0 2px 6px rgba(0,0,0,0.30) |

The deeper three-layer reference shadow (0 2px offset with 4px blur, 0 8px with 24px blur, and 0 16px with 40px blur; warm-brown at 4%, 8%, and 6%) is reserved for a large floating surface if the simpler token is insufficient. Do not use the demo’s device-frame shadow in the app.

The native iOS composer uses the system glass effect directly over Chat content, with no opaque backing panel or separator. Let the OS own its blur, tint, edge, and elevation. Desktop has no equivalent system glass material; use a quiet surface and border instead of simulating blur across the roster.

### Motion

Use a 200 ms ease transition for custom control feedback and a 300 ms ease transition for custom color-theme changes. A desktop hover may lift a floating panel by 2 units while deepening its shadow. Do not add hover movement to list rows or controls that are not interactive. iOS touch controls use native pressed and navigation feedback.

Respect reduced-motion preferences: remove lifts and optional ambient motion while keeping state changes immediate and visible. Tuner’s roster and settings do not need Clawline’s animated dust, noise overlay, or custom caustic shader; they are reading and navigation surfaces. Avoid motion that distracts from scanning names or status.

## Component inventory

The states and token roles below describe the target appearance. Platform controls retain their native interaction semantics and accessibility behavior.

### Desktop: Qt Quick

**Window and app shell.** A resizable floating app window contains the sidebar and Chat detail. The reference size is 1180 by 760 logical units, with a 640 by 420 minimum. Use Canvas for the window and Surface for the sidebar; follow the desktop’s system light/dark appearance. Preserve loading-settings, first-run settings, no-selection, selected-agent, overlay-open, and closing states. Closing the last window quits the app; Ctrl+N creates an independent window.

**Agent sidebar and section heading.** The sidebar has a tracked “AGENTS” heading and visible-row count above a scrollable tree, then Filter agents and the Archetypes disclosure. Use Surface, Secondary text for the heading, and Muted text for the count. The target spacing follows the 4-unit grid; the current sidebar opens at 270 units and resizes from 190 to 480.

**Agent tree row.** Anatomy is disclosure marker, indented agent name, and selected-row background. Keep parents and descendants alphabetic, allow branch collapse, and show matching descendants with nonmatching ancestors as context. Use Body for names, Secondary text for context-only ancestors, and Selection for the active row. States are ordinary, hovered, keyboard-focused, selected, collapsed/expanded, and filtered-context. Light and dark use the same semantic roles.

**Filter agents field.** A single-line field at the bottom of the desktop sidebar, with placeholder, editable query, and visible focus boundary. Use Surface for the inset field, Primary text for the query, Muted text for placeholder, Subtle border at rest, and Warm accent for focus. The query and archetype filters combine; filtering keeps matching branches visible. Ctrl+/ opens the sidebar and focuses this field.

**Archetypes disclosure and checklist.** A bordered inset group has an “Archetypes” disclosure row and a checklist shown while expanded. Use Surface, Subtle border, Secondary text for its label, and Selection for checked items. States are collapsed/expanded, checked/unchecked, hovered, and focused. Multiple archetypes can be selected; the selected set filters the tree.

**Sidebar resize divider.** A narrow full-height drag target separates sidebar and detail. Keep it visually quiet at rest, use Warm accent only while hovered or keyboard-focused, and show the platform split cursor. It changes sidebar width without changing selection or filters; its range remains 190–480 logical units.

**Sidebar toggle.** A compact floating control at the upper-left of the detail pane toggles the sidebar and changes its menu/close symbol. Use a quiet translucent Surface and Subtle border with an 8-unit corner; show focus clearly. It is hidden while settings are open and follows light/dark surfaces.

**Chat detail and empty/loading states.** With a selected agent, the existing Chat page fills the detail pane. Without one, Tuner shows “Choose an agent to open Chat”; while reading the roster it shows “Reading agents…”, and connection-settings startup has a separate loading message. Errors remain readable text on a calm surface. Tuner owns the host background, reload trigger, zoom preference, and external-link handoff; the embedded page owns all transcript styling. Use Canvas/Primary text for Tuner placeholders in both themes.

**Spotlight picker.** A centered, bounded dialog has a scrim, search field, up to 12 matching rows, and a no-match or roster-error message. Use Raised surface, 24-unit panel corners, Floating panel elevation, 12-unit interior padding, and Selection for the keyboard-highlighted result. The field has a clear focus boundary; row states are ordinary, hovered, keyboard-highlighted, and pressed. Query changes reset the active result. Up/Down changes the highlight, Enter selects, Escape closes when a chat is already selected, and an outside click dismisses when possible. Ctrl+Space opens the picker and focuses its field.

**Connection settings panel.** First-run setup and later connection settings use a centered scrollable panel with a title, explanatory copy, Chat server URL, gateway URL, Tightbeam CLI location, Tightbeam user, feedback message, and action row. Use Raised surface, 24-unit panel corners, 12-unit field corners, Body for input values, Supporting label for field labels, and Error for visible connection feedback. Field states are empty, editing, focused, and populated; validation and discovery failures appear in the shared feedback message rather than an inline field error. “Find from Chat” has idle/checking/disabled/error states; “Save and connect” has enabled/connecting/disabled states; “Back to chat” appears only after setup. Preserve the existing desktop field set; device key and SSH host-key settings belong to iOS.

**Tuner button.** The shared desktop button has a text label, rounded capsule background, and either a filled primary or quiet secondary treatment. Use Primary action with its theme-matched foreground for the prominent action; use a translucent Surface and Subtle border for secondary actions. States are ordinary, hover, keyboard focus, pressed, and disabled. Disabled actions remain visibly unavailable; focus remains distinct from hover in both themes.

**Desktop navigation shortcuts.** Ctrl+N opens a new window; Ctrl+Space opens Spotlight; Ctrl+/ opens and focuses sidebar search; Ctrl+\ toggles the sidebar; Ctrl+= and Ctrl+- adjust text size; Ctrl+, opens or closes connection settings; Ctrl+R reloads the selected Chat page. These keyboard routes are part of the navigation system, not decoration. Keep the labels and focus states legible in either theme.

### iOS: SwiftUI and WebKit

**Split navigation and toolbars.** NavigationSplitView presents the Agents sidebar and selected Chat detail when space permits, and a compact one-column flow on narrow layouts. Use the system title, toolbar, back/sidebar controls, selection, safe areas, and adaptive split behavior. Settings is a sidebar toolbar action; Reload Chat is a detail toolbar action. Preserve the floating sidebar behavior on a wide iPad in portrait, the selected detail under that sidebar, and the app’s saved sidebar visibility across background/foreground changes. The system sidebar control has no custom Replies badge.

**Sidebar search.** The native searchable field is labeled “Filter agents” and filters Replies, Recent, and Agents by name. All query words must match; archetype selections are combined with the name query. Preserve the native search capsule, focus, keyboard, clear action, and safe-area behavior. Do not replace it with a custom field to force the desktop dimensions.

**Section headers and count pills.** Replies, Recent, and Agents are native collapsible sections. Replies and Recent appear only when populated; Agents remains the tree section. Each visible header contains its title and a capsule count; use Secondary text for the title and Sage for the count and soft count-pill fill. Counts follow active filters and do not change when a section or agent branch is collapsed. Agents counts matching agents, excluding context-only ancestors; Replies and Recent count their filtered entries. Native expanded/collapsed and VoiceOver behavior remains intact.

**Replies rows.** A row contains the agent name and optional archetype caption, plus a waiting spinner or reply symbol. Waiting rows sort before received replies; among each group, newer activity appears first. Opening a reply selects its agent and marks it read on this device. Use Body for the name, Supporting label for the archetype, and a labeled spinner or symbol in addition to any color. States are waiting, unread reply, selected, filtered-context, and section-collapsed.

**Recent rows.** A row contains the agent name, archetype caption, and clock symbol. Selecting it opens Chat and updates recency. A trailing swipe reveals the destructive remove action; it is not a full-swipe action. Use the native destructive treatment and preserve the system swipe gesture. States are ordinary, selected, swiped, and removed. Settings controls the visible count from Off to 50, with 10 as the default.

**Agent tree rows.** The hierarchical list uses DisclosureGroup and NavigationLink. Parents start expanded; branches can collapse. A name match shows its ancestors as subdued context, with branches expanded while filtering so matches remain reachable. Use Body for names, Secondary text for context-only names, Caption for archetype, and the native selected-row background. States are ordinary, selected, expanded/collapsed, filtered-context, and focused.

**Archetype filter menu.** The “Filter archetypes” toolbar menu contains a Toggle for each available archetype. Preserve system menu presentation, checkmarks, keyboard/VoiceOver behavior, and visibility while search is active. Use system selection with the theme’s Sage accent. States are menu closed/open and each option checked/unchecked.

**Roster status and empty states.** Loading uses the native progress indicator and “Loading agents…” label. A stale roster uses a clock symbol and explanatory text. Failure uses the standard unavailable presentation with a readable error. An empty tree has no invented agent rows. Pull-to-refresh remains a native gesture. Use Primary or Secondary text for essential status; Caution and Error colors supplement the words and symbols.

**Chat detail and reload navigation.** The selected existing Chat page is hosted in WebKit below Tuner’s navigation controls. “Reload Chat” remains a native toolbar action. Tuner opens clicked links in the system browser and does not impose its typography or bubble tokens on Chat. With no selected agent, use the native “Choose an agent” unavailable presentation. Keep page, keyboard, safe-area, selection, and toolbar coordination intact across compact and regular layouts.

**Native composer and connection status.** When Chat hands composer ownership to Tuner, the native glass row overlays the transcript directly. Its anatomy is a connection-status button, multiline Message field, and circular Send button. The field can grow from one to six lines, keeps its draft per agent, and aligns with Filter agents where the navigation layout supports that alignment. Use the system interactive glass treatment, capsule field, Warm accent for the available Send icon, and Secondary text for unavailable Send. Do not add an opaque toolbar panel behind it.

The connection dot opens a native popover with status, gateway, session, and agent details. Connected, reconnecting/connecting, and disconnected states use Sage, Caution, and Error respectively and retain a spoken label. When disconnected, the popover offers Connect. Send is disabled for an empty draft, unavailable Chat, or an in-flight handoff; a live-feed reconnect alone does not disable it. A failed, uncertain, or interrupted outgoing message restores the draft and changes Send to Retry. “Not sent” appears as a labeled notice for a failed message. Keep the system glass, keyboard, and selection behavior in both themes.

**Settings sheet.** A native NavigationStack and Form organize Chat server and gateway, SSH host/port/login, Tightbeam CLI path and Tightbeam user, public server key, device public key, Appearance, Agent list, and About. Keep system text fields, URL and numeric keyboards, selection/copy, Picker, Stepper, section footers, and navigation bars. The appearance Picker offers System, Light, and Dark; System follows iOS, while the other options force the scheme. Save and connect has idle/connecting/disabled states; discovery has idle/checking/disabled/error states. Existing configuration allows Cancel; first-run setup cannot be dismissed until configuration is complete. A missing device public key and discovery/connection failures remain explicit and legible. Use native Form row surfaces and theme-aware text rather than custom replacement fields.

**What’s New and Release Notes.** What’s New is a scrollable update sheet shown once for unseen releases, with icon, title, detail, and a bottom Continue action. Release Notes in Settings is a native list grouped by version and date with the same rows. Use Body for titles/details, Sage for symbols and primary action, and Secondary text for descriptions. Preserve sheet dismissal, native scrolling, and Dynamic Type.

## Navigation map

| Platform | Entry and movement | State changes |
| --- | --- | --- |
| Desktop | Sidebar row selects an agent; Ctrl+Space opens Spotlight; Ctrl+/ opens and focuses filtering; Ctrl+\ toggles sidebar | Selection opens the existing Chat page; filters preserve matching branches; Ctrl+R reloads; links leave for the browser |
| iOS | NavigationSplitView selects an agent; native search and Filter archetypes narrow the three list sections; swipe from the left edge reopens the list | Compact selection moves to detail; a floating iPad sidebar closes after selection; Replies selection marks the reply read; Recent swipe removes only that entry |
| Both | Settings is reached from the app’s settings affordance; Chat remains the detail destination | Desktop settings are an overlay; iOS settings and update notes are native sheets; connection details are a popover on iOS |

There is no Spotlight picker on iOS. The Chat page may navigate within its own web history; Tuner’s edge gesture still opens the iOS agent list. Swiping down on the conversation hides the keyboard, while tapping the conversation or Latest messages leaves it open.

## Platform constraints and deliberate departures

| Constraint or departure | Tuner treatment and reason |
| --- | --- |
| Tuner is a roster browser, not a transcript | Keep the parent/child tree, section counts, names, and archetype captions. Do not add Clawline avatar waypoints, message flow packing, sender-side bubble corners, or conversation-only link cards to the roster. |
| Chat owns its embedded page | Style only Tuner’s WebKit host and native composer. Chat controls message bubbles, transcript layout, and in-page typography. |
| Native iOS controls | Use SwiftUI NavigationSplitView, List, searchable, Form, system menus, sheets, popovers, and iOS 26+ Liquid Glass. Native controls adapt shape, keyboard, safe area, accessibility, and platform appearance; do not replace them with web-sized replicas. |
| Dynamic Type versus fixed web sizes | Treat Clawline’s pixel values as reference sizes. Map UI roles to system text styles on iOS and keep desktop’s persisted text-size control. |
| Desktop density and input model | Qt Quick uses logical coordinates, hover and pointer interaction, resizable panes, and keyboard shortcuts. Keep the 190–480 unit sidebar range and allow window resizing rather than using phone-sized fixed layouts. |
| System appearance | Desktop follows the current desktop color scheme. iOS defaults to System and exposes explicit Light and Dark overrides in Settings. Every semantic surface and status token must have both variants. |
| Focus and status contrast | Keep primary and secondary text readable, use muted text only for nonessential metadata, and pair status colors with names or symbols. Warm accent outlines focus; it does not replace focus indication. |
| Texture and ambient effects | Clawline’s subtle page grain and demo particles are not applied to the dense agent tree or settings. They would compete with names, hierarchy, filters, and status. Native glass remains limited to the iOS composer. |

Desktop is implemented with Quickshell/Qt Quick and Qt WebEngine; iOS uses SwiftUI with a WebKit-hosted Chat page. The iOS app targets iOS 26 or later for its native glass controls and adapts to available size classes and split-view geometry, including iPhone Duo layouts. Preserve safe areas, keyboard visibility, Dynamic Type, VoiceOver labels, and native navigation when applying this system.

## Source inventory

The component inventory was checked against shell.qml, TunerWindow.qml, TunerButton.qml, SettingsPane.qml, TunerPalette.qml, and the iOS views, color assets, and project notes in Tuner’s repository. The Clawline source was limited to docs/design-system/design-system.html and docs/design-system/demo.html at the pinned commit above. This document defines the design target; a separate reviewed change is required to apply it.
