-- The scene cycle: which scenes it offers for the group's lights, the order it steps through them, and what it
-- activates.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_scene_cycle.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")

JSON = require("JSON")

local now = 1000000
function C4:GetTime()
  return now
end

local cycle = require("group.cycle")

local activated, ends = {}, 0
cycle.onActivate(function(step)
  activated[#activated + 1] = step.name
end)
cycle.onChange(function(_, atEnd)
  if atEnd then
    ends = ends + 1
  end
end)

local function names(list)
  local out = {}
  for _, item in ipairs(list) do
    out[#out + 1] = item.name
  end
  return out
end

-- The group is 900, with lights 1, 2 and 3.
cycle.setLights({ [900] = true, [1] = true, [2] = true, [3] = true })
cycle.setScenes({
  { id = 4, name = "Kitchen", members = { 50, 51 } },
  { id = 5, name = "Bright", members = { 900 } },
  { id = 6, name = "Bright (Toggle)", members = { 900 } },
  { id = 7, name = "Relax", members = { 1, 2 } },
  { id = 8, name = "Whole House", members = { 1, 50 } },
}, 421)

T.section("The scenes offered")
T.eq("scenes with the group or one of its lights", names(cycle.catalog()), { "Bright", "Relax", "Whole House" })
T.eq("the agent is kept", cycle.agentId(), 421)
T.eq("one with other lights says so", cycle.catalog()[3].others, true)
cycle.configure({ any = false })
T.eq("only these lights", names(cycle.catalog()), { "Bright", "Relax" })
cycle.configure({ any = true, skipToggle = false })
T.eq("toggle scenes when asked for", names(cycle.catalog())[2], "Bright (Toggle)")
cycle.configure({ skipToggle = true })

T.section("Stepping")
cycle.next()
cycle.next()
cycle.next()
T.eq("in order", activated, { "Bright", "Relax", "Whole House" })
T.eq("the end is told once", ends, 1)
cycle.next()
T.eq("then the first again", activated[4], "Bright")
cycle.previous()
T.eq("previous wraps to the last", activated[5], "Whole House")
T.eq("where it is", cycle.current().name, "Whole House")

T.section("Order and scenes left out, by hand")
cycle.setChoice({ 8, 7, 5 }, { 7 })
T.eq("the order given", names(cycle.catalog()), { "Whole House", "Relax", "Bright" })
T.eq("without the one left out", names(cycle.steps()), { "Whole House", "Bright" })
T.eq("it keeps its place", cycle.current().name, "Whole House")
activated = {}
cycle.next()
T.eq("and steps on from it", activated, { "Bright" })

T.section("An off step, and back and forth")
cycle.setChoice({ 5, 7, 8 }, {})
cycle.configure({ offStep = true })
T.eq("off is last", names(cycle.steps()), { "Bright", "Relax", "Whole House", "Off" })
cycle.configure({ offStep = false, backAndForth = true })
cycle.restart()
activated = {}
for _ = 1, 6 do
  cycle.next()
end
T.eq("up and back down", activated, { "Bright", "Relax", "Whole House", "Relax", "Bright", "Relax" })

T.section("Restart after a while")
cycle.configure({ backAndForth = false, restartAfter = 60 })
cycle.restart()
activated = {}
cycle.next()
cycle.next()
now = now + 61000
cycle.next()
T.eq("the first scene again", activated, { "Bright", "Relax", "Bright" })

T.section("Go to a scene")
cycle.goTo("Whole House")
T.eq("by name", cycle.current().id, 8)
cycle.goTo(7)
T.eq("by id", cycle.current().name, "Relax")

T.section("Following the lights")
cycle.configure({ restartAfter = 0, offStep = true })
cycle.setScenes({
  { id = 5, name = "Bright", members = { 900 }, targets = { ["900"] = { level = 100, kelvin = 4000 } } },
  { id = 7, name = "Relax", members = { 1, 2 }, targets = { ["1"] = { level = 30 }, ["2"] = { level = 30 } } },
}, 421)
cycle.setChoice({ 5, 7 }, {})
cycle.goTo("Bright")
local bright = { [900] = { level = 100, kelvin = 4020 }, [1] = { level = 100 }, [2] = { level = 100 } }
cycle.track({ [900] = { level = 40 } })
T.eq("the lights are left to reach a step", cycle.current().name, "Bright")
now = now + 6000
cycle.track(bright)
T.eq("lights at the scene keep it current", cycle.current().name, "Bright")
cycle.track({ [900] = { level = 55, kelvin = 4000 }, [1] = { level = 55 }, [2] = { level = 55 } })
T.eq("lights moved off it leave no scene current", cycle.current().position, 0)
cycle.track({ [900] = { level = 30 }, [1] = { level = 31 }, [2] = { level = 29 } })
T.eq("lights matching another scene make it current", cycle.current().name, "Relax")
cycle.track({ [900] = { level = 100, kelvin = 2700 }, [1] = { level = 100 }, [2] = { level = 100 } })
T.eq("the right level in the wrong color is no match", cycle.current().position, 0)
cycle.track({ [900] = { level = 0 }, [1] = { level = 0 }, [2] = { level = 0 } })
T.eq("every light off is the off step", cycle.current().off, true)
activated = {}
cycle.track(bright)
T.eq("following activates nothing", activated, {})
cycle.configure({ track = false })
cycle.track({ [900] = { level = 55 } })
T.eq("off, the cycle keeps its own place", cycle.current().name, "Bright")

T.section("Previous from no scene is the last")
cycle.configure({ track = true, offStep = false })
cycle.restart()
activated = {}
cycle.previous()
T.eq("not the one before it", activated, { "Relax" })

T.section("The scene it is at stays so when the scenes around it change")
cycle.setChoice({}, {})
cycle.goTo("Relax")
T.eq("second of two", cycle.current().position, 2)
cycle.setScenes({
  { id = 5, name = "Bright", members = { 900 }, targets = { ["900"] = { level = 100 } } },
  { id = 6, name = "Dinner", members = { 900 }, targets = { ["900"] = { level = 60 } } },
  { id = 7, name = "Relax", members = { 1, 2 }, targets = { ["1"] = { level = 30 }, ["2"] = { level = 30 } } },
}, 421)
T.eq("a scene added before it", cycle.current().name, "Relax")
T.eq("by its id", cycle.current().id, 7)
T.eq("now third of three", cycle.current().position, 3)
cycle.configure({ any = false })
cycle.configure({ any = true })
T.eq("and a setting changed and back leaves it", cycle.current().name, "Relax")

T.section("Lights that settle short of a scene still hold it")
cycle.goTo("Dinner")
now = now + 6000
local short = { [900] = { level = 55 }, [1] = { level = 55 }, [2] = { level = 55 } }
cycle.track(short)
T.eq("where they settle is the scene, here", cycle.current().name, "Dinner")
cycle.track(short)
T.eq("and stays it", cycle.current().name, "Dinner")
cycle.track({ [900] = { level = 20 }, [1] = { level = 20 }, [2] = { level = 20 } })
T.eq("until they are changed", cycle.current().position, 0)

T.section("A scene's white against a light that shows a color")
function C4:ColorCCTtoXY(kelvin)
  return kelvin == 3000 and 0.4369 or 0.3805, kelvin == 3000 and 0.4041 or 0.3768
end
cycle.setScenes({
  { id = 5, name = "Warm", members = { 900 }, targets = { ["900"] = { level = 50, kelvin = 3000 } } },
}, 421)
cycle.restart()
cycle.track({ [900] = { level = 50, x = 0.64, y = 0.33 } })
T.eq("red at the scene's level is no match", cycle.current().position, 0)
cycle.track({ [900] = { level = 50, x = 0.437, y = 0.404 } })
T.eq("the white's own color is", cycle.current().name, "Warm")

T.finish()
