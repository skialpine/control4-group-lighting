<!-- Copyright 2026 the control4-group-lighting contributors. Licensed under the GNU AGPL v3. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

# <span style="color:#109EFF">Light Group</span>

______________________________________________________________________

# <span style="color:#109EFF">Overview</span>

Light Group makes several lights behave as one. Pick any lights in the project,
from any manufacturer, and the group shows in Navigator as a single light with
brightness, color and color temperature, as far as its lights allow. A command
to the group goes to every light in it, and what the lights show comes back as
the group's level and color.

Use it where several lights always move together, such as a run of LED strips
that must share a color, or downlights on separate dimmers that light one room,
without building Advanced Lighting Scenes for every level.

The driver is open source under the GNU AGPL v3. It is not affiliated with or
endorsed by Control4, Snap One, or the maker of any other light group driver.

# <span style="color:#109EFF">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Driver Setup](#driver-setup)
  - [Settings Tab](#settings-tab)
  - [Driver Properties](#driver-properties)
  - [Driver Actions](#driver-actions)
  - [Connections](#connections)
- [Scene Cycle](#scene-cycle)
- [Programming](#programming)
- [How The Group Reads Its Lights](#how-the-group-reads-its-lights)
- [Known Limitations](#known-limitations)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#109EFF">System Requirements</span>

- Control4 OS 3.3.2 or later
- Lights that use the Light V2 proxy. The original Light (v1) proxy is not
  supported.

# <span style="color:#109EFF">Features</span>

- Groups any Light V2 lights into one light: dimmers, switches, tunable white
  and full color, mixed freely
- Offers color and color temperature when any light in the group has them, and
  sends each light only what it can do
- Sends a color temperature to color-only lights as the matching color
- Maps a color temperature onto each light's own range, by the closest value or
  by scaling
- Can keep its lights in sync, so changing one changes them all
- Reads the lights back by their average, the brightest, the dimmest or one
  chosen light, or not at all
- The Light V2 proxy's own settings: Brightness On Mode and presets, click and
  hold rates, Color On Mode including Dim-To-Warm, and status LED colors
- Advanced Lighting Scenes, including ramping and flashing scenes
- A scene cycle: step through the scenes that use the group's lights from one
  keypad button
- On, Toggle and Off button links for keypads, with LED feedback
- Works with the Daylight Agent through the group's color temperature
- Can limit a group to less than its lights can do, such as on/off only
- Optional delay between commands for lighting systems that drop commands sent
  together
- A log of the last 50 commands sent, for troubleshooting

# <span style="color:#109EFF">Installer Setup</span>

## Driver Installation

1. Download the latest `light_group.c4z` from the project's
   [releases](https://github.com/skialpine/control4-group-lighting/releases).
1. In Composer Pro, choose **Driver > Add or Update Driver or Agent** and select
   the file.
1. In **System Design**, search the **Items** pane for "Light Group" and add it
   to a room. Add one for each group.

## Driver Setup

1. Select the Light Group in **System Design**.
1. In **Advanced Properties**, open the **Settings** tab, then **Lights**, check
   the lights the group controls and click **Save**.
1. The group's **Driver Status** reads `Online` and **Group Summary** counts its
   lights. Run the **Display Lights** action to see what each light can do.
1. Set the group's on modes, presets, rates and LED colors in the
   **Brightness**, **Rates** and **Color** tabs above, as for any light.
1. Refresh Navigators.

> [!NOTE]
> The **Color** tab and the color controls in Navigator appear once the group
> holds a light with color or color temperature.

> [!TIP]
> Hide the grouped lights from Navigator if the room should show only the group.

## Settings Tab

The **Settings** tab in the driver's Advanced Properties is the quickest way to
set a group up. It has four views:

- **Group**: what the group shows, and each light's level, color and whether it
  is in step with the group. Its actions send the lights the group's state
  again, try the light commands, and show the control log.
- **Lights**: every light in the project by room, with a checkbox for each.
  Check the lights, then **Save**. Also where the tracked light is chosen.
- **Scenes**: the scene cycle. Lists the Advanced Lighting Scenes that use the
  group's lights, with a checkbox to keep each in the cycle, buttons to order
  them, and Next, Previous and Restart.
- **Settings**: the driver's properties, the same as on the **Properties** tab.
  A change made on either shows on both.

## Driver Properties

### Cloud Settings

<!-- #ifdef DRIVERCENTRAL -->

#### Cloud Status (read-only)

Displays the DriverCentral cloud license status.

<!-- #endif -->

#### Automatic Updates \[ Off | **_On_** \]

Turns automatic driver updates on or off. Changing it on one Light Group changes
it on all of them.

<!-- #ifndef DRIVERCENTRAL -->

#### Update Channel \[ **_Production_** | Prerelease \]

Which releases an update takes. Prerelease includes builds still in testing.

<!-- #endif -->

### Driver Settings

#### Driver Status (read-only)

`Online` once the group has lights, or `No lights selected`.

#### Driver Version (read-only)

The driver's version.

#### Log Level \[ 0 - Fatal | 1 - Error | 2 - Warning | **_3 - Info_** | 4 - Debug | 5 - Trace | 6 - Ultra \]

How much the driver logs.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Where the log goes. Any mode but Off returns to Off after three hours.

### Group Settings

#### Lights

The lights the group controls. A group cannot contain itself.

#### Group Summary (read-only)

How many of the group's lights are on, and whether they match each other.

#### Light Type \[ **_Automatic_** | On/Off | Dimmer | Color Temperature | Full Color \]

What the group offers in Navigator. `Automatic` offers whatever any of its
lights can do. Another choice sets it outright: `On/Off` makes a group of
dimmers a plain switch, and `Full Color` shows the color controls for lights
whose drivers do not report their abilities.

#### Off Command \[ **_Brightness 0_** | Off \]

How dimmable lights are turned off. `Brightness 0` fades them off at the ramp
rate. `Off` sends each light its Off command, for lights that handle a
brightness of 0 badly; it ignores the ramp rate.

#### Command Delay (ms) \[ 0 - 2000, default **_0_** \]

The time between the commands to each light. Leave it at 0 unless a lighting
system misses commands that arrive together.

### Feedback Settings

#### Keep Lights In Sync \[ **_Off_** | On \]

With `On`, a light in the group that is changed by itself, such as from its own
slider or keypad, takes the rest with it: the other lights are sent its level
and color, and the group shows them. With `Off`, the lights can be set apart,
and the group shows what the tracking settings below give.

#### Brightness Tracking \[ **_Average_** | Brightest | Dimmest | Selected Light | Ignore \]

What the group shows when its lights differ.

- `Average`: the average of the lights that are on. The group is off when every
  light is off.
- `Brightest`: the brightest light.
- `Dimmest`: the dimmest light, counting a light that is off. The group is on
  only while every light is on.
- `Selected Light`: the light chosen in **Tracked Light**.
- `Ignore`: the group shows what it was last set to, whatever the lights do.

#### Color Tracking \[ **_Average_** | Selected Light | Ignore \]

The same for color. `Average` is a color temperature while every light that is
on shows a white, and a color otherwise.

#### Tracked Light

The light **Selected Light** follows.

#### Feedback Delay (ms) \[ 0 - 30000, default **_1500_** \]

How long the lights are given to settle after the group's own command and its
ramp before they are read. Raise it if the group's level jumps after a command.

### Color Temperature Settings

#### Color Temperature Range \[ **_Automatic_** | Manual \]

`Automatic` spans every light in the group that has color temperature. `Manual`
shows the two properties below.

#### Minimum Color Temperature (K), Maximum Color Temperature (K)

The group's range when **Color Temperature Range** is `Manual`.

#### Color Temperature Mapping \[ **_Closest_** | Scaled \]

What a light is sent when the group's color temperature is outside the light's
own range. `Closest` sends the nearest it has. `Scaled` sends the same position
on the light's range, so every light moves across its whole range together.

#### Emulate Color Temperature \[ Off | **_On_** \]

Sends a color light that has no color temperature the color of the white asked
for. This also gives such lights color temperature in Navigator and with the
Daylight Agent.

### Scene Cycle Settings

The scene cycle steps through the Advanced Lighting Scenes that use the group's
lights, one scene for each press of a keypad button bound to the **Scene Cycle
Button Link**. See [Scene Cycle](#scene-cycle).

#### Scenes In Cycle \[ **_Any Of These Lights_** | Only These Lights \]

Which scenes the cycle offers: every scene that has the group or one of its
lights in it, or only scenes with no lights outside the group.

#### Skip Toggle Scenes \[ No | **_Yes_** \]

Leaves out the "(Toggle)" scenes Composer makes alongside a scene.

#### Track Current Scene \[ Off | **_Match Light Levels_** \]

With `Match Light Levels`, the cycle follows the lights. A scene is the current
one while the group's lights are where it leaves them, however they got there,
and no scene is current once they are changed. The next step then starts from
the scene the lights match, or from the first. With `Off`, the cycle keeps its
own place whatever the lights do.

#### Cycle Off Step \[ **_Off_** | On \]

Adds a last step that turns the group off.

#### Cycle Mode \[ **_Wrap Around_** | Back And Forth \]

After the last scene, the first again, or back down through the scenes.

#### Cycle Restart After (s) \[ 0 - 86400, default **_0_** \]

After this long without a step, the next step is the first scene. 0 never
restarts.

#### Cycle Hold Action \[ **_None_** | Previous Scene | Off | Restart Cycle \]

What holding the cycle's button does.

## Driver Actions

<!-- #ifndef DRIVERCENTRAL -->

#### Update Drivers

Checks for a newer release and installs it.

<!-- #endif -->

#### Display Lights

Prints each light in the group to the Lua tab: what it can do and what it shows.

#### Display Control Log

Prints the last 50 commands the group sent to its lights.

#### Sync Lights

Sends every light the group's level and color again.

#### Test Light Commands

Tries each way of setting a color temperature on the group's first light, a few
seconds apart, and prints what the light showed after each. The light turns on
and off while it runs. Use it when a light does not follow the group, and
include the output in a support request.

## Connections

#### On Button Link, Toggle Button Link, Off Button Link

Connect keypad buttons to turn the group on, off or toggle it. A hold ramps the
group, and the button's LED follows the group.

#### Scene Cycle Button Link

Connect a keypad button to step through the scene cycle. A click is the next
scene. The button's LED is lit while the cycle is on a scene.

# <span style="color:#109EFF">Scene Cycle</span>

1. Put the group, or its lights, in the Advanced Lighting Scenes you want.
1. Open the driver's **Settings** tab and its **Scenes** view. The tab reads the
   scenes from the controller, and lists the ones that use the group's lights.
1. Uncheck any scene to leave it out, and order the rest with **Up** and
   **Down**.
1. Connect a keypad button to the **Scene Cycle Button Link**, or use the
   programming commands below.

Each step activates the whole scene, as if it were chosen in Navigator, so a
scene that also has lights outside the group changes those too. Such scenes are
marked in the list; set **Scenes In Cycle** to `Only These Lights` to leave them
out.

> [!IMPORTANT]
> A driver cannot ask the controller for its scenes; the **Settings** tab can.
> After adding, renaming or changing the lights of a scene in Composer, open the
> **Scenes** view, or click **Read scenes again** there, for the cycle to take
> it up.

Control4 does not tell a driver which scene is active, so the cycle compares the
group's lights with where each scene leaves them, a couple of seconds after they
stop changing. **Track Current Scene** turns this off.

# <span style="color:#109EFF">Programming</span>

The group has every command, event, conditional and variable of a Control4
light, plus:

## Events

- **All Lights On**: every light in the group is on
- **All Lights Off**: every light in the group is off
- **Lights Out Of Sync**: the lights stop matching each other
- **Lights In Sync**: the lights match each other again
- **Scene Cycle Changed**: the scene cycle moved to another scene
- **Scene Cycle Reached End**: the scene cycle reached its last scene

## Variables

- **LIGHTS_ON**: how many of the group's lights are on
- **LIGHTS_TOTAL**: how many lights the group has
- **LIGHTS_IN_SYNC**: whether the lights match each other
- **CURRENT_CYCLE_SCENE**: the name of the scene the cycle is on
- **CURRENT_CYCLE_SCENE_ID**: its scene id, or -1
- **CURRENT_CYCLE_POSITION**: its place in the cycle, from 1, or 0 before the
  first step

## Commands

- **Sync Lights**: sends every light the group's level and color again
- **Next Scene**, **Previous Scene**: step the scene cycle
- **Go To Scene**: activate one of the cycle's scenes
- **Restart Scene Cycle**: make the next step the first scene

# <span style="color:#109EFF">How The Group Reads Its Lights</span>

After the group sends a command it shows that command's result at once. When the
ramp and the **Feedback Delay** have passed, it reads the lights. If they ended
where they were sent, nothing changes. If a light was changed some other way,
such as at its own keypad or in a scene, the group's level and color move to
what the tracking settings give.

A switch has no level of its own, so one that is on counts as being at the
group's level.

A color set while the group is off is not sent to the lights, since some would
turn on for it. The lights get it when the group next turns on.

# <span style="color:#109EFF">Known Limitations</span>

- The driver has been tested against a simulated controller only. Please report
  what you see on real systems.
- A light's abilities are read from what its driver reports to its Light V2
  proxy. For a light that reports nothing, the group assumes a dimmer; set
  **Light Type** to offer more.
- A group stops a ramp by sending each light the level reached, so lights may
  land slightly apart after a held button is released.
- Not yet included: custom Extras and Extras merged from the lights.

# <span style="color:#109EFF">Support</span>

Report problems and ask for features on
[GitHub](https://github.com/skialpine/control4-group-lighting/issues). Include
the driver version and the output of the **Display Lights** and **Display
Control Log** actions.

<!-- #embed-changelog -->
