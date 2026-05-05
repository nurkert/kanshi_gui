# Changelog

## 1.2.0 — 2026-05-05

### Added

- **Display mirroring** on the Sway backend. Open a tile's three-dot menu
  → "Mirror onto…" → pick another enabled output to make this monitor
  show the same content. The relationship is per-profile; switching
  profiles tears down the mirrors of the previous profile and brings up
  the new ones. "Stop mirroring" releases the bond again.

  Sway 1.11 has no native `output mirror` IPC, so the engine is the
  external `wl-mirror` tool — `apt install wl-mirror` is required for
  this feature. On other backends (wlr-randr, noop) the menu entries
  are hidden entirely; on Sway without wl-mirror installed, they are
  also hidden until the binary is in `$PATH`.

  Mirrored tiles render with a cyan border + "⇄ Mirror of <src>" badge
  and are parked in their own lane beside the active cluster — so the
  layout never visually overlaps an independent monitor with one that
  inherits its content. Drag, resize and mode change are disabled on a
  mirror tile (those properties are inherited from the source).

  Mirror state survives kanshi-gui restart via an `exec wl-mirror …`
  hook injected into the relevant Sway profile in the kanshi config.

  Cycles (A→B + B→A) and chains (A→B then B→C) are rejected at the
  controller; the runner auto-respawns wl-mirror up to 3 times in 30s
  when its window is closed accidentally and surfaces a "give up"
  state when the budget is exhausted.

## 1.1.5 — 2026-05-05

### Changed

- Disabled monitors no longer render on top of the active layout. Sway
  parks disabled outputs at (0, 0), which previously stacked them on
  whichever monitor occupied origin — looking like a dirty grey overlap.
  The canvas now parks each disabled tile in a vertical column to the
  right of the active cluster (display-only; the stored coords stay
  intact so re-enabling brings the monitor back to its real position).
- Snap and overlap detection ignore disabled monitors: they were never
  visible at the snap target's coordinates anyway, so they no longer
  produce phantom snap targets when dragging an active tile.

## 1.1.4 — 2026-05-05

### Fixed

- A monitor disconnected while the user was dragging it left the layout
  canvas pinned to a bounding box that no longer existed; the next drag
  projected against stale coordinates. Hotplug now releases the pin and
  closes the drag session for any vanished output.
- Profile re-hydration matched on `id` *or* manufacturer string with
  short-circuiting: with two physically identical monitors (same EDID on
  two ports) both profile entries silently collapsed onto whichever live
  output was first in the list, swapping mode lists between the two
  screens. Re-hydration now runs in two passes — exact `id` match first,
  manufacturer fallback only on the still-unclaimed live outputs.
- The "revert last custom mode" memory was global and persisted across
  profile switches; reverting after a switch could replay an unrelated
  prior mode. Switching profiles now clears the cache and cancels any
  pending auto-revert timer.

## 1.1.3 — 2026-05-05

### Fixed

- Stop the layout canvas from reflowing under the cursor while a drag is in
  progress. Dragging a monitor above (or left of) origin pushed the
  bounding box outward, which re-scaled and re-offset every other tile
  every frame — the visible result was tiles "jumping", overlapping and
  leaving ghost imprints. The canvas now snapshots the bounding box at
  drag start and only releases the pin on drag end, so non-dragged tiles
  stay put and the dragged one follows the cursor pixel-perfectly even
  into negative coordinates.

## 1.1.2 — 2026-05-04

### Fixed

- Live apply no longer fails with `swaymsg: invalid option -- '4'` when a
  monitor is stacked above origin (negative Y position). `swaymsg` runs its
  argv through `getopt` before joining the message, so `"-1440"` was parsed
  as the option flags `-1`/`-4`/`-4`/`-0`. The apply call now prepends `--`
  to stop option scanning before the message starts.

## 1.1.1 — 2026-04-29

### Fixed

- Release `.deb`s are now built inside a Debian Bullseye container so the
  binaries link against glibc 2.31 instead of the runner's glibc
  (2.35 on `ubuntu-22.04-arm`, 2.39 on `ubuntu-latest`). The 1.1.0 packages
  failed to start on Pi OS Bullseye, Debian 11 and Ubuntu 20.04 with
  `version 'GLIBC_2.34' not found`. Both architectures now run on anything
  glibc ≥ 2.31.

## 1.1.0 — 2026-04-29

### Added

- **Live apply on release** — drag, scale or rotate a monitor and the change
  is pushed to the running compositor immediately, no more "Save & restart"
  click for every layout tweak.
- **Safety-net for risky ops** — mode changes and output-disables get a
  15-second countdown banner with Keep / Revert buttons; chained changes
  share a single banner that always reverts to the pre-chain state.
- **Hard block** against disabling the last enabled output.
- **Snap guides à la Figma** — visible cyan lines while dragging show
  exactly which edge or alignment is engaging.
- **Corner snap with axis alignment** — when an edge snaps, the orthogonal
  axis additionally rasters onto top / bottom / center of the neighbour.
- **Smarter alignment magnet** — after the user pulls out of an alignment
  twice in the same drag, that axis stays free for the rest of the grab;
  a fresh grab restores the full snap help.
- **Scale snap reform** — sensible target values (1.0 / 1.25 / 1.333 / 1.5
  / 1.75 / 2.0 / 2.5 / 3.0), commit-on-release only, direction-aware so
  you never feel "glued" to integer scales.
- **Hotplug listener** — the app reacts to monitor connects/disconnects
  without a manual refresh and shows a toast.
- **`kanshictl reload`** is preferred over `pkill kanshi` when available
  — no flicker on save & restart.
- **Identify Displays** button (light-bulb icon) flashes pulsing numbers
  on each tile for three seconds.
- **First-run wizard** — three-step onboarding that detects the backend,
  lists outputs and proposes a sensible profile name.
- Compositor-agnostic backend abstraction (Sway, wlr-randr, Noop) with
  auto-detection at startup.
- Headless probe tool: `dart run tool/probe_outputs.dart`.

### Changed

- `swaymsg output … position` now correctly receives space-separated X Y
  arguments (was comma-joined, which Sway rejected).
- `apply()` picks the mode that matches the current width/height/refresh
  rather than blindly using the largest mode in the list.
- `kanshi config` writer makes the Sway-specific `exec swaymsg "workspace …"`
  injection opt-in based on the active backend (kept on for Sway, off for
  wlr-randr-based compositors).
- The compositor support matrix in the README is now honest: Sway full,
  Hyprland / Wayfire / other wlroots via wlr-randr, GNOME on Wayland not
  yet supported.

### Fixed

- `withOpacity()` deprecation warnings on newer Flutter SDKs.
- `library_private_types_in_public_api` lint in `createState()` overrides.
- Sidebar animation icon out-of-sync with the sidebar state at startup.
- `_buildAndSave` no longer mutates fields inside `setState`.
- Sway literal `"Unknown"` strings no longer leak into the manufacturer
  display label.
- `dpkg-deb` warning about file ownership in `scripts/build_deb.sh`
  (now passes `--root-owner-group`).

### Internals

- 1573-line god widget refactored into a `KanshiController`
  (`ChangeNotifier`), pulled `LayoutMath`, `KanshiConfigParser`,
  `KanshiConfigWriter` and the backend layer out of the page.
- Test suite grew from 0 → 79 tests covering layout, parser, writer,
  Sway / wlr-randr backends, controller, safety-net, drag-session
  alignment escapes, scale snap and the first-run helpers.

## 1.0.2

- Initial release with manual save / restart workflow.
