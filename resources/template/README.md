# Pending shared template additions

`light-reliability.patch` contains local changes against
[finitelabs/control4-driver-template v0.9.117](https://github.com/finitelabs/control4-driver-template/tree/v0.9.117)
(commit `1041c5fe4fd0329fd5363a5da65e9e710362baa4`). It includes local changes
to shared source, example integration, and tests.

The changes were developed in a separate template checkout, tested through a
fresh Copier render, then copied into this driver's template-owned files:

- `src/lib/light.lua`: unload cleanup and read-only diagnostics.
- `src/lib/light/groups.lua`: skip missing group drivers and clear stale
  memberships after a second project lookup confirms their absence.
- `src/lib/light/proxy.lua` and `types.lua`: complete display state callbacks
  and keypad notifications for late colors.
- `src/lib/ui/page.js`: public authenticated JSON requests.
- `test/light_rig.lua`, `light_proxy_fake.lua`, and `light_conformance.lua`:
  optional reload checks, Director target readback, and conformance coverage
  for late keypad colors and brightness preset fades.
- `tools/globals.py` and `test_globals.py`: compare preprocessor globals within
  each driver's package and its literal dependencies.

Keep this patch when updating with Copier until these additions are incorporated
upstream. Apply it to the stated template revision with
`git apply light-reliability.patch`. The driver-specific
transport, startup-state, logging and reload tests are maintained in this
repository.
