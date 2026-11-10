-- The group as one light: a command to the group reaches every light in the form that light
-- takes, and the lights' own levels and colors come back as the group's.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_light_group.lua

local T = require("testlib")
require("c4_shim")
require("c4_local")
require("lib.utils")
require("drivers-common-public.global.handlers")

JSON = require("JSON")

-- A clock the test moves, so "the lights have settled" is a step and not a wait.
local now = 1000000
function C4:GetTime()
  return now
end

local toDevices, toProxy = {}, {}
function C4:SendToDevice(id, command, params)
  toDevices[#toDevices + 1] = { id = id, command = command, params = params or {} }
end
function C4:SendToProxy(binding, command, params)
  toProxy[#toProxy + 1] = { binding = binding, command = command, params = params }
end
-- The shim reads another device's variable as C4:GetVariable.
function C4:GetDeviceVariable(id, variable)
  return C4:GetVariable(id, variable)
end
function C4:GetProxyDevices()
  return 900
end

local function caps(fields)
  local xml = { "<DynamicCapabilities>" }
  for key, value in pairs(fields) do
    xml[#xml + 1] = string.format("<%s>%s</%s>", key, tostring(value), key)
  end
  xml[#xml + 1] = "</DynamicCapabilities>"
  return table.concat(xml)
end

local DIMMER = caps({ dimmer = "True", supports_target = "True" })
local SWITCH = caps({ dimmer = "False", supports_target = "False" })
local LEGACY = caps({ dimmer = "True", supports_target = "False" })
local TUNABLE = caps({
  dimmer = "True",
  supports_target = "True",
  supports_color_correlated_temperature = "True",
  color_correlated_temperature_min = 2700,
  color_correlated_temperature_max = 5000,
})
local COLOR = caps({ dimmer = "True", supports_target = "True", supports_color = "True" })

local devices = {}
local function device(id, name, capabilities, level)
  devices[id] = {
    deviceName = name,
    variables = {
      ["1000"] = { name = "LIGHT_STATE", value = level > 0 and "1" or "0" },
      ["1001"] = { name = "LIGHT_LEVEL", value = tostring(level) },
      ["6661"] = { name = "DYNAMIC_CAPABILITIES", value = capabilities },
    },
  }
end

--- A light reports: its variable changes and the driver hears of it.
local function report(id, variable, value)
  devices[id].variables[tostring(variable)] = { value = tostring(value) }
  OnWatchedVariableChanged(id, variable, tostring(value))
end

--- Lets the lights settle and the driver read them.
local function settle()
  for _ = 1, 4 do
    now = now + 60000
    ShimFireTimers()
  end
end

local function sentTo(id, command)
  local found = {}
  for _, sent in ipairs(toDevices) do
    if sent.id == id and (not command or sent.command == command) then
      found[#found + 1] = sent
    end
  end
  return found
end

local function lastToProxy(command)
  for i = #toProxy, 1, -1 do
    if toProxy[i].command == command then
      return toProxy[i].params
    end
  end
end

local function clear()
  toDevices, toProxy = {}, {}
end

local light = require("group.light")
local group = require("group.group")
light.attach(group.adapter())

local status
group.onChange(function(s)
  status = s
end)

T.section("A group with no lights is offline")
ShimSetDevices(devices)
light.lateInit()
group.setMembers({})
T.eq("the proxy is told offline", lastToProxy("ONLINE_CHANGED").STATE, false)
T.eq("no lights", status.total, 0)

T.section("Dimmers, a switch and a pre-3.3 dimmer")
device(101, "Left", DIMMER, 0)
device(102, "Right", DIMMER, 0)
device(103, "Fan Light", SWITCH, 0)
device(104, "Old Dimmer", LEGACY, 0)
ShimSetDevices(devices)
clear()
group.setMembers({
  { id = 101, name = "Left" },
  { id = 102, name = "Right" },
  { id = 103, name = "Fan Light" },
  { id = 104, name = "Old Dimmer" },
})
settle()
T.eq("the proxy is told online", lastToProxy("ONLINE_CHANGED").STATE, true)
T.eq("the group dims", lastToProxy("DYNAMIC_CAPABILITIES_CHANGED").dimmer, true)
T.eq("it has no color", lastToProxy("DYNAMIC_CAPABILITIES_CHANGED").supports_color, false)
T.eq("four lights", status.total, 4)
T.eq("nothing was sent to the lights", #toDevices, 0)

T.section("A level goes to each light in its own form")
clear()
RFP.SET_BRIGHTNESS_TARGET(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 2000 })
T.eq("a dimmer gets the target", sentTo(101, "RAMP_TO_LEVEL")[1].params.LEVEL, 60)
T.eq("with the rate", sentTo(102, "RAMP_TO_LEVEL")[1].params.TIME, 2000)
T.eq("a switch is turned on", #sentTo(103, "ON"), 1)
T.eq("an old dimmer gets a level", sentTo(104, "RAMP_TO_LEVEL")[1].params.LEVEL, 60)
T.eq("and a time", sentTo(104, "RAMP_TO_LEVEL")[1].params.TIME, 2000)
report(101, 1001, 60)
report(102, 1001, 60)
report(103, 1001, 100)
report(104, 1001, 60)
settle()
T.eq("the group ends at the level", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 60)
T.eq("all on", status.on, 4)
T.eq("a switch that is on is in step", status.inSync, true)

T.section("One light turned off elsewhere leaves the group on")
clear()
report(101, 1001, 0)
settle()
T.eq("the proxy hears nothing", lastToProxy("LIGHT_BRIGHTNESS_CHANGED"), nil)
T.eq("three on", status.on, 3)
T.eq("out of step", status.inSync, false)
T.eq("the lights are sent nothing", #toDevices, 0)

T.section("Every light off turns the group off")
report(102, 1001, 0)
report(103, 1001, 0)
report(104, 1001, 0)
settle()
T.eq("the group is off", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 0)
T.eq("none on", status.on, 0)

T.section("A light dimmed elsewhere moves the group's average")
report(101, 1001, 40)
report(102, 1001, 80)
settle()
T.eq("the average of the lights on", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 60)

T.section("Brightest and Dimmest")
group.configure({ brightnessTracking = "Brightest" })
group.refresh()
T.eq("brightest", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 80)
group.configure({ brightnessTracking = "Dimmest" })
group.refresh()
T.eq("dimmest counts the lights off", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 0)
group.configure({ brightnessTracking = "Selected Light", trackedId = 101 })
group.refresh()
T.eq("selected", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 40)
group.configure({ brightnessTracking = "Average" })

T.section("Off as a command")
group.configure({ offCommand = "Off" })
clear()
RFP.SET_BRIGHTNESS_TARGET(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 })
T.eq("a dimmer is sent OFF", #sentTo(101, "OFF"), 1)
T.eq("and no level", #sentTo(101, "RAMP_TO_LEVEL"), 0)
group.configure({ offCommand = "Brightness 0" })
for id = 101, 104 do
  report(id, 1001, 0)
end
settle()

T.section("A tunable white light and a color light")
device(201, "Strip", TUNABLE, 0)
device(202, "Bulb", COLOR, 0)
ShimSetDevices(devices)
clear()
group.setMembers({ { id = 201, name = "Strip" }, { id = 202, name = "Bulb" } })
settle()
local told = lastToProxy("DYNAMIC_CAPABILITIES_CHANGED")
T.eq("the group has color", told.supports_color, true)
T.eq("and color temperature", told.supports_color_correlated_temperature, true)
T.eq("from the strip's range", told.color_correlated_temperature_min, 2700)
T.eq("to its top", told.color_correlated_temperature_max, 5000)

T.section("A color temperature set while off waits for the on")
clear()
local x, y = C4:ColorCCTtoXY(6000)
RFP.SET_COLOR_TARGET(5001, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = x,
  LIGHT_COLOR_TARGET_Y = y,
  LIGHT_COLOR_TARGET_MODE = 1,
  LIGHT_COLOR_TARGET_RATE = 0,
})
T.eq("the lights are sent nothing", #toDevices, 0)
RFP.SET_BRIGHTNESS_TARGET(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 50, RATE = 0 })
local strip = sentTo(201, "SET_COLOR_TARGET")[1]
T.truthy("the strip gets a white", strip)
T.eq("as a color temperature", strip.params.LIGHT_COLOR_TARGET_MODE, 1)
local kelvin = strip.params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE
T.check("the closest the strip has", math.abs(kelvin - 5000) < 60, kelvin)
local bulb = sentTo(202, "SET_COLOR_TARGET")[1]
T.truthy("the bulb gets the white as a color", bulb)
T.eq("in full color", bulb.params.LIGHT_COLOR_TARGET_MODE, 0)
T.eq("both get the level", #sentTo(201, "RAMP_TO_LEVEL") + #sentTo(202, "RAMP_TO_LEVEL"), 2)
local order = {}
for _, sent in ipairs(sentTo(201)) do
  order[#order + 1] = sent.command
end
T.eq("color before level", order[1], "SET_COLOR_TARGET")

T.section("A full color skips the light without it")
report(201, 1001, 50)
report(202, 1001, 50)
settle()
clear()
RFP.SET_COLOR_TARGET(5001, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = 0.64,
  LIGHT_COLOR_TARGET_Y = 0.33,
  LIGHT_COLOR_TARGET_MODE = 0,
  LIGHT_COLOR_TARGET_RATE = 500,
})
T.eq("the strip is sent nothing", #sentTo(201), 0)
local red = sentTo(202, "SET_COLOR_TARGET")[1]
T.truthy("the bulb gets it", red)
T.check(
  "as the red asked for",
  math.abs(red.params.LIGHT_COLOR_TARGET_X - 0.64) < 0.01,
  red.params.LIGHT_COLOR_TARGET_X
)
T.eq("at the rate", red.params.RATE, 500)

T.section("A white after a color stays a white")
settle()
local wx, wy = C4:ColorCCTtoXY(4000)
RFP.SET_COLOR_TARGET(5001, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = wx,
  LIGHT_COLOR_TARGET_Y = wy,
  LIGHT_COLOR_TARGET_MODE = 1,
  LIGHT_COLOR_TARGET_RATE = 0,
})
settle()
T.eq("the group shows a color temperature", lastToProxy("LIGHT_COLOR_CHANGED").LIGHT_COLOR_CURRENT_COLOR_MODE, 1)

T.section("Light Type limits the group")
group.configure({ lightType = "On/Off" })
group.refresh()
told = lastToProxy("DYNAMIC_CAPABILITIES_CHANGED")
T.eq("no dimming", told.dimmer, false)
T.eq("no color", told.supports_color, false)
clear()
RFP.OFF(5001, "OFF", {})
T.eq("off reaches a light", #sentTo(201) > 0, true)
group.configure({ lightType = "Automatic" })

T.section("Commands spaced apart")
group.refresh()
for id = 201, 202 do
  report(id, 1001, 0)
end
settle()
group.configure({ commandDelay = 100 })
clear()
RFP.SET_BRIGHTNESS_TARGET(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 30, RATE = 0 })
T.eq("one command at once", #toDevices, 1)
settle()
T.eq("the rest follow", #sentTo(201, "RAMP_TO_LEVEL") + #sentTo(202, "RAMP_TO_LEVEL"), 2)
T.truthy("the control log keeps them", #group.controlLog() > 0)

T.section("A tunable white group shows Presets and Temperature, and takes a color preset")
group.configure({ commandDelay = 0 })
device(301, "Cans", TUNABLE, 50)
ShimSetDevices(devices)
group.setMembers({ { id = 301, name = "Cans" } })
settle()
told = lastToProxy("DYNAMIC_CAPABILITIES_CHANGED")
T.eq("color temperature, for the Temperature tab", told.supports_color_correlated_temperature, true)
T.eq("no full color, so no Color tab", told.supports_color, false)
clear()
local px, py = C4:ColorCCTtoXY(3000)
RFP.SET_COLOR_TARGET(5001, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = px,
  LIGHT_COLOR_TARGET_Y = py,
  LIGHT_COLOR_TARGET_MODE = 1,
  LIGHT_COLOR_TARGET_RATE = 0,
  LIGHT_COLOR_TARGET_PRESET_ID = 4,
  LIGHT_COLOR_TARGET_PRESET_ORIGIN = 2,
})
local preset = sentTo(301, "SET_COLOR_TARGET")[1]
T.truthy("the light gets the preset's white", preset)
local presetKelvin = preset.params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE
T.check("at 3000 K, within the conversion's error", math.abs(presetKelvin - 3000) < 60, presetKelvin)
settle()
local changed = lastToProxy("LIGHT_COLOR_CHANGED")
T.eq("the proxy is told the preset is active", tonumber(changed.LIGHT_COLOR_CURRENT_PRESET_ID), 4)

T.section("Kept in sync, one light changed by itself takes the others with it")
device(401, "A", DIMMER, 50)
device(402, "B", DIMMER, 50)
device(403, "C", DIMMER, 50)
ShimSetDevices(devices)
group.setMembers({ { id = 401, name = "A" }, { id = 402, name = "B" }, { id = 403, name = "C" } })
settle()
group.configure({ keepSync = true })
clear()
report(401, 1001, 23)
-- Past the debounce, and the other lights answer while the group waits for them to settle.
now = now + 300
ShimFireTimers()
report(402, 1001, 23)
report(403, 1001, 23)
settle()
T.eq("the light that changed is sent nothing", #sentTo(401), 0)
T.eq("another follows it", sentTo(402, "RAMP_TO_LEVEL")[1].params.LEVEL, 23)
T.eq("and the third", sentTo(403, "RAMP_TO_LEVEL")[1].params.LEVEL, 23)
T.eq("the group shows it", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 23)
T.eq("the lights following is no new change", #sentTo(402) + #sentTo(403), 2)
clear()
report(403, 1001, 0)
now = now + 300
ShimFireTimers()
report(401, 1001, 0)
report(402, 1001, 0)
settle()
T.eq("one turned off turns the rest off", sentTo(401, "RAMP_TO_LEVEL")[1].params.LEVEL, 0)
T.eq("the group is off", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 0)
group.configure({ keepSync = false })

local function noneToProxy(command, level)
  for _, sent in ipairs(toProxy) do
    if sent.command == command and tonumber(sent.params.LIGHT_BRIGHTNESS_CURRENT) == level then
      return false
    end
  end
  return true
end

T.section("On reaches the lights that are off in a group that reads as on")
device(501, "P", DIMMER, 100)
device(502, "Q", DIMMER, 0)
ShimSetDevices(devices)
group.setMembers({ { id = 501, name = "P" }, { id = 502, name = "Q" } })
settle()
T.eq(
  "the group reads as on, at the level of the light that is",
  tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT),
  100
)
clear()
RFP.SET_BRIGHTNESS_TARGET(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 0 })
T.eq(
  "the level it already shows still goes to the light that is off",
  sentTo(502, "RAMP_TO_LEVEL")[1].params.LEVEL,
  100
)
report(502, 1001, 0)
settle()
group.configure({ lightType = "On/Off" })
group.refresh()
clear()
RFP.ON(5001, "ON", {})
T.eq("and so does a plain on", #sentTo(502, "ON"), 1)
group.configure({ lightType = "Automatic" })
group.refresh()
report(502, 1001, 100)
settle()

T.section("A stop mid-ramp finds the lights an even share of the way")
T.eq("the ramp is taken as even", group.adapter().curve(0.2), 0.2)

T.section("Kept in sync, lights set apart together are left apart")
device(601, "A", DIMMER, 50)
device(602, "B", DIMMER, 50)
device(603, "C", DIMMER, 50)
ShimSetDevices(devices)
group.setMembers({ { id = 601, name = "A" }, { id = 602, name = "B" }, { id = 603, name = "C" } })
settle()
group.configure({ keepSync = true })
clear()
report(601, 1001, 30)
report(602, 1001, 80)
settle()
T.eq("a scene's levels are not flattened", #toDevices, 0)
T.eq("the group shows their average", tonumber(lastToProxy("LIGHT_BRIGHTNESS_CHANGED").LIGHT_BRIGHTNESS_CURRENT), 53)

T.section("Kept in sync, a light still moving is followed to where it stops")
clear()
report(603, 1001, 70)
now = now + 300
ShimFireTimers()
T.eq("followed at once", sentTo(601, "RAMP_TO_LEVEL")[1].params.LEVEL, 70)
clear()
report(603, 1001, 90)
report(601, 1001, 70)
report(602, 1001, 70)
settle()
T.eq("and again where it ended", sentTo(601, "RAMP_TO_LEVEL")[1].params.LEVEL, 90)
T.eq("without being sent anything itself", #sentTo(603), 0)
report(601, 1001, 90)
report(602, 1001, 90)
settle()

T.section("Held, the lights are not followed")
clear()
group.hold(5000)
report(601, 1001, 20)
now = now + 300
ShimFireTimers()
T.eq("a light set by a scene the driver activated", #toDevices, 0)
settle()
group.configure({ keepSync = false })

T.section("A color leaves a light that is off by itself off")
device(701, "Lamp", TUNABLE, 50)
device(702, "Lamp 2", TUNABLE, 0)
ShimSetDevices(devices)
group.setMembers({ { id = 701, name = "Lamp" }, { id = 702, name = "Lamp 2" } })
settle()
clear()
RFP.SET_COLOR_TARGET(5001, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3000,
  LIGHT_COLOR_TARGET_MODE = 1,
  LIGHT_COLOR_TARGET_RATE = 0,
})
T.eq("the light that is on gets it", #sentTo(701, "SET_COLOR_TARGET"), 1)
T.eq("the light that is off does not", #sentTo(702), 0)

T.section("A quick command during a long ramp does not end the wait for it")
report(702, 1001, 50)
settle()
clear()
RFP.SET_BRIGHTNESS_TARGET(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 30000 })
RFP.SET_COLOR_TARGET(5001, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 4000,
  LIGHT_COLOR_TARGET_MODE = 1,
  LIGHT_COLOR_TARGET_RATE = 0,
})
report(701, 1001, 62)
report(702, 1001, 62)
now = now + 3000
ShimFireTimers()
T.check("a level on the way is not the group's", noneToProxy("LIGHT_BRIGHTNESS_CHANGED", 62))
report(701, 1001, 100)
report(702, 1001, 100)
settle()

T.section("A white scaled onto each light's range reads back as the group's")
local WIDE = caps({
  dimmer = "True",
  supports_color_correlated_temperature = "True",
  color_correlated_temperature_min = 2000,
  color_correlated_temperature_max = 6500,
})
device(801, "Narrow", TUNABLE, 50)
device(802, "Wide", WIDE, 50)
ShimSetDevices(devices)
group.setMembers({ { id = 801, name = "Narrow" }, { id = 802, name = "Wide" } })
group.configure({ scaled = true })
settle()
clear()
RFP.SET_COLOR_TARGET(5001, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 4250,
  LIGHT_COLOR_TARGET_MODE = 1,
  LIGHT_COLOR_TARGET_RATE = 0,
})
local narrow = sentTo(801, "SET_COLOR_TARGET")[1].params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE
local wide = sentTo(802, "SET_COLOR_TARGET")[1].params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE
T.check("the lights are sent different whites", math.abs(narrow - wide) > 200, narrow .. " and " .. wide)
settle()
local told = #toProxy
local nx, ny = C4:ColorCCTtoXY(narrow)
local wx2, wy2 = C4:ColorCCTtoXY(wide)
report(801, 1200, nx .. "," .. ny .. ",1")
report(802, 1200, wx2 .. "," .. wy2 .. ",1")
settle()
local moved = false
for i = told + 1, #toProxy do
  moved = moved or toProxy[i].command == "LIGHT_COLOR_CHANGED"
end
T.falsy("the group's white does not move", moved)
T.eq("and the lights are in step", status.inSync, true)
group.configure({ scaled = false })

T.section("Ignore keeps the group's level through a change of setting")
device(901, "Solo", DIMMER, 80)
ShimSetDevices(devices)
group.setMembers({ { id = 901, name = "Solo" } })
settle()
group.configure({ brightnessTracking = "Ignore" })
clear()
report(901, 1001, 20)
settle()
group.configure({ lightType = "Dimmer" })
group.refresh()
T.check("the lights are not read again", noneToProxy("LIGHT_BRIGHTNESS_CHANGED", 20))
group.configure({ brightnessTracking = "Average", lightType = "Automatic" })

T.finish()
