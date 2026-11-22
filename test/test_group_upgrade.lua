-- In-place updates across independent driver Lua states on the same simulated Director.
local T = require("testlib")
require("c4_shim")
local Project = require("group_project_rig")
local p = Project.new()
local ok, err = xpcall(function()
  p:member(801, false)
  p:member(802, false)
  p:member(803, true)
  p:member(804, true)
  p:member(805, true)
  p:member(806, false)
  local a = p:load(7101, { 801, 802 })
  local b = p:load(7102, { 803, 804 })
  local c = p:load(7103, { 805, 806 })
  p.clock.run(3000)
  T.section("Three isolated driver instances retain separate member lists and settings")
  for _, entry in ipairs({ { a, 25, 1111 }, { b, 50, 2222 }, { c, 75, 3333 } }) do
    entry[1].proxy:send("SET_CLICK_RATE_UP", { RATE = entry[3] })
    entry[1].proxy:send("SET_LEVEL", { LEVEL = entry[2] })
  end
  p.clock.run(3000)
  T.eq("generic group reached its own level", p.members[801].level, 25)
  T.eq("native group reached its own level", p.members[803].level, 50)
  T.eq("mixed group reached its own level", p.members[805].level, 75)
  T.section("Updating all three preserves storage, selection and the running project")
  local before = #p.commands
  a = p:load(7101)
  b = p:load(7102)
  c = p:load(7103)
  p.clock.run(5000)
  T.eq("group A's rate survived its fresh Lua state", a.light.settings:clickRate(true), 1111)
  T.eq("group B's rate survived its fresh Lua state", b.light.settings:clickRate(true), 2222)
  T.eq("group C's rate survived its fresh Lua state", c.light.settings:clickRate(true), 3333)
  T.eq("group A's selection survived", a.env.Properties["Lights"], "801,802")
  T.eq("group B's selection survived", b.env.Properties["Lights"], "803,804")
  T.eq("group C's selection survived", c.env.Properties["Lights"], "805,806")
  local motion = 0
  for i = before + 1, #p.commands do
    if p.commands[i].command ~= "LIGHT_GROUP_JOIN" then
      motion = motion + 1
    end
  end
  T.eq("reload sends no commands other than joins", motion, 0)
  T.eq("the first group is online", a.light.online, true)
  T.eq("the second group is online", b.light.online, true)
  T.eq("the third group is online", c.light.online, true)
  a.proxy:send("SET_LEVEL", { LEVEL = 90 })
  p.clock.run(3000)
  T.eq("the updated generic group still works", p.members[802].level, 90)
  T.eq("the native group was not disturbed", p.members[804].level, 50)
  T.eq("the mixed group was not disturbed", p.members[806].level, 75)
  T.section("A native loss in a mixed group keeps the standard member available")
  local mixed = c.env.require("group.group")
  local cycle = c.env.require("group.cycle")
  cycle.setScenes({
    {
      id = 1,
      name = "Mixed Scene",
      members = { 805, 806 },
      targets = { ["805"] = { level = 75 }, ["806"] = { level = 0 } },
    },
  }, 1)
  mixed.configure({ keepSync = true })
  local beforeLoss = #p.commands
  p:setOnline(805, false)
  p.clock.run(2500)
  T.eq("the mixed group stays online", c.light.online, true)
  T.eq("only the native member is shown offline", c.env.Properties["Driver Status"], "1 of 2 lights offline")
  T.eq("the group's level does not change on loss", c.proxy.level, 75)
  T.eq("losing a member sends no movement to the other one", #p.commands, beforeLoss)
  T.eq("the standard member retains its level", p.members[806].level, 75)
  T.eq("the programming variable keeps its confirmed value", c.env.Variables.LIGHTS_IN_SYNC, "1")
  c.proxy:send("OFF")
  p.clock.run(5000)
  T.eq("the offline member did not receive the command", p.members[805].level, 75)
  T.eq("the standard member turned off", p.members[806].level, 0)
  T.eq("the displayed level follows the reachable member", c.proxy.level, 0)
  T.eq("the cached offline reading does not establish a scene match", cycle.current().id, nil)
  p:setOnline(805, true)
  p.clock.run(3500)
  T.eq("scene tracking resumes with complete feedback", cycle.current().id, 1)
  T.eq("the programming variable reports the now-confirmed mismatch", c.env.Variables.LIGHTS_IN_SYNC, "0")

  T.section("Editing a mixed group's Lights preserves retained members and drops late reports")
  local edited = p:load(7105, { 803, 806 })
  p.clock.run(3000)
  local beforeEdit = #p.commands
  edited.env.Properties.Lights = "806"
  edited.env.OnPropertyChanged("Lights")
  p.clock.run(3000)
  local leave = p.commands[beforeEdit + 1]
  T.eq("only the removed member's protocol driver is notified", {
    #p.commands - beforeEdit,
    leave and leave.id,
    leave and leave.command,
    leave and leave.params.GROUP_ID,
  }, { 1, 1803, "LIGHT_GROUP_LEAVE", "7105" })
  T.eq("the removed member keeps its other membership", p.members[803].joined[7102], "803")
  T.eq("the removed member drops the edited group", p.members[803].joined[7105], nil)
  edited.env.ExecuteCommand("LIGHT_GROUP_STATE", { MEMBER_ID = "803", ONLINE = "true", ON = "true", LEVEL = "99" })
  p.clock.run(3000)
  T.eq("an in-flight report from the removed member cannot change the group level", edited.proxy.level, 0)

  local beforeCommand = #p.commands
  edited.proxy:send("SET_LEVEL", { LEVEL = 27 })
  p.clock.run(3000)
  T.eq("the retained standard Light V2 member still follows the group", p.members[806].level, 27)
  T.eq("the removed member stays at its previous level", p.members[803].level, 50)
  T.eq("the standard command targets the retained proxy", p.commands[beforeCommand + 1].id, 806)

  local beforeRejoin = #p.commands
  edited.env.Properties.Lights = "806,803"
  edited.env.OnPropertyChanged("Lights")
  p.clock.run(3000)
  local join = p.commands[beforeRejoin + 1]
  T.eq("only the re-added member joins, with distinct proxy and protocol IDs", {
    #p.commands - beforeRejoin,
    join and join.id,
    join and join.command,
    join and join.params.MEMBER_ID,
  }, { 1, 1803, "LIGHT_GROUP_JOIN", "803" })
  T.eq("the re-added member registers with the edited group", p.members[803].joined[7105], "803")
  local rejoined = edited.env.require("group.group").snapshot().lights[2]
  T.eq("the synchronous join reply supplies the re-added member's level", rejoined.level, 50)
  local beforeMixed = #p.commands
  edited.proxy:send("SET_LEVEL", { LEVEL = 40 })
  p.clock.run(3000)
  local movement = {}
  for i = beforeMixed + 1, #p.commands do
    local command = p.commands[i]
    if command.from == 7105 then
      movement[#movement + 1] = { command.id, command.command }
    end
  end
  T.eq("the re-added member uses native transport alongside the standard proxy", movement, {
    { 806, "RAMP_TO_LEVEL" },
    { 1803, "LIGHT_GROUP_COMMAND" },
  })

  T.section("Deleting a group clears its own native registration and cancels pending commands")
  p:load(7104, { 805, 803 })
  p.clock.run(3000)
  mixed.configure({ commandDelay = 400 })
  c.proxy:send("SET_LEVEL", { LEVEL = 60 })
  local beforeRemoval = #p.commands
  c.env.OnDriverRemovedFromProject()
  c.env.OnDriverDestroyed()
  c.env.OnDriverRemovedFromProject()
  mixed.setMembers({ { id = 805, name = "Late member selection" } })
  p.clock.run(3000)
  T.eq("the deleted group is gone from its native member", p.members[805].joined[7103], nil)
  T.eq("the overlapping group remains joined", p.members[805].joined[7104], "805")
  T.eq("the deleted group's member list is empty", mixed.size(), 0)
  local sent = {}
  for i = beforeRemoval + 1, #p.commands do
    local command = p.commands[i]
    if command.from == 7103 then
      sent[#sent + 1] = { command.id, command.command, command.params.GROUP_ID }
    end
  end
  T.eq("each protocol driver receives one leave and no queued light command follows", sent, {
    { 1805, "LIGHT_GROUP_LEAVE", "7103" },
    { 1806, "LIGHT_GROUP_LEAVE", "7103" },
  })

  T.section("A deletion callback can still clear registrations after driver teardown")
  b.env.OnDriverDestroyed()
  T.eq("ordinary teardown preserves the registration", p.members[803].joined[7102], "803")
  b.env.OnDriverRemovedFromProject()
  T.eq("the first member leaves the deleted group", p.members[803].joined[7102], nil)
  T.eq("the second member leaves the deleted group", p.members[804].joined[7102], nil)
  T.eq("the first member stays in its other group", p.members[803].joined[7104], "803")

  T.eq("no callback raised", p.clock.errors, {})
  a.env.SetTimer("FixtureErrorProbe", 1, function()
    error("fixture timer sentinel")
  end)
  p.clock.run(10)
  T.check(
    "private timer failures reach the test recorder",
    #p.clock.errors == 1 and p.clock.errors[1]:find("7101:.*fixture timer sentinel") ~= nil
  )
end, debug.traceback)
p:done()
T.check("the shared project simulation completed", ok, not ok and err or nil)
T.finish()
