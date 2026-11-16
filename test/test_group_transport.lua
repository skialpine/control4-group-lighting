-- Timed wire checks around the driver's real adapter, with physical fades supplied only by the rig.
local T = require("testlib")
require("c4_shim")

local run = require("group_test").run

for _, native in ipairs({ false, true }) do
  T.section((native and "Confirmed template" or "Generic Light V2") .. " members ramp without a plateau")
  run(native, function(h)
    h.proxy:send(
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3200, LIGHT_COLOR_TARGET_MODE = 1, RATE = 0 }
    )
    h.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 750 })
    local previous = 0
    for i = 1, 10 do
      h.clock.run(75)
      local level = h.device.state().level
      T.check("the physical level advances at sample " .. i, level > previous, tostring(level))
      previous = level
      if i == 4 then
        -- A late duplicate after the old model's 250 ms deduplication window must not restart the fade.
        h.proxy:send(
          "SET_COLOR_TARGET",
          { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 3200, LIGHT_COLOR_TARGET_MODE = 1, RATE = 750 }
        )
      end
    end
    T.check("the requested 750 ms ramp reaches full", math.abs(previous - 1) < 0.001)
    local counts = {}
    for _, cmd in ipairs(h.commands) do
      counts[cmd.command] = (counts[cmd.command] or 0) + 1
    end
    T.eq("one brightness operation per member", counts[native and "LIGHT_GROUP_COMMAND" or "RAMP_TO_LEVEL"], 2)
    T.eq("no separate color command interrupts the fade", counts.SET_COLOR_TARGET or 0, 0)
    if not native then
      T.eq("an unconfirmed member never receives the custom group command", counts.LIGHT_GROUP_COMMAND or 0, 0)
    end
  end)
end

T.section("Native feedback keeps its absolute brightness scale")
run(true, function(h)
  local group = require("group.group")
  h.device.set({ on = true, level = 0.4 })
  h.clock.run(2500)
  T.eq("native members report physical 40 percent", group.snapshot().level, 40)
  -- A member with its own Min/Max On can report 33 on its proxy while its device is physically at 40 percent.
  OnWatchedVariableChanged(801, 1001, "33")
  OnWatchedVariableChanged(802, 1001, "33")
  h.clock.run(500)
  T.eq("late proxy-scale reports do not overwrite native brightness", group.snapshot().level, 40)
  group.setMembers({ { id = 801, name = "Member 801" }, { id = 802, name = "Member 802" } })
  T.eq("reselecting the lights retains native brightness", group.snapshot().level, 40)
  group.configure({ commandDelay = 100 })
  h.commands = {}
  h.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 750 })
  h.clock.run(3000)
  T.check("spaced native commands reach physical 80 percent", math.abs(h.device.state().level - 0.8) < 0.001)
  local combined, generic = 0, 0
  for _, cmd in ipairs(h.commands) do
    if cmd.command == "LIGHT_GROUP_COMMAND" then
      combined = combined + 1
    end
    if cmd.command == "RAMP_TO_LEVEL" then
      generic = generic + 1
    end
  end
  T.eq("spacing keeps the native command for each member", combined, 2)
  T.eq("spacing does not reapply the member's logical scale", generic, 0)
end)

T.section("The Settings tab follows a color held while the group is off")
run(false, function(h)
  h.proxy:send(
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 4500, LIGHT_COLOR_TARGET_MODE = 1, RATE = 0 }
  )
  h.clock.run(500)
  local shown = require("group.group").snapshot()
  T.eq("the group stays off", shown.level, 0)
  T.check("its displayed held white follows Navigator", math.abs(shown.kelvin - 4500) < 70)
  T.check("the off members retain their actual white", math.abs(h.device.state().color.kelvin - 3200) < 70)
end)
T.finish()
