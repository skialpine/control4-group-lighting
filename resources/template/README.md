# Pending shared template additions

`light-reliability.patch` contains local changes against
[finitelabs/control4-driver-template v0.9.109](https://github.com/finitelabs/control4-driver-template/tree/v0.9.109)
(commit `a8101b444d79e4e4c238fabd81d2c3c18935f8c7`). It includes shared source,
example integration and upstream tests. It has not been published upstream.

The changes were developed in a separate template checkout, tested through a
fresh Copier render, then copied into this driver's template-owned files:

- `src/lib/light.lua`: unload cleanup and read-only diagnostics.
- `src/lib/light/proxy.lua` and `types.lua`: complete display state callbacks.
- `src/lib/ui/page.js`: public authenticated JSON requests.
- `test/light_rig.lua` and `light_conformance.lua`: optional reload checks.

The `.copier-answers.yml` revision remains v0.9.109. Keep this patch when
updating with Copier until these additions are incorporated upstream; otherwise
Copier may report conflicts or replace them. Apply it to the stated template
revision with `git apply light-reliability.patch`. The driver-specific
transport, startup-state, logging and reload tests are maintained in this
repository.
