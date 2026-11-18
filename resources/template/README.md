# Pending shared template additions

`light-reliability.patch` contains local changes against
[finitelabs/control4-driver-template v0.9.113](https://github.com/finitelabs/control4-driver-template/tree/v0.9.113)
(commit `71379181d3aee40f102bb20ea11e4920825ddbfb`). It includes shared source,
example integration and upstream tests. It has not been published upstream.

The changes were developed in a separate template checkout, tested through a
fresh Copier render, then copied into this driver's template-owned files:

- `src/lib/light.lua`: unload cleanup and read-only diagnostics.
- `src/lib/light/proxy.lua` and `types.lua`: complete display state callbacks
  and keypad notifications for colors learned after the proxy's capability update.
- `src/lib/ui/page.js`: public authenticated JSON requests.
- `test/light_rig.lua` and `light_conformance.lua`: optional reload checks
  and conformance coverage for late keypad colors.
- `tools/globals.py` and `test_globals.py`: compare preprocessor globals within
  each driver's package and its literal dependencies.

Keep this patch when updating with Copier until these additions are incorporated
upstream. Apply it to the stated template revision with
`git apply light-reliability.patch`. The driver-specific
transport, startup-state, logging and reload tests are maintained in this
repository.
