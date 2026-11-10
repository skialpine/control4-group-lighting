# Light V2 startup brightness findings

## Confirmed in Light Group

On the first device report, Light Group compared the actual brightness with
Control4's cached Brightness Percent (1001) and brightness target (1110). When
they matched, it skipped LIGHT_BRIGHTNESS_CHANGED. This also skipped the report
when both values were zero.

The Light V2 contract calls for LIGHT_BRIGHTNESS_CHANGED when the driver starts
or the hardware comes online and its actual brightness is known. The fix sends
that first numeric report, including zero. Later identical reports remain
suppressed. An unknown device is not given a made-up brightness. Missing or
invalid member state stays unknown until a valid level or off state is received;
an on/off switch can also establish its on level from a valid on state.

A second issue affected recovery from a failed proxy message. The driver marked
the entity as seen before publishing all capabilities. After a failure, an
identical device report did not retry capability setup. The group also caught
publication errors without retrying if its members stayed at the same level. The
fix retries incomplete setup and retries group state publication after one
second. A successful publication or removing all members cancels the retry.
These retries send status to the proxy, not lighting commands to member bulbs.

The regression suite covers cached levels 0, 40 and 100, undefined startup
state, reconnects, capability and brightness send failures, unchanged group
feedback, delayed retries, and cancellation when members are removed.

## Home Assistant investigation

The controller's Lua diagnostic showed Brightness Percent declared as type 2
(integer) for a working Office bulb, an affected Front Porch bulb, and the Front
Porch group. Their values were respectively 100, 0 and 0. Lua variable reads
normally return strings; those quoted values do not establish a schema error.
The raw REST values seen by Home Assistant have not been captured.

The startup fixes are verified in simulated-controller tests. Whether they
resolve Home Assistant's reported string error still needs a live check. They
cannot change an individual Zigbee bulb's proxy or Control4's REST serializer.

## For the Zigbee driver author

Please check whether your Light V2 driver skips its first brightness report when
the bulb's observed value matches the proxy's cached value, particularly zero.
Light Group had that optimization; it omitted the startup notification required
by the Light V2 contract. We removed it and still suppress duplicate reports
after the initial send. Please also check that an interrupted capability
publication is retried even if the bulb's next state is unchanged.

We have not inspected the encrypted Zigbee Lua code and cannot confirm it has
either issue. The affected bulb's native variable is currently declared as an
integer with value 0. We have not established the cause of its Home Assistant
REST value error.

A simple reproduction for the startup omission is to give a fresh driver a proxy
cache of 0 and an observed bulb level of 0. Capture its proxy messages: once the
actual level is known, expect one LIGHT_BRIGHTNESS_CHANGED with
LIGHT_BRIGHTNESS_CURRENT = 0, followed by no duplicate sends for unchanged
reports. Repeat with a nonzero level. For recovery, inject one failed capability
send and check that setup and brightness recover without moving the bulb or
requiring another state change.

Sending the initial brightness notification can run Control4 brightness-event
programming at startup. Test existing programming when validating this change.

References:
[Light V2 brightness notifications](https://snap-one.github.io/docs-driverworks-proxyprotocol/#light_brightness_changed),
[Light V2 variables](https://snap-one.github.io/docs-driverworks-proxyprotocol/#light-v2-variables),
and
[Lua variable reads](https://snap-one.github.io/docs-driverworks-api/#getdevicevariable).
