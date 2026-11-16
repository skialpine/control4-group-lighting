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
