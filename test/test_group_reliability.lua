-- Error isolation and missing state are exercised through the shipping driver's real transport adapter.
local T = require("testlib")
require("c4_shim")
local run = require("group_test").run

T.section("Missing startup levels remain unknown until feedback arrives")
run(false, function(h)
  local group = require("group.group")
  T.eq("the cache does not invent Off", group.snapshot().level, nil)
  T.eq("unreported members stay unknown", group.snapshot().lights[1].level, nil)
  T.eq("the light awaits real feedback", h.light.online, false)
  T.eq("the proxy is not told a fabricated off level", h.proxy:count("LIGHT_BRIGHTNESS_CHANGED"), 0)
  h.device.set({ on = true, level = 0.4 })
  h.clock.run(2500)
  T.eq("the real report brings the group online", h.light.online, true)
  T.eq("the actual level is shown", group.snapshot().level, 40)
end, { unknown = true })

T.section("Unknown members do not trigger All Off programming")
run(false, function(h)
  h.device.set({ on = true, level = 0.4 })
  h.clock.run(2500)
  local actual, fired = C4.FireEventByID, {}
  function C4:FireEventByID(id)
    fired[#fired + 1] = id
  end
  local group = require("group.group")
  group.setMembers({ { id = 999, name = "Waiting for feedback" } })
  T.eq("the new member has no known level", group.status().known, 0)
  T.eq("unknown feedback fires no on/off or sync transition", fired, {})
  C4.FireEventByID = actual
end)

T.section("Native member outages preserve the last level and keypad state")
run(true, function(h)
  local group = require("group.group")
  h.device.set({ on = true, level = 0.65 })
  h.clock.run(2500)
  local actual, fired = C4.FireEventByID, {}
  function C4:FireEventByID(id)
    fired[#fired + 1] = id
  end
  h.proxy:mark()
  h.device.drop()
  h.clock.run(500)
  T.eq("the proxy is offline", h.proxy.online, false)
  T.eq("the driver status is offline", Properties["Driver Status"], "Offline")
  T.eq("both members show as offline", group.snapshot().offline, 2)
  T.eq("the member's last reported level is kept", group.snapshot().lights[1].level, 65)
  T.eq("the proxy keeps its level", h.proxy.level, 65)
  T.eq("no Off notification is sent", h.proxy:count("LIGHT_BRIGHTNESS_CHANGED"), 0)
  T.eq("the On link LED stays lit", h.proxy.leds[300], true)
  h.device.back()
  h.clock.run(2500)
  T.eq("the proxy is online again", h.proxy.online, true)
  T.eq("the returning member clears the offline count", group.snapshot().offline, 0)
  T.eq("the proxy reflects the reported level", h.proxy.level, 65)
  T.eq("there is no false group programming event", fired, {})
  C4.FireEventByID = actual
end)

T.section("Native member loss is processed during a fade")
run(true, function(h)
  h.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 60000 })
  h.device.drop()
  h.clock.run(500)
  T.eq("the proxy goes offline without waiting for the fade", h.proxy.online, false)
  h.device.back()
  h.clock.run(500)
  T.eq("the old fade does not delay reconnect", h.proxy.online, true)
end)

for _, outcome in ipairs({ "read", "missing", "error" }) do
  T.section("A settled engine refresh uses fresh state (" .. outcome .. ")")
  run(false, function(h)
    local reports = {}
    local report = h.light.report
    function h.light:report(state)
      if state.kind == "final" then
        reports[#reports + 1] = state
      end
      return report(self, state)
    end
    local watched, read = OnWatchedVariableChanged, C4.GetDeviceVariable
    OnWatchedVariableChanged = function() end
    local capabilitiesReads = 0
    function C4:GetDeviceVariable(id, variable)
      if id == 801 or id == 802 then
        if variable == 6661 then
          capabilitiesReads = capabilitiesReads + 1
        elseif outcome ~= "read" and (variable == 1000 or variable == 1001) then
          if outcome == "error" then
            error("mock read failure")
          end
          return nil
        end
      end
      return read(self, id, variable)
    end
    h.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 1500 })
    h.light.adapter:refresh()
    h.clock.run(1000)
    T.eq("the refresh does not settle a running fade", #reports, 0)
    h.clock.run(5000)
    C4.GetDeviceVariable, OnWatchedVariableChanged = read, watched
    T.eq("settlement reads no capability XML", capabilitiesReads, 0)
    T.eq("the light physically reached the target", h.device.state().level, 0.8)
    if outcome == "read" then
      T.check("the settled level came from the read", #reports > 0 and reports[1].level == 0.8)
    else
      T.eq("a failed level read sends no cached final report", #reports, 0)
    end
    T.eq("the proxy shows the command target", h.proxy.level, 80)
  end)
end

T.section("Out-of-range native Kelvin does not discard valid brightness")
run(true, function(h)
  local group = require("group.group")
  group.setMembers({ { id = 801, name = "Native light" } })
  ExecuteCommand("LIGHT_GROUP_STATE", {
    MEMBER_ID = "801",
    ONLINE = "true",
    ON = "true",
    LEVEL = "78",
    X = "0.31",
    Y = "0.33",
    MODE = "cct",
    KELVIN = "100001",
  })
  h.clock.run(2500)
  T.eq("the new brightness reaches the proxy", h.proxy.level, 78)
end)

for _, native in ipairs({ false, true }) do
  T.section((native and "Native" or "Proxy") .. " failure is isolated to its member")
  run(native, function(h)
    local actual = C4.SendToDevice
    local failed = native and 1801 or 801
    function C4:SendToDevice(id, command, params, ...)
      if tonumber(id) == failed and command == (native and "LIGHT_GROUP_COMMAND" or "RAMP_TO_LEVEL") then
        error("simulated member send failure")
      end
      return actual(self, id, command, params, ...)
    end
    local group = require("group.group")
    group.configure({ commandDelay = 100 })
    h.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 750 })
    h.clock.run(3000)
    T.eq("the other member still receives its target", group.snapshot().lights[2].level, 80)
    local entries = table.concat(group.controlLog(), "\n")
    T.check(
      "the failure is visible with its command identity",
      entries:find("#%d+.-failed.-simulated member send failure") ~= nil
    )
    T.check("millisecond timing is recorded", entries:find("t=%d+ms") ~= nil)
    T.check("feedback is recorded separately from sends", entries:find("FEEDBACK_LEVEL") ~= nil)
    T.falsy("the failed light is not hidden as in sync", group.status().inSync)
    C4.SendToDevice = actual
  end)
end

T.section("Unloading cancels queued commands and ignores late native feedback")
run(true, function(h)
  local group = require("group.group")
  group.configure({ commandDelay = 100 })
  h.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 4000 })
  local count = #h.commands
  local old = h.light
  OnDriverDestroyed()
  h.clock.run(10000)
  T.eq("no queued wire operation survives the unload", #h.commands, count)
  T.eq("the old engine discards late reports", #old.waiting, 0)
  T.eq("the old engine is stopped", old.started, nil)
end)
T.finish()
