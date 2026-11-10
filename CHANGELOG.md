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

## Unreleased

### Added

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
