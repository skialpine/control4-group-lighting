-- Startup brightness must reach the native proxy, including a cached/off zero.
-- Proxy publication failures must recover without issuing another bulb command.
local T = require("testlib")
require("c4_shim")
local fixture = require("c4_local")
require("lib.utils")
require("drivers-common-public.global.handlers")
JSON = require("JSON")

local now = 1000000
function C4:GetTime()
  return now
end
function C4:GetProxyDevices()
  return 900
end
function C4:GetDeviceVariable(id, variable)
  return C4:GetVariable(id, variable)
end

local calls, commands, failures, delays = {}, {}, {}, {}
local setTimer = C4.SetTimer
function C4:SetTimer(delay, ...)
  delays[#delays + 1] = delay
  return setTimer(self, delay, ...)
end
function C4:SendToDevice(id, command, params)
  commands[#commands + 1] = { id = id, command = command, params = params }
end
function C4:SendToProxy(binding, command, params)
  if (failures[command] or 0) > 0 then
    failures[command] = failures[command] - 1
    error("temporary proxy failure: " .. command)
  end
  calls[#calls + 1] = { binding = binding, command = command, params = params }
end

local function count(command)
  local n = 0
  for _, call in ipairs(calls) do
    if call.command == command then
      n = n + 1
    end
  end
  return n
end

local function lastLevel()
  for i = #calls, 1, -1 do
    if calls[i].command == "LIGHT_BRIGHTNESS_CHANGED" then
      return calls[i].params.LIGHT_BRIGHTNESS_CURRENT
    end
  end
  return nil
end

local function fresh(cached, memberVariables, extraMember)
  CancelTimer("GroupProxyRetry")
  CancelTimer("GroupFeedback")
  fixture.freshLuaState({ "^group%." })
  ShimSetDevices({
    [900] = {
      variables = {
        ["1001"] = { name = "Brightness Percent", type = "2", value = cached },
        ["1110"] = { value = cached },
      },
    },
    [102] = extraMember,
    [101] = {
      variables = memberVariables
        or {
          ["1000"] = { value = "0" },
          ["1001"] = { value = "0" },
          ["6661"] = {
            value = "<DynamicCapabilities><dimmer>True</dimmer><supports_target>True</supports_target></DynamicCapabilities>",
          },
        },
    },
  })
  calls, commands, failures, delays = {}, {}, {}, {}
  local light = require("group.light")
  light.lateInit()
  return light
end

local function report(light, level)
  light.state({ supported_color_modes = { light.ColorMode.COLOR_MODE_BRIGHTNESS } }, {
    state = level > 0,
    brightness = level / 100,
  })
end

T.section("First actual brightness is published even when the cache matches")
for _, level in ipairs({ 0, 40, 100 }) do
  local light = fresh(tostring(level))
  report(light, level)
  T.eq("initial notification at " .. level, count("LIGHT_BRIGHTNESS_CHANGED"), 1)
  T.eq("numeric level at " .. level, lastLevel(), level)
  T.eq("numeric payload at " .. level, type(lastLevel()), "number")
  report(light, level)
  T.eq("unchanged later report stays quiet", count("LIGHT_BRIGHTNESS_CHANGED"), 1)
  T.eq("publication moves no bulb", #commands, 0)
end

T.section("An undefined cache is replaced by an observed off level")
local light = fresh("Undefined")
report(light, 0)
T.eq("off is zero", lastLevel(), 0)

T.section("Before a real report no brightness is invented")
light = fresh("Undefined")
RFP.GET_LIGHT_LEVEL(5001, "GET_LIGHT_LEVEL", {})
T.eq("unknown stays unknown", count("LIGHT_BRIGHTNESS_CHANGED"), 0)

T.section("An interrupted setup retries on an identical report")
light = fresh("0")
failures.DYNAMIC_CAPABILITIES_CHANGED = 1
T.raises("first capability send fails", function()
  report(light, 0)
end, "temporary proxy failure")
report(light, 0)
T.eq("capabilities are retried", count("DYNAMIC_CAPABILITIES_CHANGED"), 1)
T.eq("the actual off level follows", lastLevel(), 0)

T.section("A failed first brightness send retries without a level change")
light = fresh("0")
failures.LIGHT_BRIGHTNESS_CHANGED = 1
T.raises("first brightness send fails", function()
  report(light, 0)
end, "temporary proxy failure")
report(light, 0)
T.eq("the brightness retry reaches the proxy", lastLevel(), 0)
T.eq("capabilities are not resent after success", count("DYNAMIC_CAPABILITIES_CHANGED"), 1)

T.section("The group recovers automatically with unchanged members")
for _, command in ipairs({ "DYNAMIC_CAPABILITIES_CHANGED", "LIGHT_BRIGHTNESS_CHANGED" }) do
  light = fresh("0")
  local group = require("group.group")
  light.attach(group.adapter())
  failures[command] = 1
  group.setMembers({ { id = 101, name = "Off bulb" } })
  T.eq("failed first report is not a bulb command", #commands, 0)
  now = now + 2000
  ShimFireTimers()
  T.eq("group retries " .. command, lastLevel(), 0)
  T.eq("retry sends no bulb command", #commands, 0)
  local sent = count("LIGHT_BRIGHTNESS_CHANGED")
  now = now + 2000
  ShimFireTimers()
  T.eq("retry stops after success", count("LIGHT_BRIGHTNESS_CHANGED"), sent)
end

T.section("Reconnect publishes the first reading again, then suppresses duplicates")
light = fresh("40")
report(light, 40)
light.reset(true)
report(light, 40)
report(light, 40)
T.eq("one report per connection", count("LIGHT_BRIGHTNESS_CHANGED"), 2)
T.eq("reconnect does not move a bulb", #commands, 0)

T.section("Persistent proxy failures wait between attempts")
light = fresh("0")
local waiting = require("group.group")
light.attach(waiting.adapter())
failures.DYNAMIC_CAPABILITIES_CHANGED = 5
waiting.setMembers({ { id = 101, name = "Off bulb" } })
T.eq("one initial attempt", failures.DYNAMIC_CAPABILITIES_CHANGED, 4)
T.eq("retry is delayed by one second", delays[#delays], 1000)
now = now + 1000
ShimFireTimers()
T.eq("one retry after the delay", failures.DYNAMIC_CAPABILITIES_CHANGED, 3)
waiting.setMembers({})

T.section("Unknown group startup waits for an actual zero")
for _, value in ipairs({ "missing", "", "Undefined", "not-a-number", "nan" }) do
  local vars = {
    ["6661"] = { value = "<DynamicCapabilities><dimmer>True</dimmer></DynamicCapabilities>" },
  }
  if value ~= "missing" then
    vars["1001"], vars["1000"] = { value = value }, { value = value }
  end
  light = fresh("0", vars)
  local unknown = require("group.group")
  light.attach(unknown.adapter())
  unknown.setMembers({ { id = 101, name = "Unreported bulb" } })
  now = now + 2000
  ShimFireTimers()
  T.eq("no synthetic zero for " .. value, count("LIGHT_BRIGHTNESS_CHANGED"), 0)
  T.eq("unknown stays offline for " .. value, light.isOnline(), false)
  vars["1001"] = { value = "0" }
  OnWatchedVariableChanged(101, 1001, "0")
  now = now + 2000
  ShimFireTimers()
  T.eq("first actual zero is reported for " .. value, lastLevel(), 0)
  T.eq("reading unknown/zero moves no bulb", #commands, 0)
end

T.section("A dimmer on state without a brightness is still unknown")
light = fresh("0", {
  ["1000"] = { value = "1" },
  ["6661"] = { value = "<DynamicCapabilities><dimmer>True</dimmer></DynamicCapabilities>" },
})
local unmeasured = require("group.group")
light.attach(unmeasured.adapter())
unmeasured.setMembers({ { id = 101, name = "On but unreported dimmer" } })
T.eq("no invented 100 percent", count("LIGHT_BRIGHTNESS_CHANGED"), 0)
T.eq("no bulb commands", #commands, 0)

T.section("A proxy retry cannot run Keep Lights In Sync")
light = fresh("0", nil, {
  variables = {
    ["1000"] = { value = "0" },
    ["1001"] = { value = "0" },
    ["6661"] = {
      value = "<DynamicCapabilities><dimmer>True</dimmer><supports_target>True</supports_target></DynamicCapabilities>",
    },
  },
})
local syncing = require("group.group")
light.attach(syncing.adapter())
syncing.configure({ keepSync = true })
failures.DYNAMIC_CAPABILITIES_CHANGED = 1
syncing.setMembers({ { id = 101, name = "Left" }, { id = 102, name = "Right" } })
OnWatchedVariableChanged(101, 1001, "50")
ExpireTimer("GroupProxyRetry")
T.eq("retry only publishes status", #commands, 0)
T.eq("last group snapshot reaches the proxy", lastLevel(), 0)
ExpireTimer("GroupFeedback")
T.check("normal member feedback still runs sync", #commands > 0)
syncing.setMembers({})

T.section("Removing members cancels a pending publication")
light = fresh("0")
local group = require("group.group")
light.attach(group.adapter())
failures.DYNAMIC_CAPABILITIES_CHANGED = 1
group.setMembers({ { id = 101, name = "Off bulb" } })
group.setMembers({})
now = now + 2000
ShimFireTimers()
T.eq("removed group stays offline", light.isOnline(), false)
T.eq("no retry after removing lights", count("DYNAMIC_CAPABILITIES_CHANGED"), 0)
T.eq("removing lights sends no bulb command", #commands, 0)
T.finish()
