-- Light Group.
--
-- One Light V2 light that stands for several: the lights picked in the Lights property, from any
-- manufacturer. The light model (src/group/light.lua) runs the light_v2 proxy on binding 5001 (on
-- modes, presets, rates, ramps, Advanced Lighting Scenes and the three button links) and
-- src/group/group.lua is its device: it sends each light its commands and reads their levels and
-- colors back into one state.

--#ifndef DRIVERCENTRAL
DRIVER_GITHUB_REPO = "skialpine/control4-group-lighting"
--#endif

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

JSON = require("JSON")

local log = require("lib.logging")
local values = require("lib.values")
local updateSettings = require("lib.update-settings")
--#ifdef DRIVERCENTRAL
local drivercentral = require("lib.drivercentral")
local supportCode = require("lib.support-code")
--#endif
--#ifndef DRIVERCENTRAL
local driverFilenames = require("lib.driver-filenames")
local githubUpdater = require("lib.github-updater")
--#endif

local pageParams = require("lib.ui.page-params")
local tabProperties = require("lib.ui.tab-properties")
local constants = require("constants")
local light = require("group.light")
local group = require("group.group")
local cycle = require("group.cycle")

local EVENT = {
  ALL_ON = 1,
  ALL_OFF = 2,
  OUT_OF_SYNC = 3,
  IN_SYNC = 4,
  CYCLE_CHANGED = 5,
  CYCLE_END = 6,
}

local PROXY_BINDING = 5001
local CYCLE_BINDING = 303
local ADVANCED_LIGHTING_C4I = "control4_agent_adv_lighting.c4i"

light.attach(group.adapter())

--- What the lights last showed, for the events to fire on a change only.
local gShown = {}

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------

--- @param status { total: integer, on: integer, inSync: boolean }
local function showStatus(status)
  if status.total == 0 then
    UpdateProperty("Driver Status", "No lights selected")
    UpdateProperty("Group Summary", "")
  else
    UpdateProperty("Driver Status", "Online")
    UpdateProperty(
      "Group Summary",
      string.format("%d of %d on%s", status.on, status.total, status.inSync and "" or ", out of sync")
    )
  end
  values:update("LIGHTS_ON", status.on, "NUMBER")
  values:update("LIGHTS_TOTAL", status.total, "NUMBER")
  values:update("LIGHTS_IN_SYNC", status.inSync, "BOOL")

  local allOn = status.total > 0 and status.on == status.total
  local allOff = status.total > 0 and status.on == 0
  -- Nothing fires for the first reading after a start: it is no change.
  if gShown.total ~= nil then
    if allOn and not gShown.allOn then
      C4:FireEventByID(EVENT.ALL_ON)
    end
    if allOff and not gShown.allOff then
      C4:FireEventByID(EVENT.ALL_OFF)
    end
    if status.inSync ~= gShown.inSync and status.total > 0 then
      C4:FireEventByID(status.inSync and EVENT.IN_SYNC or EVENT.OUT_OF_SYNC)
    end
  end
  gShown = { total = status.total, allOn = allOn, allOff = allOff, inSync = status.inSync }
end

---------------------------------------------------------------------------
-- The Settings tab
---------------------------------------------------------------------------

--- Every light in the project the group could hold, for the tab's picker.
--- @param own table<integer, true> The group's own ids.
--- @return { id: integer, name: string, room: string }[]
local function projectLights(own)
  local lights = {}
  local ok, devices = pcall(function()
    return C4:GetDevices({ C4iNames = "light_v2.c4i" })
  end)
  for id, device in pairs(ok and type(devices) == "table" and devices or {}) do
    id = tointeger(id)
    if id and not own[id] and type(device) == "table" then
      lights[#lights + 1] = { id = id, name = device.deviceName or tostring(id), room = device.roomName or "" }
    end
  end
  table.sort(lights, function(a, b)
    if a.room ~= b.room then
      return a.room < b.room
    end
    return a.name < b.name
  end)
  return lights
end

local ownIds

--- Sends the tab the group, its lights and the lights it could hold.
local function pushGroup()
  local snapshot = group.snapshot()
  snapshot.name = GetDeviceDisplayNameOrId(C4:GetProxyDevices() or C4:GetDeviceID())
  snapshot.status = Properties["Driver Status"]
  snapshot.available = projectLights(ownIds())
  snapshot.log = group.controlLog()
  snapshot.cycle = {
    scenes = cycle.catalog(),
    current = cycle.current(),
    known = cycle.known(),
    read = cycle.readAt(),
  }
  C4:SendDataToUI("GROUP_DATA", { payload = JSON:encode(snapshot) })
end

function UIR._GET_CONFIG()
  C4:SendDataToUI("CONFIG_DATA", { properties = JSON:encode(tabProperties:list()) })
  pushGroup()
end

function UIR._SET_PROPERTY(tParams)
  local params = pageParams(tParams)
  local err = tabProperties:set(params.property, params.value)
  if err then
    C4:SendDataToUI("PROPERTY_ERROR", { payload = JSON:encode({ property = params.property, error = err }) })
  end
end

--- The tab's picker: the lights checked.
function UIR.SET_LIGHTS(tParams)
  local ids = {}
  for _, id in ipairs(pageParams(tParams).ids or {}) do
    if tointeger(id) then
      ids[#ids + 1] = tostring(tointeger(id))
    end
  end
  UpdateProperty("Lights", table.concat(ids, ","), true)
end

function UIR.SET_TRACKED_LIGHT(tParams)
  local id = tointeger(pageParams(tParams).id)
  UpdateProperty("Tracked Light", id and tostring(id) or "", true)
end

--- The scenes the tab read from the controller, each with the lights in it.
function UIR.SET_SCENES(tParams)
  local params = pageParams(tParams)
  cycle.setScenes(params.scenes, params.agentId)
end

--- The cycle's order and the scenes left out of it.
function UIR.SET_CYCLE(tParams)
  local params = pageParams(tParams)
  cycle.setChoice(params.order, params.excluded)
end

function UIR.RUN_ACTION(tParams)
  local params = pageParams(tParams)
  local action = params.action
  if action == "next" then
    cycle.next()
  elseif action == "previous" then
    cycle.previous()
  elseif action == "restart" then
    cycle.restart()
  elseif action == "scene" then
    cycle.goTo(params.scene)
  elseif action == "sync" then
    group.sync()
  elseif action == "test" then
    group.probe(function(line)
      C4:SendDataToUI("TEST_LINE", { line = line })
    end)
  end
end

---------------------------------------------------------------------------
-- The scene cycle
---------------------------------------------------------------------------

--- @return integer|nil agentId The Advanced Lighting agent.
local function advancedLighting()
  local ok, found = pcall(function()
    return C4:GetDevicesByC4iName(ADVANCED_LIGHTING_C4I)
  end)
  for id in pairs(ok and type(found) == "table" and found or {}) do
    return tointeger(id)
  end
  return cycle.agentId()
end

cycle.onActivate(function(step)
  -- A scene sets each light where it wants it: none of them is one light changed by itself, to be followed.
  group.hold(5000)
  if step.off then
    RFP.OFF(PROXY_BINDING, "OFF", {})
    return
  end
  local agent = advancedLighting()
  if not agent then
    log:error("The Advanced Lighting agent was not found; scene %s was not activated", step.name)
    return
  end
  SendToDevice(agent, "ACTIVATE_SCENE", { SCENE_ID = step.id })
end)

cycle.onChange(function(current, atEnd)
  local changed = values:update("CURRENT_CYCLE_SCENE", current.name, "STRING")
  values:update("CURRENT_CYCLE_SCENE_ID", current.id or -1, "NUMBER")
  values:update("CURRENT_CYCLE_POSITION", current.position, "NUMBER")
  -- The button's LED is lit while the cycle is on a scene.
  SendToProxy(CYCLE_BINDING, "MATCH_LED_STATE", { STATE = current.position > 0 and not current.off }, "NOTIFY")
  if gInitialized and changed then
    C4:FireEventByID(EVENT.CYCLE_CHANGED)
  end
  if gInitialized and atEnd then
    C4:FireEventByID(EVENT.CYCLE_END)
  end
  SetTimer("TabPush", 300, pushGroup)
end)

--- What holding the cycle's button does.
local gCycleHold = "None"
local gCycleHeld = false

local function cycleHold()
  gCycleHeld = true
  if gCycleHold == "Previous Scene" then
    cycle.previous()
  elseif gCycleHold == "Off" then
    RFP.OFF(PROXY_BINDING, "OFF", {})
    cycle.restart()
  elseif gCycleHold == "Restart Cycle" then
    cycle.restart()
  end
end

--- The Scene Cycle Button Link: a click is the next scene, and a hold what Cycle Hold Action says.
RFP[CYCLE_BINDING] = function(_, strCommand)
  if strCommand == "DO_PUSH" then
    gCycleHeld = false
    SetTimer("CycleHold", 800, cycleHold)
  elseif strCommand == "DO_CLICK" then
    CancelTimer("CycleHold")
    if not gCycleHeld then
      cycle.next()
    end
  elseif strCommand == "DO_RELEASE" then
    CancelTimer("CycleHold")
  elseif strCommand == "REQUEST_BUTTON_COLORS" then
    local current = cycle.current()
    SendToProxy(CYCLE_BINDING, "MATCH_LED_STATE", { STATE = current.position > 0 and not current.off }, "NOTIFY")
  end
end

--- What the group and each of its lights show, for the cycle to compare with its scenes.
local function trackScene()
  local snapshot = group.snapshot()
  local shown = {}
  for _, member in ipairs(snapshot.lights) do
    shown[member.id] = { level = member.level, kelvin = member.kelvin, x = member.x, y = member.y }
  end
  if snapshot.total > 0 then
    for id in pairs(ownIds()) do
      shown[id] = { level = snapshot.level, kelvin = snapshot.kelvin, x = snapshot.x, y = snapshot.y }
    end
  end
  cycle.track(shown)
end

group.onChange(function(status)
  showStatus(status)
  -- Once the lights have stopped changing.
  SetTimer("CycleTrack", 2000, trackScene)
  -- Together, when several lights report at once.
  SetTimer("TabPush", 300, pushGroup)
end)

---------------------------------------------------------------------------
-- The group's lights
---------------------------------------------------------------------------

--- @return table<integer, true> own The group's own ids: its driver and its proxy.
ownIds = function()
  -- C4:GetProxyDevices gives the proxy's id, or several as separate values.
  local own = { [C4:GetDeviceID()] = true }
  local ok, err = pcall(function()
    for _, id in ipairs({ C4:GetProxyDevices() }) do
      own[tointeger(id) or 0] = true
    end
  end)
  if not ok then
    log:warn("The group's own proxy could not be read: %s", err)
  end
  return own
end

--- Reads the Lights property into the group. A light cannot be in its own group.
local function readLights()
  local own = ownIds()
  local devices = {}
  for idText in string.gmatch(Properties["Lights"] or "", "([^,]+)") do
    local id = tointeger(idText)
    if id and not own[id] then
      devices[#devices + 1] = { id = id, name = GetDeviceDisplayNameOrId(id) }
    elseif id then
      log:warn("The group cannot be one of its own lights; %s is left out", idText)
    end
  end
  log:info("The group has %d light(s)", #devices)
  local mine = ownIds()
  for _, device in ipairs(devices) do
    mine[device.id] = true
  end
  cycle.setLights(mine)
  -- A failure here would otherwise leave the group silently empty.
  local set, problem = xpcall(function()
    group.setMembers(devices)
  end, debug.traceback)
  if not set then
    log:error("The group's lights could not be set: %s", problem)
    UpdateProperty("Driver Status", "Error: " .. tostring(problem):match("^[^\n]*"))
  end
end

---------------------------------------------------------------------------
-- Updates
---------------------------------------------------------------------------

--#ifndef DRIVERCENTRAL
--- Update the driver from the GitHub repository.
--- @param forceUpdate? boolean Force the update even if already up to date.
function UpdateDrivers(forceUpdate)
  log:trace("UpdateDrivers(%s)", forceUpdate)
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, driverFilenames, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      if updatedDrivers and #updatedDrivers > 0 then
        log:info("Updated driver(s): %s", table.concat(updatedDrivers, ","))
      end
    end, function(err)
      log:warn("Driver update failed: %s", err)
    end)
end

--- The lowest-numbered Light Group checks for every one of them.
local function isUpdateLeader()
  local lowest
  for id in pairs(C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}) do
    id = tointeger(id)
    lowest = math.min(lowest or id, id)
  end
  return lowest == C4:GetDeviceID()
end
--#endif

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function OnDriverInit()
  --#ifdef DRIVERCENTRAL
  drivercentral:startClient()
  --#else
  C4:AllowExecute(true)
  --#endif
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- The router runs each handler in its own xpcall and reports its error, so the rest still run.
  for p, _ in pairs(Properties) do
    OnPropertyChanged(p)
  end

  --#ifndef DRIVERCENTRAL
  SetTimer("UpdateCheck", 30 * ONE_MINUTE, function()
    if isUpdateLeader() and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)
  --#endif

  gInitialized = true
  light.lateInit()
  readLights()
  -- A change made in Composer's Properties tab reaches the open Settings tab.
  tabProperties:follow(UIR._GET_CONFIG)
  --#ifdef DRIVERCENTRAL
  drivercentral:startGate(function(licensed)
    if not licensed then
      UpdateProperty("Driver Status", drivercentral.UNLICENSED_STATUS)
    end
  end)
  --#endif
end

---------------------------------------------------------------------------
-- Properties
---------------------------------------------------------------------------

function OPC.Driver_Status(propertyValue)
  log:trace("OPC.Driver_Status('%s')", propertyValue)
  if not gInitialized then
    UpdateProperty("Driver Status", "Initializing", false)
  end
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if gInitialized then
    updateSettings:share("Automatic Updates", propertyValue)
  end
end

--#ifndef DRIVERCENTRAL
function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if gInitialized then
    updateSettings:share("Update Channel", propertyValue)
  end
end
--#endif

--- An update setting changed on another item.
function EC.SET_UPDATE_SETTING(params)
  log:trace("EC.SET_UPDATE_SETTING(%s)", params)
  updateSettings:take(params)
end

--#ifdef DRIVERCENTRAL
--- Not logged: the value is the code.
function OPC.Support_Code(propertyValue)
  supportCode:enter(propertyValue)
end
--#endif

function OPC.Lights(propertyValue)
  log:trace("OPC.Lights('%s')", propertyValue)
  if gInitialized then
    readLights()
  end
end

--- A setting that changes what the group offers or shows: the proxy is told again.
--- @param changes table
local function configure(changes)
  group.configure(changes)
  if gInitialized then
    group.refresh()
  end
end

function OPC.Light_Type(propertyValue)
  log:trace("OPC.Light_Type('%s')", propertyValue)
  configure({ lightType = propertyValue })
end

function OPC.Off_Command(propertyValue)
  log:trace("OPC.Off_Command('%s')", propertyValue)
  group.configure({ offCommand = propertyValue })
end

function OPC.Command_Delay_ms(propertyValue)
  log:trace("OPC.Command_Delay_ms('%s')", propertyValue)
  group.configure({ commandDelay = tointeger(propertyValue) or 0 })
end

function OPC.Brightness_Tracking(propertyValue)
  log:trace("OPC.Brightness_Tracking('%s')", propertyValue)
  configure({ brightnessTracking = propertyValue })
end

function OPC.Color_Tracking(propertyValue)
  log:trace("OPC.Color_Tracking('%s')", propertyValue)
  configure({ colorTracking = propertyValue })
end

function OPC.Tracked_Light(propertyValue)
  log:trace("OPC.Tracked_Light('%s')", propertyValue)
  local id = tointeger(string.match(propertyValue or "", "%d+"))
  configure(id and { trackedId = id } or { clearTracked = true })
end

function OPC.Keep_Lights_In_Sync(propertyValue)
  log:trace("OPC.Keep_Lights_In_Sync('%s')", propertyValue)
  group.configure({ keepSync = propertyValue == "On" })
end

function OPC.Scenes_In_Cycle(propertyValue)
  log:trace("OPC.Scenes_In_Cycle('%s')", propertyValue)
  cycle.configure({ any = propertyValue ~= "Only These Lights" })
end

function OPC.Skip_Toggle_Scenes(propertyValue)
  log:trace("OPC.Skip_Toggle_Scenes('%s')", propertyValue)
  cycle.configure({ skipToggle = propertyValue ~= "No" })
end

function OPC.Track_Current_Scene(propertyValue)
  log:trace("OPC.Track_Current_Scene('%s')", propertyValue)
  cycle.configure({ track = propertyValue ~= "Off" })
end

function OPC.Cycle_Off_Step(propertyValue)
  log:trace("OPC.Cycle_Off_Step('%s')", propertyValue)
  cycle.configure({ offStep = propertyValue == "On" })
end

function OPC.Cycle_Mode(propertyValue)
  log:trace("OPC.Cycle_Mode('%s')", propertyValue)
  cycle.configure({ backAndForth = propertyValue == "Back And Forth" })
end

function OPC.Cycle_Restart_After_s(propertyValue)
  log:trace("OPC.Cycle_Restart_After_s('%s')", propertyValue)
  cycle.configure({ restartAfter = tointeger(propertyValue) or 0 })
end

function OPC.Cycle_Hold_Action(propertyValue)
  log:trace("OPC.Cycle_Hold_Action('%s')", propertyValue)
  gCycleHold = propertyValue
end

function OPC.Feedback_Delay_ms(propertyValue)
  log:trace("OPC.Feedback_Delay_ms('%s')", propertyValue)
  group.configure({ feedbackDelay = tointeger(propertyValue) or 1500 })
end

function OPC.Color_Temperature_Range(propertyValue)
  log:trace("OPC.Color_Temperature_Range('%s')", propertyValue)
  local manual = propertyValue == "Manual"
  local visibility = manual and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
  C4:SetPropertyAttribs("Minimum Color Temperature (K)", visibility)
  C4:SetPropertyAttribs("Maximum Color Temperature (K)", visibility)
  configure({ manualRange = manual })
end

function OPC.Minimum_Color_Temperature_K(propertyValue)
  log:trace("OPC.Minimum_Color_Temperature_K('%s')", propertyValue)
  configure({ minKelvin = tointeger(propertyValue) or 2000 })
end

function OPC.Maximum_Color_Temperature_K(propertyValue)
  log:trace("OPC.Maximum_Color_Temperature_K('%s')", propertyValue)
  configure({ maxKelvin = tointeger(propertyValue) or 6500 })
end

function OPC.Color_Temperature_Mapping(propertyValue)
  log:trace("OPC.Color_Temperature_Mapping('%s')", propertyValue)
  group.configure({ scaled = propertyValue == "Scaled" })
end

function OPC.Emulate_Color_Temperature(propertyValue)
  log:trace("OPC.Emulate_Color_Temperature('%s')", propertyValue)
  configure({ emulate = propertyValue == "On" })
end

---------------------------------------------------------------------------
-- Actions and commands
---------------------------------------------------------------------------

--#ifndef DRIVERCENTRAL
function EC.Update_Drivers()
  log:trace("EC.Update_Drivers()")
  log:print("Updating drivers")
  UpdateDrivers(true)
end
--#endif

function EC.Display_Lights()
  log:trace("EC.Display_Lights()")
  local lines = group.describe()
  print(#lines == 0 and "No lights selected" or table.concat(lines, "\n"))
end

function EC.Display_Control_Log()
  log:trace("EC.Display_Control_Log()")
  local lines = group.controlLog()
  print(#lines == 0 and "No commands sent yet" or table.concat(lines, "\n"))
end

function EC.Test_Light_Commands()
  log:trace("EC.Test_Light_Commands()")
  group.probe(print)
end

function EC.Next_Scene()
  log:trace("EC.Next_Scene()")
  cycle.next()
end

function EC.Previous_Scene()
  log:trace("EC.Previous_Scene()")
  cycle.previous()
end

function EC.Restart_Scene_Cycle()
  log:trace("EC.Restart_Scene_Cycle()")
  cycle.restart()
end

function EC.Go_To_Scene(params)
  log:trace("EC.Go_To_Scene(%s)", params)
  cycle.goTo(Select(params, "Scene"))
end

--- The scenes Go To Scene offers: the cycle's steps.
function GCPL.Go_To_Scene()
  local names = {}
  for _, step in ipairs(cycle.steps()) do
    names[#names + 1] = step.name
  end
  return names
end

function EC.Sync_Lights()
  log:trace("EC.Sync_Lights()")
  group.sync()
end
