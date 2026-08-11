# Changelog

## 2.0.3

### Fixed

- **Workspaces above the number of screens had no home.** On a three-screen
  desk, `$mod+4` through `$mod+9` opened wherever the cursor happened to be.
  Since M9 a setup that had ever been observed used its recorded
  workspace map *instead of* the distribution rule — but sway only reports the
  workspaces that currently exist, so what got recorded was whatever was open
  at that moment. Three workspaces up meant three homes written, and the other
  six had no `workspace N output X` line anywhere in the config. sway puts an
  unbound workspace on the focused output, and the next observation then wrote
  that accident down as a preference. The rule now covers 1–9 unconditionally
  and an observation only overlays it, so a hole is no longer expressible.

- **The workspace layout is declared on every launch.** The startup repair pass
  compared the live mapping against the intended one and did nothing when they
  agreed — but a workspace that has no home *and* does not exist yet is
  invisible to that comparison, which is exactly the case that was broken.
  The `workspace N output X` half of the chain is silent and idempotent, so it
  now runs unconditionally; the focus-and-move half still only runs on a real
  mismatch, and still never steals the focus on a quiet launch.

### Added

- **The workspace setting is reachable again**, under Advanced → Workspaces,
  on sway. Four choices: leave them alone, let the number keys walk left to
  right (1 4 7 · 2 5 8 · 3 6 9 on three screens), give each screen one
  contiguous block, or keep them where you put them. Underneath the choice the
  sheet spells out what it does to *your* screens, because the question people
  actually have is where `$mod+9` takes them.

### Changed

- **Learning where you put your workspaces is now one of those four choices,
  not the behaviour underneath all of them.** M9 applied it to everyone,
  including users who had explicitly asked for a distribution; the setting kept
  saying `interleaved` while the app did something else. A config still
  carrying `# kanshi_gui:ws` annotations while a rule is selected is corrected
  on the next launch — the annotations are an observation, not your data, and
  the "keep them where I put them" mode records the setup you are on again the
  moment you pick it.

### Known limitation

- Within a running sway session, a workspace that already has the *wrong* home
  keeps it. sway appends each `workspace N output X` to a list and uses the
  first entry that resolves, so a later declaration can fill a missing binding
  but never replace one (`sway/commands/workspace.c`,
  `workspace_get_initial_output`). Workspaces that never had a home — the ones
  that were opening under the cursor — are fixed immediately; a stale one
  clears on the next login, or right away with
  `swaymsg reload && kanshictl reload`.

## 2.0.2

### Added

- **Setups can be renamed.** `renameProfile` had existed on the controller
  with no caller since M8 deleted the profile rail that used to reach it, so a
  setup the app captured for you stayed called `Setup 1` forever. The setups
  popover now offers **Rename** and **Forget** as words rather than as two
  unlabelled icons — a name you cannot change is not a default, it is a
  constraint, and guessing which pictogram means "rename" is the same problem
  one step later. Duplicate and unusable names are refused with the reason,
  and a rename is undoable.

### Changed

- **Clicking empty canvas closes the screen settings.** Selecting a screen
  opens the settings strip at the foot of the window; dismissing it required
  finding its ✕. Clicking away from a thing is what dismisses it everywhere
  else. Clicking a *different* screen still just moves the selection.

### Notes

- A profile literally named `Current Setup` — written by versions before
  2.0.1, which reused that one name for every captured setup and so
  overwrote the previous desk — is treated as an ordinary profile of yours.
  Nothing re-points it, and new captures take their own number beside it.
  There is now a test for exactly that, because the old behaviour is the
  reason those profiles are in people's configs at all.

## 2.0.1

A repair release. 2.0.0 shipped with a canvas that did not draw, which made
the app unusable — everything below follows from that and from what looking
into it turned up.

### Fixed

- **The screens are visible again.** The canvas rendered at zero height, so
  every tile was scaled by a factor of 0 and the area where the monitors
  belong was simply empty. Nothing threw and nothing was logged: the Scaffold
  hands its body a loose height, every child of the canvas Stack is a
  `Positioned.fill`, and a Stack with no non-positioned child takes no height
  from that. Until 2.0.0 the title bar sat inside that Stack and gave it a
  height by accident; promoting it to a real `appBar` removed the accident.
  There are now widget tests that measure the rendered boxes rather than
  merely assert the widgets exist — the whole test suite passed while the app
  showed nothing, and only a measured test can tell those two apart.
- **A setup captured for you gets its own name.** When no saved profile fits
  the connected screens, the app captures them so there is always something
  to arrange. That capture was always called "Current Setup" and reused by
  name, so a second desk overwrote the first desk's capture. Captures are now
  numbered — `Setup 1`, `Setup 2`, taking the lowest free number — and a
  capture is only ever re-pointed while you have not edited it. Once you
  arrange it, it is yours and the next unknown desk gets its own.
- **Pressing "remember the screens I have now" twice no longer creates two
  profiles with the same name.** Names are the key the config file is edited
  by, so two profiles sharing one collapsed into a single block when saved.
- **Docking into an unknown arrangement re-points the captured setup** instead
  of leaving you editing a layout that is not in front of you. A profile you
  chose or edited yourself is never taken away from you.
- **A screen you switch off stays on the canvas.** Disabled screens are parked
  in a lane beside the arrangement, and that lane was projected outside the
  visible area — so "use only this screen" made the others vanish, taking
  their "Enable display" menu with them and leaving no way back. The fit now
  includes them: a little smaller, but there.
- **The canvas can no longer be scaled to nothing.** A zero-height viewport or
  a `scale 0` typo in the config made the projection factor zero, which draws
  every screen at 0x0 — visually identical to the 2.0.0 bug, and reachable
  from a file this app does not own. The projection has a floor, a
  non-positive scale is treated as 1, and the window now requests a minimum
  size instead of only a default one.
- **The presets pill no longer sits on top of your screens.** It is painted
  above the tiles and takes clicks, so on a short window it covered them and
  swallowed drags, resize grips and the three-dot menu. The arrangement is
  fitted above it now.
- **The title bar's buttons reach the right edge.** A `Flexible` and a
  `Spacer` were splitting the free space between them, so Identify and
  Advanced were stranded near the middle of the bar with a few hundred pixels
  dead to their right — on every launch, at every window size.

### Packaging

- The release page carries the changelog section for its version instead of an
  empty body.
- A build whose package glob matches nothing now fails instead of publishing an
  empty release marked "latest" under a tag that cannot be reused.
- `wlr-randr` is recommended, so the app finds a backend on wlroots
  compositors other than sway rather than falling back to doing nothing.

## 2.0.0

A major version. The short version: it no longer loses your layout, it no
longer loses your config, and it stopped asking you questions it can answer
itself.

### Fixed — the reported bug

- **Your arrangement and your workspaces survive a reboot and a redock.**
  Profiles were addressed by connector name (`DP-1`), which `kanshi(5)`
  explicitly warns "may change across reboots … or creation order (typically
  for USB-C docks)". The stable EDID identity was already in the file, but in
  a comment only this app could read. Profiles are now written as
  `output "Make Model Serial"`, which kanshi matches natively, and the sway
  workspace chain uses the same identity. Migration is evidence-based: a
  descriptor is only ever written after a backend actually reported it, never
  guessed.
- The hotplug path had no debounce at all. Docking is a salvo of events, and
  every one of them ran the full pipeline against a half-connected set.
- `reapplyActiveProfile` shelled out to a bare `kanshictl reload`, which does
  nothing on a machine that starts kanshi from the sway config and so has no
  socket. It goes through the full reload chain now.

### Fixed — data loss

- **Saving no longer rewrites your config file.** It used to re-render the
  whole file from the model, so anything the model could not express was
  deleted on the first save: `include`, `alias`, global `output` defaults,
  hand-written `exec` lines, braced `output { … }` blocks, `adaptive_sync`,
  and every comment. A hand-written config could be emptied outright. There
  is a real scfg parser now, and the save edits the document in place.
- Configs using `include`, and configs with syntax the model cannot read, are
  editable again — they were blocked only because rewriting them was unsafe.
- The mode of a rotated output oscillated between `1920x1080` and
  `1080x1920` on every save, so every second save asked the panel for a
  resolution it does not have.
- Two concurrent saves could clobber each other and roll the file back to the
  state before the edit.
- "Restore backup" restored the file and then immediately overwrote it with
  the in-memory profiles.
- A profile name containing an apostrophe produced a config kanshi refuses to
  parse, which stops display management entirely.

### Fixed — the safety net

- Setting the countdown to 0, labelled "Off", made every mode change and
  every disable revert *instantly* instead of not at all.
- Revert closures wrote into a detached list, so the compositor turned a
  screen back on while the model and the config kept saying `disable`.
- A revert could restore into the wrong profile if you switched during the
  countdown, and a failing revert was silent and unretryable.
- The lockout guard counted disconnected outputs, so on the train you could
  switch off the only screen you actually had.

### Changed — the interface

- One status line replaces the health banner, the drift banner, the
  safety-net bar and seven toasts, which could all appear at once. Its green
  check is rendered from a comparison that actually ran; when something could
  not be verified, the sentence gets weaker rather than quieter.
- The safety-net countdown is a card over a dimmed canvas, mirrored onto
  every screen via swaynag — the window asking the question may itself be on
  the screen that just went black. Enter keeps, Escape reverts, and nothing
  else does either.
- Drift is drawn instead of described: your screen stays where the setup
  wants it and a dashed outline shows where it actually is.
- A title bar and a setups list replace the 248px rail; a bottom strip that
  is zero-height at rest replaces the 300px inspector. The canvas gets both
  back.
- A design-token layer, applied centrally — including to menus, dropdowns and
  dialogs, which render in their own overlay and had been left on Material
  defaults. The light theme now reaches the whole app instead of a third of
  it.
- The corner grip no longer deforms the screen it represents.
- Switching a screen off no longer shrinks the ones you are still using.

### Removed

- Twelve preferences, the settings screen and the first-run wizard. Snap
  distance, countdown lengths, toast toggles, backup count and the accent
  override are derived, fixed, or read from sway. Where the workspaces go is
  learned from where you put them, per setup, rather than chosen from
  "interleaved or grouped".

### Internal

- CI now runs `flutter analyze --fatal-infos` and the test suite on every
  push and pull request; releases are cut from tags rather than from every
  commit to main. Neither was true before.
- 358 → 558 tests, including the project's first widget tests and a golden
  corpus of real kanshi configs.
- `KanshiController` lost eleven collaborators (2,793 → ~2,650 lines despite
  everything added), and the config, geometry and identity logic moved into a
  Flutter-free `lib/domain/`.

## 1.6.2 — 2026-05-29

### Fixed

- **Drift banner now surfaces after a drag, not just on hotplug.** 1.6.1 only
  recomputed drift on hotplug events / explicit reloads, so a drag whose live
  apply succeeded at the IPC level but got silently auto-arranged by Sway
  (e.g. a sibling shifted to resolve an overlap) left the cached output
  snapshot stale and the banner never appeared. `pushLiveApply` now
  schedules a `refreshConnectedMonitors()` ~200 ms after the apply returns,
  which re-reads Sway's actual post-apply state and recomputes drift.

## 1.6.1 — 2026-05-28

### Fixed

- **Hotplug "layout drift" is now detected and fixable in one click.** When a
  monitor is re-plugged, kanshi-daemon occasionally re-matches the profile
  but silently drops a `position X,Y` directive — Sway then parks the
  re-appearing output at its hotplug-default spot and the live layout no
  longer matches the active profile (the GUI's preview is right, the screens
  aren't). The controller compares the active profile against the live
  output positions on every hotplug event and surfaces an orange banner with
  the per-output mismatch; "Re-apply" runs `kanshictl reload` (the manual
  fix). Tolerance 2 px to absorb scale rounding; disabled outputs and mirror
  destinations are excluded from the check. The check is **snapshot-based**,
  not live: dragging a tile mutates the profile coords ahead of the
  compositor, which would otherwise flap the banner every frame; the cached
  snapshot only refreshes when the live layout actually changes.
- **Optional auto re-apply on drift** (Settings → Behavior, off by default):
  fires `kanshictl reload` automatically ~1.5 s after a hotplug if the live
  layout drifted. The banner still surfaces while we wait, so dismissing it
  also dismisses the queued auto-reapply for that hotplug cycle.

## 1.6.0 — 2026-05-22

### Fixed

- **Live apply is the default again (opt-out).** Edits go straight to the
  compositor as you make them and there is no Apply button; the "unapplied"
  indicator is therefore always accurate (nothing is ever pending). Turn it
  off in Settings → Behavior to stage changes behind an explicit Apply.
- **Performance: dropped the real-time blur and isolated static layers.**
  The frosted `BackdropFilter`s were recomputed every drag frame; they're
  gone (translucent fills instead), and the dot-grid backdrop, profile rail
  and header now live in their own `RepaintBoundary`s so dragging a monitor
  only re-rasterises the canvas. Snappy again.
- **Opening the app no longer touches your config — or your screens.**
  Previously every launch silently re-rendered and rewrote your kanshi
  config (even with zero edits); combined with kanshi auto-reload that could
  re-apply a layout where outputs ended up *overlapping* — in the worst case
  a screen landed on top of the GUI. Now a fresh launch captures your setup
  in memory only and writes nothing until you make a deliberate edit.
- **The tool can never emit an overlapping layout.** A new overlap guard
  (`LayoutMath.resolveOverlaps`, idempotent) runs before every config write:
  if any enabled outputs would overlap, they're repacked flush, left-to-
  right. Sway happily stacks outputs that share coordinates, so this is the
  load-bearing fix against the "screen on top of the GUI" disaster. Explicit
  reload/apply additionally validates the layout up front and auto-arranges
  before applying.
- **Apply has an optional auto-revert safety net.** When enabled (Settings →
  Behavior, *off by default* so routine applies don't nag), applying a layout
  snapshots the previously-applied config and arms a countdown; if you can't
  see the new layout to click "Keep", it rolls back to the last working
  config automatically. Apply always refuses to leave you with no enabled
  output (lockout guard).

### Changed

- **Reworked UI into a "dark editor" look.** The draggable monitor canvas
  you know stays — everything around it grew up: a frosted top bar showing
  the active profile, a persistent left profile rail (with active-glow,
  hover actions and live match dots) replacing the slide-in sidebar, a
  dot-grid canvas backdrop, and redesigned monitor tiles (rounded, soft
  status glow, status dot + glyph, fact chips, a proper resize grip). The
  whole app now derives its colours from a Material 3 scheme seeded from
  your accent, so buttons, sliders and switches finally feel of-a-piece.
- **Workspace management is now opt-in.** Previously, launching kanshi_gui
  on Sway immediately redistributed workspaces 1–9 across your monitors —
  great if you wanted it, jarring for a new user who didn't. It now
  defaults to **off**: a fresh install never touches your workspaces until
  you turn it on, either in a new first-run wizard step or via the settings
  menu. Existing installs are migrated to keep their previous always-on
  (interleaved) behaviour, so nothing changes for current users.

### Added

- **Two workspace distribution modes.** When management is enabled you can
  choose *interleaved* (the historical layout — 1/3/5… on the left screen,
  2/4/6… on the right) or *grouped* (contiguous bands — e.g. 1–5 left, 6–9
  right). Selectable in the wizard and the settings page; switching applies
  immediately.
- **Dedicated settings page** replacing the cramped gear dropdown, with
  grouped sections and a pile of new options:
  - *Behavior* — toggle hotplug notifications and profile-match suggestions;
    tune the safety-net countdown (0 disables it) and the custom-mode
    auto-revert delay.
  - *Layout & editing* — adjustable snap distance; toggle scale snapping.
  - *Appearance* — Light / Dark / System theme, an accent-colour override
    (or auto-from-Sway), and identify-banner duration.
  - *Mirror (Sway)* — wl-mirror scaling mode (fit / cover / exact).
  - *Advanced* — backup-retention count, a kanshi-config path override, and
    a "reset all settings to defaults".
- **Properties inspector.** Click a monitor to open a side panel with proper
  controls for resolution/refresh, scale, rotation, mirror and enable —
  replacing the cramped right-click submenus. The selected tile gets a
  brighter ring + glow.
- **Quick-layout presets.** A floating bar with one-click *Extend* (all
  outputs side-by-side), *Mirror* (everything onto the leftmost), and
  *Single* (use one output, disable the rest). Presets preview into the
  layout; you still hit Apply to push them live.
- **Explicit Apply button + "unapplied changes" indicator** in the header,
  and a **startup health banner** that warns when kanshi isn't installed/
  running or wl-mirror is missing.

## 1.5.13 — 2026-05-15

### Fixed

- **Reverted the 1.5.12 `mirror (<dst>)` named-workspace claim.** It
  swapped one annoyance (an unreachable auto-numbered ws like "10")
  for another (an unreachable named ws "mirror (eDP-1)" in the bar).
  Orphan workspaces are now displaced through the regular numeric
  chain re-run instead.
- **`_verifyAndFixWorkspacePlacement` now also fires when a workspace
  outside the 1..maxWorkspaces range is alive on any output.** The
  earlier mismatch check only looked at workspaces in the desired
  map, so a leftover ws 10 from an earlier session — visible on the
  output but not part of the desired 1..9 set — slipped through. The
  re-run cycles focus through every numeric workspace, displacing
  the orphan; sway then garbage-collects the now-empty workspace.
- **`setMirror` force-applies the workspace chain.** `kanshictl
  reload` does NOT re-fire its `exec swaymsg "…"` line for a still-
  active profile, which left sway's binding table out of sync with
  the GUI's in-memory model after every `setMirror(null)` /
  set-mirror toggle. The chain is idempotent enough that an
  unconditional re-run is cheap, and the live state finally matches
  what the rank ordering says it should.

## 1.5.12 — 2026-05-15

### Fixed

- **Mirror destinations no longer leave an unreachable orphan
  workspace in the bar.** Sway enforces "one workspace per active
  output", so a mirror destination — which the rank-based ws 1..9
  distribution deliberately skips — gets an auto-numbered workspace
  on activation (typically 10 on a default 1..9 keybind setup). The
  user sees that 10 in the bar but can't `$mod+0` it. Writer now
  emits a `workspace 'mirror (<dst>)' output '<dst>'; workspace
  'mirror (<dst>)'` claim at the tail of the Sway exec chain so the
  output is filled by a named workspace instead. The auto-numbered
  orphan is empty + not focused once the named workspace becomes
  visible → Sway garbage-collects it on the next focus event.
- Boot-time guarded `exec wl-mirror` line now also passes
  `--scaling fit` (parity with the GUI's MirrorRunner — a 1.5.11
  oversight where the flag was added on the Dart side only).

## 1.5.11 — 2026-05-15

### Fixed

- **Mirror no longer triggers an infinity-cascade when wl-mirror is
  running.** The 1.5.7 fix had stacked the mirror destination onto
  the source's rectangle in sway coordinates to keep the cursor from
  wandering into a "dead zone" on the dest output. That's fine when
  wl-mirror isn't running, but the moment it is: wl-mirror creates a
  fullscreen layer-shell surface on the dest output, sway happily
  paints that same surface onto every output whose geometry overlaps
  the dest's rect (the source rect, in this case), wl-mirror then
  re-captures the source — which now contains its own surface — and
  projects that onto the dest. Two outputs at identical coords plus
  one screen-capture process = an 1980s-VCR-style infinity mirror.
  Writer no longer overrides the destination's position; mirrors now
  occupy their own rectangle. The cursor-routing concern (the
  original motivation for stacking) is left to the GUI's placement
  layer.
- **`pgrep`-guarded mirror exec no longer self-matches.** 1.5.10's
  guard used `pgrep -f "wl-mirror --fullscreen-output X"` to skip a
  duplicate spawn, but `pgrep -f` matches against the FULL argv of
  every process — including the very shell running the guard, whose
  argv contains the pattern verbatim. The guard always found itself,
  always reported "already running", and so wl-mirror never started
  at boot. The replacement filters by process *name* with
  `pgrep -x wl-mirror -a` (the guard shell's process name is `sh`,
  not `wl-mirror`) and then `grep -qF -- "--fullscreen-output <dst> "`
  for the destination match — literal substring, trailing-space
  pinned so e.g. `eDP-1` can't match a hypothetical `eDP-10`.
- **wl-mirror now spawns with `--scaling fit` explicitly.** It's the
  documented default, but a user-visible crop ("bottom edge of the
  source missing on the destination") was reported anyway when
  source and destination had different logical sizes. Setting the
  flag pins the behaviour against any ambient default and is harmless
  when fit was already in effect.

## 1.5.10 — 2026-05-15

### Fixed

- **Mirrors actually mirror at boot now.** The 1.5.7 fix had stacked
  the mirror destination onto the source's position so Sway didn't
  treat it as a separate interactive zone — but the wl-mirror process
  itself was only spawned by the GUI's MirrorRunner. When kanshi
  applied a mirror profile at session start (before any GUI was
  running), both outputs ended up overlapping at the same coords with
  no content-mirroring at all, just two independent outputs fighting
  for the same rectangle. Workspaces leaked onto the destination, the
  user saw the wrong content, and opening the GUI from that state
  buried the leftover windows under wl-mirror's fullscreen layer.

  Two changes together close the gap:

  1. **Guarded `exec wl-mirror`.** The writer now emits a
     `pgrep`-guarded shell exec for each mirror destination, e.g.
     `exec sh -c 'pgrep -f "wl-mirror --fullscreen-output eDP-1"
     >/dev/null || wl-mirror --fullscreen-output "eDP-1" "DP-1" &'`.
     This spawns the mirror at session start when no GUI is running,
     and the pgrep guard prevents `kanshictl reload` from stacking
     duplicate wl-mirror processes — the exact failure mode that got
     the old `exec wl-mirror` line removed in the first place. The
     GUI's MirrorRunner still takes ownership at runtime by killing
     the kanshi-spawned instance and replacing it with a managed one
     (single owner while the GUI is up; best-effort owner via kanshi
     for the boot window).

  2. **Reconcile evacuates new mirrors.** `_doReconcileMirrors` now
     runs the same evacuation pipeline `setMirror` uses — move
     workspaces off the destination, wait for the output to clear —
     before asking the MirrorRunner to spawn. This fires when init
     finds a mirror profile already active (kanshi applied it before
     the GUI launched) or when a hotplug brings a new mirror partner
     online. Without it, workspaces sitting on the destination from
     before the mirror started ended up buried under wl-mirror's
     fullscreen layer, unreachable until the user manually moved
     them. `setMirror` still does its own evacuation up front and
     now tells reconcile to skip the second pass (`evacuateNewMirrors:
     false`), so the IPC chain doesn't run twice on the same path.

  Parser updated to ignore the new guarded-exec form (the `pgrep -f
  "wl-mirror …"` substring would otherwise be misread as the actual
  mirror invocation); the canonical `# kanshi_gui:mirror` annotation
  stays in charge of mirror-state hydration.

## 1.5.9 — 2026-05-12

### Fixed

- **Profile-suggestion banner no longer pesters with strictly worse
  alternatives.** `findBestProfileSuggestion` always returned the
  best non-active profile that cleared the 0.5 confidence floor —
  but never compared it against the active profile's own score. The
  result: a user on a 3-of-3-output profile was nagged "Setup matches
  profile 'Mobile' (2 of 3 outputs)" every hotplug, because the
  alternative cleared the floor even though it was a strict
  regression. The function now also scores the active profile and
  suppresses the suggestion unless the candidate strictly beats it.
  Tied candidates also no longer trigger — switching sideways between
  two equivalent profiles produces no user-visible improvement.

## 1.5.8 — 2026-05-12

### Fixed

- **Workspaces above N (3 on a 3-monitor setup, 2 on a dual-monitor
  setup) no longer land on whichever output the cursor happens to
  be on.** The Sway workspace-distribution chain was emitting the
  output bindings with the `number` keyword:

      workspace number 5 output 'DP-5'

  Sway parses this and returns `success: true`, but the binding never
  takes effect — `workspace_outputs` is keyed by workspace name, and
  the `number` variant stores under a key sway never looks up at
  workspace creation time. With no binding in force, `$mod+5` from
  a different output created ws 5 on the focused output rather than
  its assigned home, exactly as users had been reporting.

  Phase 1 of the chain (the persistent output binding) now emits
  the no-`number` form:

      workspace 5 output 'DP-5'

  Empirically verified against sway 1.11: the binding survives
  workspace destruction + recreation, so every `$mod+N` from then on
  goes to the assigned monitor regardless of which output is currently
  focused. Phase 2 (the focus + force-move pass that relocates
  pre-existing workspaces) still uses `workspace number N` so the
  rename-safety guarantee for users who renamed their workspaces
  (e.g. `1: code`) is preserved.

  As a side effect, the workspace layout now self-applies at session
  start without the GUI being open: kanshi runs the `exec swaymsg
  "…"` line on every profile match, and the bindings it lays down are
  persistent for the rest of the sway session.

## 1.5.7 — 2026-05-12

### Fixed

- **Mirror destination no longer leaves an input dead-zone.** The 1.5.6
  mirror fix kept the destination output at its original position in
  Sway's coordinate space, which meant the user could still move the
  cursor onto the (now-empty) destination and "lose" interactivity —
  `wl-mirror` paints the source's pixels there but Sway routes input
  to whichever output the cursor is over. The writer now emits the
  mirror destination at the *source's* `position` so the rectangles
  overlap; cursor at the shared coords stays on the source and
  `wl-mirror` keeps painting the destination because it targets by
  output name, not by position.
- **Drag-then-cancel and undo/redo cycles no longer spam the backup
  directory.** `ConfigService.saveProfiles` now short-circuits when
  the rendered output is byte-identical to the live config: no
  backup, no atomic write, no prune. Eliminates the "wall of
  near-duplicate `config.bak.<unix-ms>` files within minutes" pattern
  reported by users who fiddle with layouts.

### Changed

- **Backups moved out of `~/.config/kanshi/` into `~/.config/kanshi/
  backups/`.** Default `backupPrefix` now lands timestamped backups in
  a dedicated sub-directory so the main config directory stays tidy.
  Existing `config.bak.<ts>` files are relocated lazily on the first
  save by the new release, and the orphaned pre-1.3.1 single-file
  `config.bak` (which no rotation logic ever cleaned up) is removed
  in the same migration pass. Idempotent; the migration runs once per
  process.

## 1.5.6 — 2026-05-12

### Fixed

- **Mirror toggle no longer buries windows under `wl-mirror`.** Setting
  a mirror via the GUI used to spawn `wl-mirror` on the destination
  output without first relocating the workspaces that already lived
  there. The `kanshictl reload` triggered by the save does NOT
  guarantee that kanshi re-runs its `exec swaymsg "…workspace number
  …"` chain (same matched profile name → kanshi can skip the
  re-apply), so any workspace whose home was on the about-to-be-mirror
  output stayed put and got visually covered by the new `wl-mirror`
  fullscreen — including kanshi_gui's own window, leaving the GUI
  unreachable until the user killed the process.

  `setMirror` now actively evacuates the destination before
  `wl-mirror` spawns:

  - Reads the live `swaymsg -t get_workspaces` mapping and moves every
    workspace currently on the mirror destination — numeric AND named,
    including slots > 9 that the writer's 1..9 chain does not cover —
    to one of the remaining non-mirror outputs (round-robin),
    refocusing whatever workspace the user was on at the end.
  - Waits up to 400 ms for the destination to actually report empty
    before handing it to `wl-mirror`.
  - Runs the standard verify-and-fix workspace placement pass
    afterwards, so the normal interleaved distribution also kicks in
    when releasing a mirror.

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
