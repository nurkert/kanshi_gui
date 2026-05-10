# Changelog

## 1.5.5 — 2026-05-10

### Fixed

- **Scale changes propagate through edge-snap chains and to the
  compositor.** Two bugs combined to leave the layout in a state where
  the GUI showed monitors flush but sway had a gap (mouse couldn't
  cross) and a downstream tile visually overlapped its neighbour:
  - `scaleMonitor` only nudged the *direct* edge-snapped neighbours of
    the scaled tile. In a chain A → B → C, scaling A pushed B but left
    C anchored to its old position, so C ended up overlapping B in
    the canvas. Replaced with a BFS over the pre-change edge graph so
    every transitively-snapped tile follows.
  - `onScaleCommit` only pushed the scaled tile's new state to sway.
    Neighbour positions that `scaleMonitor` had moved stayed at their
    old compositor values — the GUI looked fine but sway opened a gap
    between the scaled monitor and its neighbour. The commit now
    live-applies every tile whose `x`, `y`, or `scale` actually
    changed in the same step.

## 1.5.4 — 2026-05-10

### Fixed

- **Rotated outputs render vertically again.** The Sway and wlr-randr
  backends populated `MonitorTileData.width/height` straight from the
  compositor's `current_mode`, which is reported in the panel's native
  (unrotated) orientation. The rest of the app — config parser, writer,
  in-GUI rotation handler — already stores width/height post-rotation,
  so a 90°/270° monitor came back as a landscape tile with a "portrait"
  label until the user rotated it through the GUI. Both backends now
  swap on portrait transforms so the layout matches what Sway's `rect`
  reports.

## 1.5.3 — 2026-05-08

### Fixed

- **Backend detection no longer misfires on non-Sway compositors.**
  `MonitorService.detect` used to pick `SwayBackend` whenever `swaymsg`
  was anywhere in `PATH`, which broke users on niri / river / Hyprland
  who keep the sway package installed for tooling reasons. Detection
  now requires a *running* sway IPC socket (`SWAYSOCK` env var pointing
  at an existing path); without it, the wlr-randr fallback takes over,
  giving non-Sway users basic monitor management (position / mode /
  scale / rotate / enable-disable) instead of a dead UI. The Sway-only
  features (mirror via wl-mirror, swaynag identify-banners, automatic
  workspace placement, sway-accent theming) stay gated behind their
  capability flags. Reported in #26.
- **Verify-and-fix workspace pass short-circuits on non-Sway backends.**
  The post-init self-heal added in 1.5.2 would still pay an IPC
  round-trip on backends that don't emit the workspace `exec` chain
  in the first place. Gated explicitly on
  `writeOptions.injectSwayWorkspaceExec`.

## 1.5.2 — 2026-05-08

### Fixed

- **Workspace placement self-heals on app start.** On a cold boot
  with a docking station already attached, kanshi's `exec swaymsg
  "…"` chain — emitted once per profile activation — could lose its
  race against sway's output discovery. If an output was not yet
  known by name when the chain ran, sway silently dropped the
  affected `output 'X'` targets and workspaces ended up wherever
  they were first created (typically the reverse of left-to-right,
  e.g. 3 / 2 / 1). The GUI now verifies the live `workspace_number
  → output_name` mapping after `init()` against the desired ranks
  computed from the active profile's enabled, non-mirror outputs and
  reapplies the chain only on mismatch. Idempotent — no extra
  swaymsg call when sway is already in the desired state. The chain
  builder is now a top-level helper (`buildSwayWorkspaceChain`) so
  the writer's embedded `exec` line and the controller's recovery
  path stay byte-identical.

## 1.5.1 — 2026-05-07

### Fixed

Audit-driven robustness pass over the freshly-landed 1.5.0 surface.
Four parallel read-only audits (concurrency, workspace-writer,
persistence, UI-reactivity) found the issues below; each fix lands
as its own commit with focused tests.

- **`_reconcileMirrors` now serialises concurrent calls.** The five
  call sites — three of them fire-and-forget (hotplug listener,
  `setActiveProfile`, `_restoreSnapshot`) — could interleave inside
  the non-reentrant `MirrorRunner`. A second concurrent call for
  the same destination would read the first's half-installed
  `_entries[dst]` state and `await stop(dst)` on the just-spawned
  wl-mirror process. Symptom in the wild: flapping mirrors during
  rapid hotplug or hotplug-meets-undo events. Fix is a
  per-controller `Future`-chain lock plus inner `try`/`catch` that
  logs but doesn't poison the chain.
- **Hotplug listener no longer fires after `dispose()`.**
  `_outputSubscription?.cancel()` doesn't abort an in-flight
  handler. The body would call `notifyListeners` on the disposed
  `ChangeNotifier` (asserts in debug) and trigger fire-and-forget
  `_reconcileMirrors` against a torn-down listener registration.
  Added a `_isDisposed` flag set first in `dispose()` and checked
  at the listener entry.
- **Mirror destinations are excluded from workspace-rank
  distribution.** The 1.5.0 chained-exec workspace block built
  `enabledMons` from `mons.where((m) => m.enabled)` only —
  destinations leaked in. wl-mirror's fullscreen surface occludes
  anything sway draws on a destination, so workspaces landing
  there were invisible. The 1.5.0 imperative `move workspace to
  output` form made the misassignment durable across reloads.
  Added the `m.mirrorOf == null` predicate matching
  `LayoutMath.computeDisplay`.
- **HomePage callbacks are cleared on dispose.** `c.onHotplugToast`,
  `c.onProfileSuggestion`, `c.onAutoSwitchedProfile`,
  `c.autoSwitchProfileEnabled`, plus the new `c.onConfigSaveBlocked`
  are all nulled in `HomePage.dispose()`. Without this the closures
  pinned the disposed `State` and pointed the controller at stale
  `widget.settings` on wizard re-entry.
- **EDID manufacturer round-trips losslessly via `\'` escape.** The
  pre-fix writer stripped apostrophes from manufacturer before
  emitting, but the matcher byte-compared against the unstripped
  live data — manufacturers like `L'Hôtel` would silently drop out
  of manufacturer-fallback matching after a save+load. Switched to
  escape-and-unescape; backwards-compatible with 1.5.0-pre-fix
  configs (which never contained apostrophes).
- **GUI refuses to overwrite a kanshi config that uses `include`
  directives.** kanshi's DSL supports splitting profiles across
  files via `include <pattern>`. The GUI parses only the main file,
  so a save would render-and-overwrite without preserving the
  include line — orphaning every profile in the included files.
  `ConfigService` now detects includes at first read and throws
  `ConfigHasIncludesException` from `saveProfiles`. Both controller
  save paths (`_flushSaveAndReload`, `_scheduleSave`) short-circuit
  on the flag. HomePage shows a persistent SnackBar explaining
  why edits aren't landing on disk.

## 1.5.0 — 2026-05-07

### Added

- **Auto-switch to a matching profile on hotplug.** When a known
  monitor set is plugged in, the GUI now switches to the matching
  profile automatically and surfaces a toast with an Undo button
  (Ctrl+Z also works). The behaviour is gated by a new toggle in
  the AppBar gear menu (Settings → "Auto-switch profile on
  hotplug"), default on. Persisted in
  `~/.config/kanshi-gui/settings.json` via an atomic
  write-tmp-then-rename so a crash can't half-write the file.
  Mirror restoration comes for free: the active profile's
  `# kanshi_gui:mirror` annotation triggers `_reconcileMirrors`
  on every profile switch, so re-plugging a beamer that was set
  up for mirroring brings the mirror back without user action.
- **Settings dropdown in the AppBar.** A new gear icon hosts
  GUI-private toggles, starting with the auto-switch flag. Adding
  more knobs later is a matter of dropping another `SwitchListTile`
  into the popup menu.
- **Sidebar active-profile highlight follows the user's sway
  accent.** The hard-coded teal of the active profile row now
  reads `~/.config/sway/config`'s `client.focused` border colour
  at startup (resolving `set $name #color` variables and
  following `include` directives). The drag-time snap guides on
  the layout canvas pick up the same accent. If sway isn't
  installed or the config has no usable colour, both surfaces
  fall back to their historical defaults — the reader is
  best-effort and never errors the app.
- **Snap threshold is no longer absurd.** The default snap
  distance dropped from `500` to `60` logical pixels — the
  former was effectively "always snap" (a quarter of a 1920-wide
  monitor), making intentional small offsets impossible. Free
  placement at e.g. 100 px away now stays free; snapping engages
  only when the dragged tile is genuinely close to alignment.
- **Profile-match dot in the sidebar.** Each profile row now
  shows a small coloured dot at the start: green when every
  profile output is connected (auto-switch would fire here),
  amber for partial matches, grey when nothing matches. Tooltip
  spells out the count and which outputs are missing. The data
  was already computed for the suggestion-toast and auto-switch
  logic; surfacing it makes the sidebar readable at a glance
  instead of forcing the user to mentally map profile names to
  physical setups.

### Fixed

- **Workspaces now relocate reliably across hotplug.** Three
  coupled bugs were leaking windows onto the wrong output after
  docking: (1) multiple `exec swaymsg "..."` lines raced against
  each other because kanshi spawned each in its own fork/exec
  (sway processed them out-of-order); (2) `workspace N output X`
  is passive — it only specifies where workspace N is *created*,
  never relocates one that already exists with windows; (3) bare
  `workspace N` is matched by *name*, so a user with a named
  workspace like `1: code` would silently get a fresh empty `1`
  alongside their existing one. The writer now emits a single
  chained `exec swaymsg "..."` invocation that declares every
  workspace's home up front (using `workspace number N output X`
  to target the numeric slot), then walks 1..9 issuing
  `workspace number N; move workspace to output X` to actively
  relocate each one. Final command is `workspace number 1` so
  focus lands on the leftmost-rank monitor (typically the user's
  primary attention area after docking).

### Improved

- **Profile matching is more robust against port reassignment.**
  Manufacturer/model/serial info from EDID is now persisted in
  the kanshi config as a
  `# kanshi_gui:edid '<port>'='<manufacturer>'` comment
  annotation. Previously the on-disk profile only knew the port
  id, so plugging the same physical monitor into a different
  port (e.g. HDMI-A-1 → HDMI-A-2) broke matching across
  restarts. Within a single session, EDID rehydrates from live
  outputs; the annotation extends that robustness across app
  restarts.
- **`_findProfileMatchingCurrent` now uses claim-based two-pass
  matching.** A profile with a single Samsung output can no
  longer spuriously match a desk with two physically identical
  Samsungs (the old any-match logic let one profile slot claim
  both connected outputs and trip a false-positive auto-switch).
- **Undo against an auto-switch arms the suggestion cooldown.**
  If the user undoes the auto-switch (toast button or Ctrl+Z), a
  flaky cable wiggle that re-emits the same connected set will
  not yank them back into the profile they just walked away from
  for at least 30 seconds.

## 1.4.3 — 2026-05-06

### Fixed

- Mirroring no longer leaves orphan `wl-mirror` processes alive
  after the user clicks "Stop mirroring", and no longer cycles
  into the recursive picture-in-picture state observed in the
  wild on a 2x Samsung + 1x InfoVision setup. Three coordinated
  changes:

  1. **Mirror state is now persisted as a `# kanshi_gui:mirror`
     annotation, not an `exec wl-mirror` hook.** The exec hook
     made kanshi a second lifecycle owner of every wl-mirror
     process: every `kanshictl reload` re-ran the line and
     spawned an additional wl-mirror window on the destination,
     producing duplicates and — when two mirrors targeted each
     other through different paths — recursive PIP. The
     annotation pattern keeps kanshi blissfully ignorant of
     mirroring; the GUI's MirrorRunner is the sole owner.
  2. **`setMirror` and `setWorkspaceRank` now flush the save
     synchronously before triggering `kanshictl reload`.**
     Previously the 600 ms debounce meant the reload could read a
     stale config (with the *previous* mirror's exec hook still
     in it) and respawn the mirror we were about to tear down.
  3. **`MirrorRunner.start` and `.stop` now scan the live
     process table via `pgrep -fa wl-mirror` and kill any
     external instance targeting the same destination.** Combined
     with a new `purgeExternalNotMatching` sweep run from
     `_reconcileMirrors`, this catches orphans left behind by
     older releases, hand-edited kanshi configs that still hold
     `exec wl-mirror` lines, or any GUI session that crashed
     before its `dispose` could fire.

  The parser still accepts the legacy `exec wl-mirror` form for
  backward compatibility — old configs migrate silently on the
  next save.

## 1.4.2 — 2026-05-06

### Fixed

- `deleteProfile` now correctly shifts `_activeProfileIndex` down
  when the deleted profile sat at a lower index than the active
  one. Previously the active index pointed past the end of the
  list (or at a different profile) → `RangeError` on the next
  `activeProfile` access.
- `undo` / `redo` now persist the restored snapshot to disk
  immediately (bypassing the 600 ms debounce) and trigger
  `kanshictl reload` so the live compositor catches up. Before
  this fix the GUI showed the rolled-back layout while the
  compositor still ran the post-mutation one — visually confusing
  and easy to miss.
- `undo` / `redo` cancel any pending custom-mode auto-revert
  timer and any active SafetyNet guard on the way through. Without
  this an `applyCustomMode` that was undone seconds before its
  15-second auto-revert window expired would still fire its
  revert callback and re-apply the pre-custom mode the user no
  longer expected.
- `setActiveProfile`, `renameProfile`, `deleteProfile` now bounds-
  check their `index` argument: out-of-range calls are no-ops (or
  return an `OpResult.err` for `renameProfile`) instead of throwing
  `RangeError`.

### Internal

- Cleaned up dead branch and redundant pre-loop in the hotplug
  listener: the per-id session removal that was duplicating
  `_cancelInFlightDrags`'s work, plus the empty `if (hadActiveDrags)`
  branch that did nothing.
- New `test/end_to_end_smoke_test.dart` (12 tests) exercises a
  realistic user journey through drag + mirror + undo + redo +
  multi-profile flows with cross-feature invariant checks.
- New `test/hardening_edges_test.dart` (17 tests) targets the
  out-of-range guards, mirror-lifecycle/undo interactions,
  layout-math zero-cases, config-write robustness on missing
  directories, identify-on-fully-mirrored setups, and drag pipeline
  edges (snapAndCommit without beginDragSession, no-movement
  drags). 213 tests total, `flutter analyze` clean.

## 1.4.1 — 2026-05-05

### Added

- **Undo / redo with `Ctrl+Z` and `Ctrl+Shift+Z`** (`Ctrl+Y` also
  works as a redo alias). Every mutation that touches profile state
  pushes a deep snapshot onto the undo stack before applying its
  change: drag commits, scale commits, mode changes, custom modes,
  enable/disable, mirror set/clear, workspace-rank changes,
  rearrange-layout, profile create/rename/delete, and profile
  switches. Drags are recorded against the **pre-drag rollback**
  (not the last mid-drag frame) so undo always returns to where the
  layout was when the drag started. The stack is capped at 30
  entries; redo lives only until the next mutation, at which point
  the forward path is invalidated. A drag cancelled by hotplug or
  profile-switch leaves no undoable entry — the rollback is silent
  by design.

## 1.4.0 — 2026-05-05

### Added

- **Drag-to-mirror**: drop a monitor tile substantially on top of
  another (≥70% area coverage) and a confirmation dialog asks
  whether to set up a mirror. Confirming reverts the drag-position
  and calls `setMirror`; declining continues with the regular
  snap-and-commit position drag. The detection lives as a pure
  geometry helper (`LayoutMath.detectMirrorDropTarget`) so it has
  no extra coupling to the gesture pipeline; it runs only after
  `onPanEnd` so the existing snap/alignment math is untouched
  during the drag itself. Disabled tiles and mirror destinations
  are skipped as drop targets — the latter are filtered out of the
  layout entirely, so a drop on their phantom rect would feel
  arbitrary. Available only on backends that support mirroring AND
  when wl-mirror is installed; otherwise the menu-based
  "Mirror onto…" path remains the only way in.

## 1.3.6 — 2026-05-05

### Added

- Hotplug events now surface a "Setup matches profile X (N of M
  outputs). Switch?" SnackBar when the connected output set fits a
  non-active profile better than the currently active one. The
  controller never auto-switches — kanshi already does its own
  matching and we don't fight it — so the toast is purely
  informational with a "Switch" action that activates the
  suggestion. Suggestions are suppressed for 30 seconds after a
  manual profile switch so the user isn't nagged into reverting
  what they just chose. Confidence is `matchedScore /
  max(profileEnabled, currentEnabled)`, where each match
  contributes 1.0 (id-exact) or 0.7 (manufacturer-only fallback);
  the default floor is 0.5.

## 1.3.5 — 2026-05-05

### Added

- "Identify Displays" now also reports the physical screens hidden
  behind a mirror. Mirror destinations are filtered out of the GUI
  layout entirely (their pixels belong to the source), so they used
  to be invisible during identify. The controller now numbers all
  enabled outputs — sources, regular tiles, and destinations — and
  the source tile renders small cyan `+N` chips next to its main
  identify number, one per destination it occupies. The swaynag
  banner spawn keeps skipping destinations: their physical screens
  already display the source's number via wl-mirror, and printing a
  second banner on a hidden workspace would just be noise.

## 1.3.4 — 2026-05-05

### Internal

- Audited the coordinate-system contract for mixed-scale (1× + 2×)
  layouts. The codebase is already internally consistent: tile
  `x`/`y` are logical (post-scale) layout coordinates — the same
  space Sway's `output position X Y` IPC and kanshi's config syntax
  consume — while `width`/`height` are the physical panel mode
  dimensions, with `scale` tying them together. A 4K display at
  scale 2.0 placed flush-right of a 1080p neighbour sits at
  `x = 1920`, not `x = 3840`. Locked the contract in place with
  golden tests (`test/hidpi_mixed_scale_test.dart`) and a
  load-bearing doc-comment on `MonitorTileData`.

## 1.3.3 — 2026-05-05

### Fixed

- A monitor unplugged or replugged in the middle of a tile-drag no
  longer leaves the canvas in a half-committed state. The controller
  now exposes a monotonically increasing `dragCancelEpoch`; the
  Sway-style hotplug listener and `setActiveProfile` bump it whenever
  they invalidate in-flight drags. Each tile snapshots the epoch at
  `onPanStart` and aborts subsequent `onPanUpdate` / `onPanEnd`
  events when the value advances — the dragged tile snaps back to
  its pre-drag origin and no commit is sent. The pre-drag rollback
  is also stored inside the controller's drag session so the rollback
  is applied to the active profile, not just the visual position.

## 1.3.2 — 2026-05-05

### Fixed

- Subprocess calls (`swaymsg`, `wlr-randr`, `kanshictl`, …) can no
  longer hang the apply pipeline indefinitely. `ProcessRunner.run`
  now enforces a default 5-second timeout: if the child is still
  alive when the timer fires it gets `SIGTERM`, then `SIGKILL`
  500ms later, and the call returns a synthetic non-zero
  `ProcessResult` whose `stderr` reads `"<exe>: timed out after 5s"`.
  Streaming subscriptions (`swaymsg -t subscribe -m`) are
  unaffected — they're long-running by design.

## 1.3.1 — 2026-05-05

### Changed

- Saving the kanshi config is now crash-safe and keeps a rolling
  history of the last 10 versions. Each save first snapshots the
  current live config to `~/.config/kanshi/config.bak.<unix-ms>`,
  then writes the new content to a temporary sibling and renames
  it over the live file (atomic on POSIX). Older backups beyond the
  newest 10 are pruned. Previously a single `config.bak` was
  overwritten on every save and the live file was rewritten in
  place, so a crash mid-write — or a writer regression — could
  leave an unrecoverable half-written config and clobber the only
  rollback point.
- `restoreBackupAndApply` now picks the newest timestamped backup,
  not a fixed `config.bak` path.

### Internal

- `ConfigService.backupPath` constructor argument renamed to
  `backupPrefix`. The default value is unchanged
  (`~/.config/kanshi/config.bak`), but new backups are written as
  `<prefix>.<unix-ms>` instead of overwriting the prefix itself.

## 1.3.0 — 2026-05-05

### Added

- "Workspace position" submenu on each monitor tile's three-dot menu.
  Pick `Position 1`/`Position 2`/… to override which slot this monitor
  occupies in the left-to-right workspace distribution, or `Auto
  (left-to-right)` to clear the override and fall back to X-position.
  Choosing a slot that another monitor already holds swaps with that
  monitor so all positions stay unique. Overrides are persisted in the
  kanshi config as `# kanshi_gui:rank '<id>'=<n>` annotations and read
  back on the next app start / `kanshictl reload`.

### Changed

- Workspace numbering on the Sway backend is now **interleaved
  left-to-right**, not ascending in blocks. With N enabled outputs,
  workspace `w` lands on the monitor whose left-to-right rank equals
  `(w - 1) mod N`. So two screens give the left one workspaces
  1/3/5/7/9 and the right one 2/4/6/8; three screens give 1/4/7,
  2/5/8, 3/6/9. The number-keys 1..9 thus walk left-to-right across
  the displays and loop back as you press higher numbers, matching
  what most users perceive as "workspace 1 = first screen".

  Previous releases (≤1.2.2) numbered ascending from the leftmost
  monitor and only assigned one workspace per screen; 1.2.3 (skipped)
  briefly tried right-to-left blocks of three. Both turned out to be
  the wrong default — the interleaved scheme keeps the keys 1..N
  walking the displays in physical order regardless of how many
  monitors are attached.

## 1.2.2 — 2026-05-05

### Changed

- Mirror layout now collapses both physical screens into a single tile
  in the GUI, with cyan accent + "⇄ Mirrors to <dst>" label, instead of
  parking a separate ghost destination tile in a side lane. Two
  monitors that show the exact same pixels were rendering as two
  independent tiles, which suggested they had separate roles in the
  layout — they don't. The "Stop mirroring to X" item moved to the
  source tile's three-dot menu so the mirror can be released without
  reaching for an absent destination tile.

## 1.2.1 — 2026-05-05

### Fixed

- Mirror feature now actually mirrors. The previous release built the
  `wl-mirror` invocation in the wrong order (`wl-mirror SRC
  --fullscreen-output DST --fullscreen`), which wl-mirror rejected with
  "unexpected trailing arguments after output name" — the user saw a
  blank blue window appear on a random workspace. Both the live spawn
  and the kanshi-config exec hook now use the correct order:
  `wl-mirror --fullscreen-output DST SRC`. Parser accepts both orders
  for forward compatibility.

### Added

- "Identify displays" lightbulb now also flashes the number on the
  physical screen via `swaynag` (Sway only) — not just inside the GUI
  canvas. Disabled and mirrored tiles are skipped (the latter would
  otherwise paint twice on the source's pixels). On wlr-randr-based
  compositors the in-GUI overlay remains the only identify aid.

## 1.2.0 — 2026-05-05

### Added

- **Display mirroring** on the Sway backend. Open a tile's three-dot menu
  → "Mirror onto…" → pick another enabled output to make this monitor
  show the same content. The relationship is per-profile; switching
  profiles tears down the mirrors of the previous profile and brings up
  the new ones. "Stop mirroring" releases the bond again.

  Sway 1.11 has no native `output mirror` IPC, so the engine is the
  external `wl-mirror` tool. The Debian package now `Recommends:
  wl-mirror`, so a default `apt install kanshi-gui` pulls it in
  automatically; users who don't need mirroring can opt out with
  `--no-install-recommends`. On other backends (wlr-randr, noop) the
  menu entries are hidden entirely; on Sway without wl-mirror
  installed, they are also hidden until the binary is in `$PATH`.

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
