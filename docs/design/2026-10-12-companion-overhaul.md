# Companion overhaul

Date: 2026-10-12. Scope: the menu bar companion in `macos/`. Method: the
`papi-benji-design` skill, applied to a native Mac panel. Nothing here copies
another product's colours, marks, or characters.

## What changed

- **Character.** The speech bubble is the body and its eyes are the product's
  typing dots. There is no mouth. Each mood is one row of numbers
  (`MaxPose`), so any face moves to any other: rest, needs you (wider eyes and
  a badge), working (the eyes part and a third dot hops between them), trouble
  (the eyes stack into an exclamation mark), asleep, happy, and a wink on
  click. The bubble is a plain circle with a short round-tipped tail and no
  sharp corners (`MessageMark.round`); it carries no sparkle. The same poses
  draw the panel face and the menu bar template image.
- **App icon.** A satin-silver bubble on a blue tile, lit by a lens flare at
  its upper right. The metal's reflection is a soft dark horizon taken from a
  ball fitted to the bubble's body, so the tail never bends it. It keeps the
  original bubble outline (`MessageMark.body`). Iterations are in
  `2026-10-12-companion-overhaul/`; `max-concepts-34-satin-blue.png` is the
  chosen one and `concept-renderer.swift` the exploration renderer.
- **One panel, pages inside it.** The home page shows the face, the title, a
  switch for the helper, the one setup step that is waiting, and three status
  lines. Connection, Details & help, and Preferences slide in as pages with a
  back control in the same place. The former Service menu is the header
  switch; Restart and Open Messages live on Details & help.
- **One blue button.** The setup step's first action, or the home page's
  primary action when no step is waiting. Everything else is grey.
- **Notices** are a toast above the footer that dismisses itself and is
  announced to VoiceOver.
- **Custom drawing.** Eleven glyphs on a 16-unit grid, the morphing action
  glyphs, the switch, buttons, and cards are drawn in `Icons.swift` and
  `Components.swift`. Spacing, radii, type roles, and motion durations are
  tokens in `Components.swift`.
- **Width** is 340 points.

## Checked on the running panel

Fixture windows from a debug build, in light and dark: fresh, stopped, the
three setup steps, problem, working, ready, and all three pages. Reduce Motion
was checked for ready, setup, problem, and stopped. The celebration and the
toast were captured mid-flight in slow motion. The menu bar artwork was
checked enlarged on a light and a dark bar, and the app icon at 1024 pixels.
On 2026-11-05 the round face, the menu bar set, and the redrawn refresh arrow
were checked in a fixture window and at 14 points. The package's 19 tests
pass.

## Measured

Release build, fixture window, panel open: 66.9 MB resident and 0.0% CPU at
rest between blinks; about 13% CPU while the working dots hop. The face stops
drawing when the panel closes.

## Not verified

- Every spring, blink, hop, and celebration value is a starting value chosen
  by eye from stills. None has been tuned against the moving panel by a
  person.
- The real popover, the real menu bar at 1x, VoiceOver, keyboard traversal,
  Increase Contrast, and Reduce Transparency were not exercised after the
  overhaul.
- The app icon was not checked at 16 and 32 pixels in Finder or the Dock.
- The round menu bar artwork was not seen in the real menu bar: a menu bar
  manager hid it during the check.
- The toast can cover the last navigation row for the few seconds it shows.
