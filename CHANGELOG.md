# <span style="color:#109EFF">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## v2026111803-beta.1 - 2026-11-18

### Fixed

- Report the numeric brightness target throughout every fade, including fades to
  custom presets. Report the preset ID when the fade settles.
- Make the simulator's target helper read Director's displayed brightness target
  so conformance tests catch stale targets during a fade.

## v2026111802-beta.1 - 2026-11-18

### Fixed

- Report the numeric brightness target during fades to Default On, Previous On,
  and Off. This avoids the transient `65535` target reported on Control4 OS
  3.4.3. Settled notifications still identify the preset.

## v2026111801-beta.1 - 2026-11-18

### Added

- Show native member outages in Driver Status and the Settings tab.

### Fixed

- Keep the last brightness and keypad LED state when all native members go
  offline. During a partial outage, reconcile commands with reachable members.
- Preserve the last confirmed sync state and pause automatic scene matching
  during a known outage.
- Prevent failed or incomplete member reads from replacing the group’s
  brightness with stale feedback.
- Send configured keypad colors when the proxy first makes them available.
- Keep valid brightness feedback when a native member sends an out-of-range
  color temperature.

### Changed

- Update the shared Light V2 template to v0.9.113, use Composer’s supported fade
  limit of 999,999 ms, and check preprocessed Lua globals per driver package.

## v2026111504-beta.1 - 2026-11-16

### Added

- Correlated control and feedback diagnostics with millisecond timing,
  per-member send failures and a read-only light engine snapshot.
- Fresh Lua reload checks for saved settings and three independent groups using
  standard, native and mixed member transports.
- Light Group driver: groups any Light V2 lights into one light with brightness,
  color and color temperature, on modes, presets, rates, Advanced Lighting
  Scenes and On, Toggle and Off button links.
- Brightness and color tracking by average, brightest, dimmest or a selected
  light.
- Color temperature emulation for color-only lights, and mapping onto each
  light's own range.
- Light Type, Off Command and Command Delay settings.
- Display Lights, Display Control Log and Sync Lights actions.
- Settings tab with the group's lights and their states, a checkbox picker for
  the lights by room, and the driver's properties.
- Keep Lights In Sync setting, and a Test Light Commands action.
- Scene cycle: steps through the Advanced Lighting Scenes that use the group's
  lights from a Scene Cycle Button Link, programming or the Settings tab, with a
  chosen order, an optional Off step, back-and-forth and restart-after.
- Track Current Scene: the scene cycle follows the lights, so a scene activated
  any way is the current one and none is once the lights are changed.

### Fixed

- Keep missing startup levels unknown until real member feedback arrives.
- Continue sending to other members if one member's command raises an error.
- Cancel queued transport and engine work when the driver unloads.
- Skip an unchanged color command before a brightness ramp, avoiding a separate
  turn-on that can interrupt the fade. Compare each light's reported color on
  its own range, including mapped and emulated whites.
- Turning an already-on group on again restores the group's color to an off
  member as it rejoins.
- The Settings tab compares each member's color as well as its brightness, and
  shows a new color selected while the group is off.
- Preserve scene discovery with the updated Composer tab kit.

### Changed

- Extend the shared light engine's display callback to include brightness and
  full color, and use the UI kit's authenticated request helper for scene reads.
  These additions are maintained as a patch against template v0.9.109.
- Update the shared template to v0.9.109 and replace the private light model
  with the shared Light V2 engine, retaining universal Light V2 membership,
  tracking modes, color temperature mapping and emulation, and scene cycling.
- Members that confirm the template's group protocol receive brightness and
  color together. Other lights continue to use standard Light V2 commands.
- Add timed transport checks and the shared conformance suite for both member
  transports, including delayed color echoes, keypad release and member ranges.
