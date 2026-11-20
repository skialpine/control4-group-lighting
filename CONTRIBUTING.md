# Contributing to control4-group-lighting

## Project Structure

This project uses [Copier](https://copier.readthedocs.io/) to manage shared
infrastructure across multiple Control4 driver repositories. Shared code lives
in a [template repo](https://github.com/skialpine/control4-driver-template) and
is synced into each driver project.

### What's Managed by the Template

These files are owned by the template and **should not be edited directly** in
this repo. Change them in the
[template repo](https://github.com/skialpine/control4-driver-template) instead,
then pull the change in with `copier update`.

**Build tooling:**

- `Makefile`: build, format, docs, package, and clean targets
- `.github/workflows/build.yml`: CI build and packaging
- `.github/workflows/release.yml`: tagged GitHub releases. The updater offers a
  release only when its tag's date is later than the installed driver's version,
  so give each release a later date than the last. A suffixed tag such as
  `v20260918-rc1` publishes as a pre-release, which only drivers on the
  Prerelease update channel pick up. Title the pull request that dates the
  changelog `release: vYYYYMMDD` (case and the colon don't matter):
  `.github/workflows/label-release-pr.yml` then labels it `skip-release-notes`,
  which `.github/release.yml` leaves out of the generated release notes. It
  labels a template update the same way: a title like
  `chore: copier update to template vX.Y.Z`, or any pull request opened with a
  change to `_commit` in `.copier-answers.yml`. So keep a template update in a
  pull request of its own, or the changes riding along with it drop out of the
  notes too; if one does ride along, remove the label and it stays off. Adding
  that label by hand leaves any other pull request out of the notes too

**Common libraries (`src/lib/`):**

- `bindings.lua`: binding management
- `companions.lua`: gives each of a hub driver's bindings a companion driver,
  one at a time: the one it had, a spare, or a new one, named and shown only in
  its room
- `conditionals.lua`: conditional/programming UI management; gives each one a
  `sort_order`
- `driver-filenames.lua`: every `.c4z` the repo builds, written in by the build
- `drivercentral.lua`: the DriverCentral product, its cloud client and the
  license gate (see [The License Gate](#the-license-gate))
- `events.lua`: event firing and management
- `http.lua`: HTTP client wrapper
- `logging.lua`: structured logging with configurable levels, the Log Level
  property's list and the drivers-common-public dumps (see
  [Log Level](#log-level))
- `lru.lua`: LRU cache utility
- `persist.lua`: persistent storage abstraction
- `redact.lua`: masks credentials in log lines below Ultra and in diagnostics
  reports
- `support-code.lua`: the Support Code that opens a DriverCentral build's Lua
  window (see [The Support Code](#the-support-code))
- `update-settings.lua`: keeps Automatic Updates and Update Channel the same on
  every item of the drivers the repo builds, in DriverCentral and OSS builds. A
  driver's Reset Driver leaves both as they are
- `utils.lua`: general utilities (XML, device queries, table helpers, type
  coercion)
- `values.lua`: value parsing, coercion, and formatting
- `ui/`: the kit for a custom Composer tab (see
  [Custom Composer Tabs](#custom-composer-tabs))
- `light.lua` and `light/`: the Light V2 library, which a light driver is an
  adapter over (see [Writing a Light Driver](#writing-a-light-driver))
- `github-updater.lua`: GitHub Releases self-updater (OSS builds)

**Vendor libraries (`vendor/`):**

- `JSON.lua`: JSON encoder/decoder
- `deferred.lua`: promises/deferred implementation
- `drivers-common-public/`: Control4's official shared libraries
- `xml/`: XML parser (xml2lua)
- `cloud-client-byte.lua`: DriverCentral cloud licensing
- `version.lua`: semver comparison (used by github-updater)

**Tools (`tools/`):**

- `preprocess.py`: C-style `#ifdef`/`#ifndef` preprocessor for Lua, XML, and
  Markdown
- `docs.py`: documentation generation (Markdown -> HTML -> PDF, plus README) and
  the Markdown formatting `make fmt` runs
- `globals.py`: the `make check` step that fails when a build reads a global an
  `#ifdef`/`#ifndef` branch took away, such as a `local function` inside
  `--#ifndef DRIVERCENTRAL` that shared code calls. The tests load the source
  with every branch in, so they can't see it.
- `package.py`: packaging helpers (driver.xml stamping, zip bundling)
- `deps.py`: build preflight, checks the `.venv` against `requirements.txt`
- `gen-squishy.lua`: auto-generates squishy files from driver.c4zproj
- `github-markdown.css`: vendored stylesheet for the rendered docs
- `github-setup`: checks the GitHub repo against the standard settings and
  prints the drift; `--apply` fixes it
- `test_preprocess.py`: tests for `preprocess.py`'s `#embed` and
  `#driver-filenames` directives

**Other:**

- `.gitignore`, `LICENSE`, `CONTRIBUTING.md`
- `requirements.txt`, the build-time Python dependency list
- `test/testlib.lua`, `test/c4_fixtures.lua`, `test/c4_shim.lua`,
  `test/run_test.sh`, `test/driver_restores_probe.lua`, and the
  `test/test_*.lua` suites covering shared code
- `test/light_proxy_fake.lua`, `test/light_rig.lua`, `test/light_group_rig.lua`,
  `test/light_drivers.lua`, `test/light_conformance.lua`,
  `test/test_light_conformance.lua`, `test/light_contract_cases.lua` and
  `test/light_setup/`, the Light V2 conformance kit, and `tools/light-caps.lua`
- `.copier-answers.yml`, which Copier maintains; never edit it by hand

### What's Driver-Specific (Yours to Edit)

- `src/constants.lua`: driver-specific constants
- `drivers/*/driver.lua`: main driver logic
- `drivers/*/driver.xml`: driver XML configuration
- `drivers/*/driver.c4zproj`: driver packaging manifest
- `drivers/*/www/`: documentation and icons
- `CHANGELOG.md`, seeded by the template on first render and left alone after
  that
- `resources/drivercentral/`: the DriverCentral listing, seeded once. Besides
  the banners and photos it holds `description.md`, the listing's description.
  It starts from the docs' Overview and Features, written to sell the driver
  rather than document it. Its first image is the facts strip, uploaded through
  DriverCentral's description editor, which gives the URL for its `src`
- Any additional `src/` modules specific to this driver
- Any additional `vendor/` libraries specific to this driver
- `test/` suites written for this driver, and the local support files they
  require (`test/c4_local.lua`, `test/<prefix>_fixtures.lua`)

`README.md` is in neither list: it is **generated**. `make build` rewrites it
from the driver's `www/documentation/index.md`, so edit the source doc, not the
README.

Driver docs can use GitHub's alerts: a quote whose first line is `[!NOTE]`,
`[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]`. The README, the HTML doc
and the PDF all show them as GitHub does. The marker goes alone on its line, and
the quote must not sit inside a list or another quote; otherwise it stays a
plain quote that shows the marker.

Images that every driver's docs share, the Finite Labs logo
(`finite-labs-logo.png`) and `check-drivers.png` (the DriverCentral Cloud
driver's Check Drivers action), ship with the template in
`resources/documentation/images/`. A doc that links `./images/<name>` and has no
copy of its own gets the template's at build time, so a driver's `images/` holds
only its own.

## Updating Shared Code

Copier is only needed for this occasional sync. It is **not** a build dependency
and is intentionally not installed by `make init`, so run it without installing
anything:

```bash
uvx copier update --trust        # using uv (https://docs.astral.sh/uv/)
# or:
pipx run copier update --trust   # using pipx
```

Copier shows diffs for any files that changed and lets you resolve conflicts. It
tracks which template version you're on via the `.copier-answers.yml` file
(committed to the repo). To update every driver repo, run the same command in
each one.

## Build System

This project uses `make` for build orchestration. All tooling is Python (in a
local `.venv`) plus a few standalone binaries, with no Node/npm. A repo that
adds Node tooling of its own pins the version in `.node-version`, which nodenv
reads locally and the Build workflow sets up in CI.

### Prerequisites

- Python 3.9+ (docs, formatters, preprocess, and driverpackager)
- Git, since `make init` clones the driverpackager into `dist/`
- [LuaJIT](https://luajit.org/) (`brew install luajit`) to run
  `tools/gen-squishy.lua` and the tests
- [stylua](https://github.com/JohnnyMorganz/StyLua) (`brew install stylua`), the
  Lua formatter
- [Pango](https://gtk.org/) (`brew install pango`), WeasyPrint's PDF rendering
  engine
- `swig` and OpenSSL headers (`brew install swig openssl`), which M2Crypto
  compiles against

`make init` creates the `.venv`, installs everything in `requirements.txt`
(WeasyPrint, markdown-it-py, mdit-py-plugins, Pygments, mdformat, black, and the
driverpackager's M2Crypto + lxml), and clones the driverpackager into
`dist/driverpackager`. It is safe (and cheap) to re-run: the install is keyed on
`requirements.txt`, so a template update that adds a dependency reinstalls on
the next `make init` or `make build` rather than leaving the existing `.venv`
stale.

### Common Commands

```bash
make help          # List every pipeline step, plus init/build/fmt/clean
make init          # Install all dependencies (safe to re-run)
make check-deps    # Install if needed, then verify .venv matches requirements.txt
make build         # Full build, from clean through zip (see Build Pipeline)
make build-nodocs  # Build without generating docs
make verify        # After a build, check what CI checks after one
make test          # Run the Lua test suite (test/test_*.lua) and tools/test_*.py
make support-code  # Print today's Support Code (see The Support Code)
make dc-release    # Download the newest release's DriverCentral upload (TAG=v... for another)
make fmt           # Format all code (Lua, Python, Markdown)
make check         # Assert formatting, docs list spacing, per-build globals, build secrets and conditional sort_order, as CI does
make clean         # Remove build artifacts and dist/ (including driverpackager)
make clean-all     # Remove everything (build artifacts, dist, deps, venv)
```

Every step in the pipeline below is also a target of its own, and `make help`
lists them all. The sub-targets those steps delegate to (`fmt-lua`, `fmt-py`,
`fmt-md`, `docs-html`, `docs-pdf`, `docs-readme`, `update-xml-version`,
`update-xml-modified`) are real targets too, but carry no `##` annotation, so
`make help` does not print them. Note that the later steps read `build/`:
`make docs` pulls in `preprocess` itself, but `make package` and `make zip` fail
on a clean tree until something has populated `build/`.

### Build Pipeline

`make build` runs these in order, starting from a cleaned `build/`:

1. **Format**: stylua (Lua), black (Python), mdformat (Markdown)
1. **Preprocess**: resolve `#ifdef`/`#ifndef` directives per distribution. In
   Markdown, where a removed directive sat between two list items, the list
   keeps its own spacing; `make check` fails on a built list spaced unevenly
1. **Generate squishy**: create squish manifests from .c4zproj files
1. **Update driver.xml**: stamp version date and modified timestamp
1. **Generate docs**: Markdown -> HTML -> PDF, plus README and DriverCentral's
   Revisions
1. **Package**: run driverpackager to create .c4z files
1. **Zip**: bundle the c4z and docs folders per distribution

The driver.xml step stamps today's date as the version unless `DRIVER_VERSION`
is set. On a tag build CI sets it to the tag's date, so the tag must be
`vYYYYMMDD` or `vYYYYMMDD-suffix` or the build fails.

A repo with no driver yet (no `drivers/*/driver.xml`) builds and verifies
nothing, and CI uploads nothing, so a new repo's first pull request goes green.

Each distribution's outputs are grouped by type under `dist/<distribution>/`:
`c4z/` (packaged drivers), `docs/` (generated PDFs) and `source/` (the squished
per-driver Lua). `<repo>.zip` sits alongside them and contains `c4z/` and
`docs/` only: `source/` is the driver's unencrypted Lua, which an encrypted
driver must not ship.

`dist/drivercentral/listing/` holds what a DriverCentral upload needs beyond the
zip and the PDFs. `description.html` is the listing's description, made from
`description.md` in `resources/drivercentral/`. `revisions.html` is the
Revisions tab, every released `CHANGELOG.md` section as the DriverCentral build
shows it. The product card, the banners and the listing photos are copied from
`resources/drivercentral/`. A tag build's drivercentral CI artifact is the whole
upload. `make dc-release` downloads the newest release's into
`dist/release/<tag>/`, or another's with `TAG=v20261111`, and stops if any
`.c4z` in it is not encrypted. It needs the GitHub CLI, signed in. When the
artifact has expired, run the Build workflow on the tag again from the Actions
tab.

While `description.md` still has `FACTS-STRIP-URL` for the facts strip,
`description.html` leaves the strip out and the build prints a warning. Upload
`banners/facts-strip-2400x136.png` through DriverCentral's description editor
and put the URL it gives in its place.

Step 1 rewrites tracked files in place. Formatting covers `tools/*.py`, all Lua
under `drivers/`, `src/`, `test/`, `tools/` and `vendor/`, and every Markdown
file at the repo root, under `documentation/`, and under
`drivers/*/www/documentation/`, so it reformats this file, the driver docs you
author, and the generated `README.md` too. CI fails the build if it finishes
with a dirty tree, so build on a clean checkout and commit whatever the
formatter changes.

After the build CI runs `make verify`, which runs the same locally: every
distribution made a PDF (`verify-pdfs`), every `.c4z` is at `DRIVER_VERSION`
when one is given (`verify-version`; CI gives the tag's date on a tag build),
and the tree is clean (`verify-clean`).

### Distributions

Every repo builds two distributions, each its own set of `.c4z` files with code
paths selected by `#ifdef` directives: `drivercentral`, which defines
`DRIVERCENTRAL`, and `oss`, which defines `OSS`.

The DriverCentral build reports to DriverCentral as the product named by the
`dc_pid` answer in `.copier-answers.yml`. It is 0 until the product exists in
DriverCentral's vendor panel. Setting it and running `copier update` is all a
repo needs before its first DriverCentral upload.

Every DriverCentral build is packaged encrypted, `encryption="2"` on each
driver's `<script>`, and `make package` deletes its plain-text
`dist/<build>/source`: a sold driver's Lua, its license check included, never
ships or uploads readable. Only `driver.lua` is encrypted, so any other file a
driver loads from its `.c4z` stays readable. An `oss` build is encrypted only
when it substitutes a build secret.

## Writing Tests

A test is a plain Lua script in `test/`, named `test_*.lua`, run by `make test`
or `./test/run_test.sh test_something.lua`. There is one convention, and every
suite in this repo follows it.

```lua
local T = require("testlib")

T.section("What is under test")
T.eq("the name of the case", got, want)

T.finish()
```

Three shared modules, split by what they depend on:

- **`testlib.lua`** is the harness: assertions, grouping, and the pass/fail
  pipeline. Plain Lua, no Control4 in it. Always required.
- **`c4_shim.lua`** mocks the Control4 `C4:*` environment. `make test` and
  `run_test.sh` preload it, so a suite that drives driver code gets it for free.
- **`c4_fixtures.lua`** holds the reusable C4 seams built on the shim. Require
  it only when you need one.

### Assertions

Assertions accumulate rather than throw, so one run reports every failure
instead of stopping at the first. Each takes the case name first.

| Call                                     | Passes when                                           |
| ---------------------------------------- | ----------------------------------------------------- |
| `T.check(name, ok, detail)`              | `ok` is truthy; the base the others build on          |
| `T.eq(name, got, want)`                  | `got` equals `want`, comparing tables by value        |
| `T.neq(name, got, unwanted)`             | `got` differs from `unwanted`                         |
| `T.truthy(name, v)` / `T.falsy(name, v)` | `v` is / is not truthy                                |
| `T.contains(name, haystack, needle)`     | `needle` occurs in `haystack`                         |
| `T.excludes(name, haystack, needle)`     | `needle` does not occur                               |
| `T.raises(name, fn, expected)`           | `fn` throws, and the message holds `expected`         |
| `T.raisesAt(name, fn)`                   | `fn` throws with the error blamed on the calling file |

`T.excludes` is the one to reach for when the point is that a secret never
reaches the output, because it reports the offending text on failure.

Supporting calls: `T.section(name)` starts a numbered group, `T.capture(fn)`
runs `fn` with `print` collected and returns `ok, err, output`, and
`T.unload(pattern, ...)` drops matching `package.loaded` entries so the next
`require` rebuilds whatever the module caches.

### Ending a test

`T.finish()` prints the summary and sets the exit code. Do not keep your own
`pass`/`fail` counters, print your own summary, or call `os.exit` yourself.

### C4 fixtures

`c4_fixtures.lua` carries the seams that need the shim:

- `F.withShim(opts, body)` reloads the shim with luasocket forced present or
  absent and restores every global afterwards. With `{ luasocket = true }`,
  `body` gets a clock whose `advance(seconds)` moves time forward and fires
  whatever came due. Returns `ok, err`.
- `F.captureTcpClient()` swaps in a `C4:CreateTCPClient` that records every
  write and completes the connect synchronously. Read `.writes`, then
  `.restore()`.
- `F.dofileBuild(path, build)` runs a Lua file as the `"drivercentral"` or
  `"oss"` build compiles it, with its `#ifdef` blocks applied. A driver loaded
  raw runs every arm.
- `F.virtualClock(opts)` runs `C4:SetTimer` and `C4:GetTime` on a virtual clock,
  so a test plays minutes of timers at once and in a fixed order. Drive it with
  `run(ms)` and `at(ms, fn)`, read `now()` and `errors` (what a timer or promise
  callback threw), then `restore()`.
- `F.repoRoot()` is the repo's root. `F.seedProperties(xml)` sets `Properties`
  to each default a `driver.xml` declares, and `F.answerConfig(xml)` answers the
  version reads from it, so a driver loads as it does on a controller.

### Persisted values

As on a controller, a `C4:PersistSetValue` reads back only once it lands, about
50 ms after the call, and until then `C4:PersistGetValue` answers what the store
held. A delete reads back at once, and a write still waiting lands after it. A
value written encrypted reads back only with the encrypted flag, so a suite that
seeds or reads such a key passes the flag the driver does.

The shim lands a write when it moves time on: `ShimFireTimers` lands every write
made before it, `C4:ProcessTimers` each one 50 ms old by its clock, and
`ShimUpdateDriver` and `ShimRestartDirector` all of them. A suite that calls
into the driver itself calls `ShimPersistLand()` where one call ends and the
next begins, such as before a reload, and before it reads what was stored. A
suite that needs a write read back at once calls `ShimPersistLater(false)`.

### Driver-local test support

Support code specific to this driver stays in this repo. Two files mirror the
shared pair above, split by what the code is *about*:

- **`test/c4_local.lua`** for environment seams: a `C4:*` method, or a bare
  global the driver code calls, that the shim does not provide. Reach for this
  instead of adding to `c4_shim.lua`, which the template owns, so anything local
  in there becomes merge surface on every `copier update`.
- **`test/<prefix>_fixtures.lua`** for domain fixtures: mocks shaped like this
  driver's own protocol or API, parallel to `c4_fixtures.lua`. Use a short
  prefix taken from the driver name.

Both `require("c4_shim")` and build on the C4 environment rather than replacing
it. Neither runner needs telling about them: `make test` collects only
`test_*.lua`, and both put `test/` on `LUA_PATH`, so `require("c4_local")`
resolves on its own.

Promote either one into the template only once a second driver needs it.

### Library restores

A library that keeps saved state names, in its `RESTORE` field, the restore a
driver owes it and the init that restore belongs in. `lib.values` and
`lib.bindings` want `restoreValues()` and `restoreBindings()` in `OnDriverInit`,
and `lib.events` wants `restoreEvents()` in `OnDriverLateInit`.

`test/test_driver_restores.lua` holds every driver to them. For each
`drivers/*/driver.lua`, `test/driver_restores_probe.lua` loads the OSS build in
a fresh process and runs `OnDriverInit`, then `OnDriverLateInit`. A driver fails
when its code loads one of these libraries and doesn't call its restore in that
init. A driver that loads none owes none. A new library that keeps saved state
declares its own `RESTORE`, and the test covers it with no list to update.

## Writing a Light Driver

`src/lib/light.lua` owns the Light V2 proxy and the Button Links: their commands
and notifications, presets, on modes, Dim-To-Warm, scenes, fades, and what the
proxy is told. `src/lib/light/types.lua` is the contract: what a driver gives
the library and what it gets back. A light driver gives it four things:

- A profile, once: what the driver offers the proxy. The build writes
  `driver.xml`'s light capabilities from it (`tools/light-caps.lua`), so
  `driver.xml` carries none of them. Just above its `<capabilities>` element it
  carries this line instead, and the build stops without it:
  `<!-- The light's capabilities are the build's, written from the profile the driver gives Light.new. -->`
- An adapter with `send`, `refresh` and `show`: it puts each command on its
  transport, asks the device for its whole state, and mirrors what the proxy
  shows on a device page.
- `light:declare(device)` on each connection, before its first report: what this
  device can do, how it fades, and how its reports behave.
- `light:report(report)` for every device state, and `light:lost()` when the
  connection goes.

`Light.new(adapter, profile)` runs once, at the driver chunk's top level.
`light:start()` runs in `OnDriverLateInit`, and `light:reset()` from Reset
Driver.

`test/test_light_conformance.lua` proves each light driver over the repo's own
`test/light_rigs.lua`, written to the rig interface in `test/light_rig.lua`.
Each rig loads its driver as it ships and fakes only its transport, and the
cases in `test/light_conformance.lua` judge what a fake proxy
(`test/light_proxy_fake.lua`) is told and where the device ends. A light group
driver's rig is `test/light_group_rig.lua`'s `rig(name, property)`: two fake
member lights behind the group as it ships. A repo with no light driver and no
rigs passes with a note.

`test/light_contract_cases.lua` holds named scenarios with the exact commands
the library sends an adapter for each. An adapter's own wire test feeds those
commands to its `send` and checks what goes on the wire.

The library, its kit and its cases are the template's: a change to them goes to
the template, where its own tests and fuzzer run, and reaches each repo at its
next `copier update`.

### Tools tests

`make test` also runs each `tools/test_*.py` with `python3`. These test the
Python tools in `tools/` with the standard library's `unittest` and need no
`.venv`.

## Preprocessor Directives

The `tools/preprocess.py` script supports C-style conditional compilation. It
walks every file in the build tree and matches four comment styles: Lua (`--#`),
XML and Markdown (`<!-- # -->`), C and JavaScript (`// #`), and bare `#`
directives with no comment prefix.

```lua
--#ifdef DRIVERCENTRAL
local supportCode = require("lib.support-code")
--#else
DRIVER_GITHUB_REPO = "skialpine/control4-group-lighting"
--#endif
```

```xml
<!-- #ifdef DRIVERCENTRAL -->
<Driver type="c4z" name="driver_dc" squishLua="true">
<!-- #else -->
<Driver type="c4z" name="driver" squishLua="true">
<!-- #endif -->
```

It also resolves `<!-- #embed-changelog -->`, which splices `CHANGELOG.md` into
the generated documentation, and `<!-- #embed <path> -->`, which splices the
file at `<path>`, relative to the file holding the directive. Both run as a
pre-pass, so directives inside the spliced text are still honored. A missing
`<path>`, or an `#embed` inside an embedded file, fails the build.

### Variant Expansion

Drivers can define variants via a `variants.json` file. The preprocessor expands
these into multiple driver directories with substituted values, generating one
.c4z per variant combination. Variants can be listed flat or given as
`dimensions`, in which case the cross-product is expanded.

Substitute a variant value with `__NAME__`, or with `%%NAME%%` in Markdown,
where `__NAME__` would render as bold instead.

In any Lua file, `-- #driver-filenames` emits one `"<name>.c4z",` line per
driver the build packages, variants included, `<name>` being the `<Driver name>`
its `driver.c4zproj` gives in that build, so a list of the repo's drivers never
goes stale. `lib/driver-filenames.lua` holds the repo's list that way, for the
GitHub updater and `lib/update-settings.lua`.

`readme_driver_slug` may name a generated variant, e.g. `<driver>_<suffix>`.
`make build` takes the README and its images from the build output, where only
the generated variants exist.

### Build Secrets

Values that must not live in the repository, such as a cloud API's OAuth client
secret, are substituted into the build tree at preprocess time. Each one is a
`__NAME__` placeholder in source (`%%NAME%%` in Markdown), the same syntax as a
variant value:

```lua
API_CLIENT_SECRET = "__EXAMPLE_CLIENT_SECRET__"
```

`.env.default`, committed at the repository root, declares every name, one
`NAME=` line each, with a comment saying what it is and where to get it. A repo
without it has no build secrets. `tools/preprocess.py` reads only the declared
names, and takes each value from, in order:

1. the process environment
1. `.env`, gitignored: for a local build, `cp .env.default .env` and fill it in
1. on macOS, the login Keychain: a generic password with the service
   `control4-driver-build` and the name as its account, so no file holds it

To put one in the Keychain (`-w` last, with no value, prompts for it and keeps
it out of shell history):

```bash
security add-generic-password -s control4-driver-build -a NAME -w
```

In CI, the Build workflow passes `make build` each build secret by name from the
repository's GitHub Actions secrets (add each name under Settings > Secrets and
variables > Actions), so `make build` and the tools it runs never see any other
secret. The template passes its own: `SUPPORT_CODE_SECRET`, `SUPPORT_PHONE` and
`SUPPORT_EMAIL` with a DriverCentral build, and the four `INFLUXDB_*` with Cloud
Monitoring. A driver's own go in the copier answer `extra_build_secrets`
(`uvx copier update --trust --data extra_build_secrets="NAME OTHER"`), and
`make check` fails when `.env.default` and the workflow disagree. Each value is
a single line.

A name with no value builds as an empty string with a warning, so a pull request
from a fork, which gets no secrets, still builds. A tag build sets
`REQUIRE_SECRETS`, and a missing value fails it, so a release never ships
without them. The build log says only whether each name was set.

When a build substitutes any placeholder, every driver in it is packaged
encrypted (`encryption="2"` on its `<script>`, set in the build copy of
`driver.xml`), and `make package` deletes the plain-text squished Lua in
`dist/<build>/source`, so neither the `.c4z` nor a CI artifact carries the value
in the clear. Only `build/` keeps it, and that is gitignored and never uploaded.
Keep placeholders out of documentation, since a PDF is not encrypted. The two
exceptions are the support contacts a DriverCentral build's docs give, which are
meant to be read: the secret only keeps them out of the repository. Write the
phone number as `[%%SUPPORT_PHONE%%](tel:__SUPPORT_PHONE__)` and the email
address as `[%%SUPPORT_EMAIL%%](mailto:__SUPPORT_EMAIL__)`, each inside
`#ifdef DRIVERCENTRAL`. The link takes the `__NAME__` form, since mdformat
escapes a `%` in a link. Set `SUPPORT_PHONE` with dashes, `+1-NNN-NNN-NNNN`, so
it also makes the `tel:` link. Only the docs and their PDFs give the contacts.
The README comes from the OSS docs, which never show them, and the listing
description, `resources/drivercentral/description.md`, gives neither.

A DriverCentral build is packaged encrypted with or without a secret.
`make package` then opens every package of an encrypted build and fails unless
each holds `driver.lua.encrypted`, no `driver.lua`, and a `driver.xml` that asks
for encryption.

### The License Gate

`lib/drivercentral.lua` is a DriverCentral build's link to DriverCentral: the
product it sells as, the cloud client that licenses it, and the gate that stops
the driver while it has no license. The client keeps the license in `DC_X`: 1
when licensed (a showroom license too), minus the hours left in a trial, and 0
without one. It is 0 from the driver's late init until the DriverCentral Cloud
driver first answers, and it turns 0 when the Cloud driver stops answering for a
minute.

The gate reads `DC_X` every 10 s and stops the driver after five minutes of 0,
longer than a Cloud driver update or a slow boot, and starts it again as soon as
a license is back. With `dc_pid` 0 the client never starts and the gate stops
the driver at its load, so a build made before its product exists does not run.

Each driver of a DriverCentral build starts the client first in `OnDriverInit`
and the gate at the end of `OnDriverLateInit`:

```lua
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
--#endif

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
  --#else
  C4:AllowExecute(true)
  --#endif
end

function OnDriverLateInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(licensed)
    -- Stop or start the connection, and show why in Driver Status.
  end)
  --#endif
end
```

A driver that talks to a device or a cloud checks `drivercentral:licensed()` at
the one place every command passes on its way out, and shows
`drivercentral.UNLICENSED_STATUS` in Driver Status while it is stopped. An OSS
build has no gate, so those calls sit inside `#ifdef DRIVERCENTRAL` too. A
companion that reaches its device only through another driver needs no gate of
its own. Never gate `ExecuteCommand` ahead of the client: the license arrives
through it.

`test/dc_cloud.lua` is a fake Cloud driver that answers the real client, for
testing a driver's gate; `test/test_drivercentral.lua` shows how.

### The Support Code

A DriverCentral build calls `C4:AllowExecute(false)`, which closes Composer's
Lua window to anything typed into it. The Support Code opens it again for an
hour, for support on a system the build runs on. The code changes every UTC day,
and `make support-code` prints the day's code. Entering it again closes the
window early, and so does reloading the driver; a code from yesterday is taken
until 01:00 UTC.

The code is an HMAC of the date under the build secret `SUPPORT_CODE_SECRET`,
which `lib/support-code.lua` takes inside an `#ifdef DRIVERCENTRAL`, so an OSS
build never carries it. Declare it in `.env.default`, give it to CI as an
Actions secret, and keep it in the Keychain for local builds and
`make support-code`. Make it with `openssl rand -hex 32`: it goes into a Lua
string as it is. A secret shorter than 32 characters, or none, turns the code
off: such a build takes no code at all. A tag build fails without it, as for any
build secret.

Each driver of a DriverCentral build takes the code through a property at the
end of its Driver Settings:

```xml
<!-- #ifdef DRIVERCENTRAL -->
<property>
  <name>Support Code</name>
  <type>STRING</type>
  <default/>
  <description>Enter only a code from Finite Labs support. It opens the Lua window for an hour.</description>
  <password>true</password>
</property>
<!-- #endif -->
```

Its `driver.lua` takes the library next to its other requires:

```lua
--#ifdef DRIVERCENTRAL
local supportCode = require("lib.support-code")
--#endif
```

and the property's handler with its other property handlers:

```lua
--#ifdef DRIVERCENTRAL
--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end
--#endif
```

The library clears the property at once, keeps its value out of the dispatcher's
Trace output, and prints its answer to the Lua output whatever Log Mode is.
While the window is open, Log Level also offers Trace and Ultra (see
[Log Level](#log-level)). A web tab's properties card follows the window by
itself, once the driver calls `lib.ui.tab-properties`' `serve()`. A driver that
shows more elsewhere while the window is open passes
`supportCode:onChange(function(open) ... end)`.

### Log Level

Every driver has the same Log Level property. An OSS build offers `0 - Fatal` to
`6 - Ultra`; a DriverCentral build stops at `4 - Debug`, and offers `5 - Trace`
and `6 - Ultra` only while the Support Code has the Lua window open, since they
show nothing the open window doesn't. The property is a `DYNAMIC_LIST` with no
items, the same in both builds, and the logger fills its list:

```xml
<property>
  <name>Log Level</name>
  <type>DYNAMIC_LIST</type>
  <default>3 - Info</default>
</property>
```

It can't be a `LIST`: Composer takes no `LIST` value that `driver.xml` doesn't
list, so a level added at runtime would show and not stick. Its handler hands
the value to the logger:

```lua
function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end
```

`log:setLogLevel` never goes above what the build allows, puts the property back
to `4 - Debug` when it shows more, and sends the property its list. At Ultra
with Print on it also turns on drivers-common-public's own dumps (`DEBUGPRINT`,
`DEBUG_TIMER`, `DEBUG_RFN`, `DEBUG_URL`, `DEBUG_WEBSOCKET`), which print whole
HTTP requests and websocket frames, logins included, and turns them off
otherwise. Nothing else sets them. The Support Code calls
`log:allowTraceAndUltra(allowed)` as the window opens and closes, which widens
and narrows the list. A page that sets Log Level offers
`log:getLogLevelNames()`.

Below Ultra, a log line of ours masks credentials through `redact.forLog`, as
`lib.http`'s request line does. At Ultra it prints them as they are, as the
dumps do. Anything that leaves the controller, a Cloud Monitoring report among
them, masks through `redact.value` at every level. The Support Code and what
`SendSecretToDevice` and `SendSecretToProxy` send stay out of the log at every
level.

### Custom Composer Tabs

`src/lib/ui/` holds everything a driver's custom Composer tab shares with the
others, so a page keeps only its own views and its driver only its own commands:

- `style.css`: the house look, from the tab bar and cards to form fields,
  tables, chips, the segmented switch and a list beside its editor, and a set of
  `.kit-*` widgets and layout helpers to use as needed, as with a CSS framework:
  states, tags, counts, a form grid, a switch, popovers and more
- `page.js`: the page's link to its driver, the live-link and demo banners, the
  tabs, the properties card and demo mode
- `variables.js` and `variables.css`: the variable browser, with
  `lib.ui.devices` on the driver's side
- `collapse.js`, `menu.js`, `combobox.js`, `color.js` and `pickgrid.js`, each
  with its stylesheet: groups that fold with Expand all, a button with a menu, a
  searchable dropdown, a color picker, and a picture grid with a drop zone
- `lib.ui.page`, `lib.ui.page-params` and `lib.ui.tab-properties`: the driver's
  side of the link and the properties card

Each file's header comment lists what it offers. A page embeds the stylesheets
in its `<style>` and the scripts in its `<script>`, the kit's first, then adds
its own:

```html
<style>
<!-- #embed ../../../../src/lib/ui/style.css -->
</style>
<div class="nav">
  <div class="nav-tab active" data-panel="status">Status</div>
</div>
<div class="panel active" id="panel-status">
  <div class="card"><h3>Status</h3><div id="status"></div></div>
  <div class="card" hidden><h3>Properties</h3><div id="props"></div></div>
</div>
<script>
<!-- #embed ../../../../src/lib/ui/page.js -->
function showStatus(status) {
  document.getElementById("status").textContent = status.text;
}
Kit.initTabs(null, { hash: true });
Kit.initPropertiesCard(document.getElementById("props"));
// Outside Composer, this stands in for the driver.
Kit.demoMode(function (command) {
  if (command === "_GET_STATUS") Kit.deliver("STATUS", { text: "Connected" });
});
Kit.connectDriver({
  handlers: { STATUS: showStatus },
  onConnect: function () { Kit.sendCommand("_GET_STATUS"); },
});
</script>
```

and its driver answers:

```lua
local page = require("lib.ui.page")
local pageParams = require("lib.ui.page-params")
require("lib.ui.tab-properties"):serve()

function UIR._GET_STATUS()
  page.send("STATUS", { text = Properties["Driver Status"] })
end

function UIR._SET_MODE(tParams)
  local params = pageParams(tParams)
  -- params.mode is what the page sent
end
```

A page restyles nothing the kit styles: `test/test_ui_pages.lua` fails one that
does, so a better look goes into the kit for every tab.

The build splices the files in, so each `.c4z` ships one self-contained page;
open the built page in `build/<distribution>/drivers/<name>/www/html/` to see
it. Opened outside Composer, the page shows the demo banner and the data its
`Kit.demoMode` answer gives, which is what the documentation's screenshots are
taken from. Opened with a controller address but no token, an OSS build logs in
through the dev proxy's saved login (`tools/dev/c4proxy.py` where a repo has
one), so a live check needs nothing typed; the DriverCentral build has no such
login.
