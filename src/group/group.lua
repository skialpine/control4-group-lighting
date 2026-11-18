--- The group's lights: which they are, what each can do and shows, the commands each is sent, and the one state the
--- group reports for them all.
---
--- To the shared light engine (lib/light.lua) the group is one device. `Group.adapter()` is that device's adapter: a
--- command in the library's device fields goes out to every light as Light V2 proxy commands, and the device's state
--- is the last command sent. Once the lights have settled, their own levels and colors are read back, and where they
--- differ from what was sent (a light switched at the wall, a light that cannot reach the color), the group's state
--- follows them as the tracking settings say.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local Aggregate = require("group.aggregate")
local Caps = require("lib.light.caps")
local Range = require("lib.light.range")

local light -- attached by the driver after Light.new

local Group = {}

--- Light V2 proxy variables, read from each light.
local VARIABLE = {
  LIGHT_STATE = 1000,
  LIGHT_LEVEL = 1001,
  --- "x,y,mode"
  LIGHT_COLOR = 1200,
  --- XML of the capabilities the light's driver told its proxy.
  DYNAMIC_CAPABILITIES = 6661,
}

local COLOR_MODE_FULL = 0
local COLOR_MODE_CCT = 1

local DEFAULT_MIN_KELVIN = 2000
local DEFAULT_MAX_KELVIN = 6500

--- Reports from the lights within this of each other are read together.
local FEEDBACK_DEBOUNCE_MS = 250
local CONTROL_LOG_SIZE = 50

--- @class GroupSettings
local settings = {
  lightType = "Automatic",
  offCommand = "Brightness 0",
  commandDelay = 0,
  brightnessTracking = Aggregate.Brightness.AVERAGE,
  colorTracking = Aggregate.Color.AVERAGE,
  trackedId = nil,
  feedbackDelay = 1500,
  manualRange = false,
  minKelvin = DEFAULT_MIN_KELVIN,
  maxKelvin = DEFAULT_MAX_KELVIN,
  scaled = false,
  emulate = true,
  keepSync = false,
}

--- @class Member: MemberState
--- @field name string
--- @field supportsColor boolean|nil
--- @field supportsCCT boolean|nil
--- @field minKelvin number|nil
--- @field maxKelvin number|nil
--- @field sentKelvin number|nil The white last sent as a color to a light without color temperature.
--- @field sentWhite { asked: number, sent: number }|nil The group's white last sent, and what this light was sent
---   for it on its own range.
--- @field deviceColor table|nil The reported color before mapping it back onto the group's range.
--- @field colorBusyUntil number|nil When the last dispatched color transition and its feedback have settled.
--- @field groupJoined boolean|nil A protocol join was sent for this connection.
--- @field groupProtocol boolean|nil Its join was answered with LIGHT_GROUP_STATE.
--- @field online boolean|nil Connection state reported by a native member.

--- @type Member[]
local members = {}

--- The virtual device's cached wire state: last sent, then reconciled with the members' reports.
local vstate = { on = false, level = 0, color = nil }

--- When the lights have settled after the group's last command (C4:GetTime, ms).
local busyUntil = 0
--- Its two parts: a level command replaces the level ramp before it, and a color command the color fade.
local levelBusyUntil, colorBusyUntil = 0, 0
--- Whether the lights have been read into the group once, which Ignore still allows.
local seeded = false
--- The last wire send still needs the members' settled answer, even if they reach exactly its target.
local pendingReport = false
--- A refresh from the shared engine is answered once the member fades settle.
local refreshAsked = false
local availabilityChanged = false
local feedbackChanged = false
--- The lights changed by something other than the group since they were last read, for the others to follow one
--- when kept in sync.
local changedLights = {}
--- The light the others were last sent after: its further reports still count while they settle.
local followed = nil
local queue = {}
--- Whether a command went out less than the command delay ago.
local spacing = false
local controlLog = {}
local onChange = function() end
local commandSequence = 0
local active = true
local displayed -- the shared engine's UI snapshot; independent of cached member feedback
local recordFeedback

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function isTrue(value)
  return value == true or (type(value) == "string" and value:lower() == "true")
end

local function vLevel()
  return vstate.on and Range.percent(vstate.level) or 0
end

--- The cached device color in the aggregation module's proxy representation.
local function vColor()
  local color = vstate.color
  return color
      and {
        mode = color.mode == "cct" and COLOR_MODE_CCT or COLOR_MODE_FULL,
        x = color.x,
        y = color.y,
        kelvin = color.kelvin,
      }
    or nil
end

local function record(member, command, params, outcome, sequence)
  local parts = {}
  for key, value in pairs(params or {}) do
    parts[#parts + 1] = key .. "=" .. tostring(value)
  end
  table.sort(parts)
  controlLog[#controlLog + 1] = string.format(
    "%s  t=%dms #%s  %s [%d]  %s %s %s",
    os.date("%Y-%m-%d %H:%M:%S"),
    C4:GetTime(),
    tostring(sequence or "-"),
    member.name,
    member.id,
    command,
    outcome or "reported",
    table.concat(parts, " ")
  )
  while #controlLog > CONTROL_LOG_SIZE do
    table.remove(controlLog, 1)
  end
end

recordFeedback = function(member, aspect, params)
  if member.watched then
    record(
      member,
      "FEEDBACK_" .. aspect:upper(),
      params,
      member.groupProtocol and "native" or "proxy",
      aspect == "color" and member.lastColorCommand or member.lastLevelCommand
    )
  end
end

---------------------------------------------------------------------------
-- What the group can do
---------------------------------------------------------------------------

--- @return boolean dims, boolean color, boolean cct
local function abilities()
  local kind = settings.lightType
  if kind == "On/Off" then
    return false, false, false
  elseif kind == "Dimmer" then
    return true, false, false
  elseif kind == "Color Temperature" then
    return true, false, true
  elseif kind == "Full Color" then
    return true, true, true
  end
  local dims, color, cct = false, false, false
  for _, member in ipairs(members) do
    dims = dims or member.dimmable ~= false
    color = color or member.supportsColor == true
    cct = cct or member.supportsCCT == true
  end
  -- A color light shows a white as a color, so a group of them still offers color temperature.
  cct = cct or (color and settings.emulate)
  return dims, color, cct
end

--- @return number minKelvin, number maxKelvin
local function kelvinRange()
  if settings.manualRange then
    local lo, hi = settings.minKelvin, settings.maxKelvin
    return math.min(lo, hi), math.max(lo, hi)
  end
  local lo, hi
  for _, member in ipairs(members) do
    if member.supportsCCT and member.minKelvin and member.maxKelvin then
      lo = math.min(lo or member.minKelvin, member.minKelvin)
      hi = math.max(hi or member.maxKelvin, member.maxKelvin)
    end
  end
  if not lo or not hi or hi <= lo then
    return DEFAULT_MIN_KELVIN, DEFAULT_MAX_KELVIN
  end
  return lo, hi
end

--- The group's capabilities and transport behavior, as the shared library's device.
--- @return LightDevice
function Group.device()
  local dims, color, cct = abilities()
  local lo, hi = kelvinRange()
  return {
    dims = dims,
    color = color,
    cct = cct and { minK = lo, maxK = hi } or nil,
    colorWhileOff = "hold",
    levelSteps = 100,
    fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = Caps.RATE_LIMIT },
    feedback = { shows = "target", waitMs = settings.feedbackDelay, refresh = true },
  }
end

---------------------------------------------------------------------------
-- Reading the lights
---------------------------------------------------------------------------

local function readCapabilities(member)
  local ok, xml = pcall(function()
    return ParseXml(C4:GetDeviceVariable(member.id, VARIABLE.DYNAMIC_CAPABILITIES))
  end)
  local caps = ok and Select(xml, "DynamicCapabilities") or nil
  if type(caps) ~= "table" then
    -- A light whose driver tells its proxy nothing is taken to dim, and is sent no color.
    member.dimmable, member.supportsColor, member.supportsCCT = nil, nil, nil
    return
  end
  if caps.dimmer ~= nil then
    member.dimmable = isTrue(caps.dimmer)
  end
  member.supportsColor = isTrue(caps.supports_color)
  member.supportsCCT = isTrue(caps.supports_color_correlated_temperature)
  member.minKelvin = tonumber(caps.color_correlated_temperature_min)
  member.maxKelvin = tonumber(caps.color_correlated_temperature_max)
end

local function readLevel(member, value)
  local level = tofinite(value)
  if level then
    member.level = math.max(0, math.min(100, math.floor(level + 0.5)))
    recordFeedback(member, "level", { LEVEL = member.level })
  end
end

local function readState(member, value)
  -- The level says more than on or off, so the state only fills in for a light with no level yet, or turns one off.
  if value == nil or value == "" then
    return
  end
  local on = toboolean(value)
  if not on then
    member.level = 0
  elseif member.dimmable == false then
    member.level = 100
  elseif member.level == nil or member.level == 0 then
    readLevel(member, C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_LEVEL))
  end
  recordFeedback(member, "level", { ON = on, LEVEL = member.level or "unknown" })
end

local function validKelvin(value)
  local kelvin = tofinite(value)
  return kelvin and kelvin > 0 and kelvin < 100000 and kelvin or nil
end

local function readColor(member, value, reportedKelvin)
  local x, y, mode = string.match(tostring(value or ""), "^([^,]+),([^,]+),([^,]+)$")
  x, y, mode = tonumber(x), tonumber(y), tonumber(mode)
  if not x or not y or not (x >= 0 and x <= 1 and y >= 0 and y <= 1) then
    return false
  end
  local color = { mode = mode == COLOR_MODE_CCT and COLOR_MODE_CCT or COLOR_MODE_FULL, x = x, y = y }
  if color.mode == COLOR_MODE_CCT then
    color.kelvin = validKelvin(reportedKelvin) or validKelvin(C4:ColorXYtoCCT(x, y))
  end
  member.deviceColor = { mode = color.mode, x = x, y = y, kelvin = color.kelvin }
  if color.mode == COLOR_MODE_CCT then
    -- The white this light was sent for the group's, mapped onto its own range, reads as the group's.
    local white = member.sentWhite
    if white and color.kelvin and math.abs(color.kelvin - white.sent) <= math.max(50, 0.02 * white.sent) then
      color.kelvin = white.asked
      color.x, color.y = C4:ColorCCTtoXY(white.asked)
    end
  elseif member.sentKelvin then
    -- A white this light was sent as a color still reads as that white.
    local wx, wy = C4:ColorCCTtoXY(member.sentKelvin)
    if math.abs(wx - x) <= Aggregate.XY_TOLERANCE and math.abs(wy - y) <= Aggregate.XY_TOLERANCE then
      color.mode, color.kelvin = COLOR_MODE_CCT, member.sentKelvin
    end
  end
  member.color = color
  recordFeedback(member, "color", { MODE = color.mode, X = x, Y = y, KELVIN = color.kelvin })
  return true
end

local evaluate

local function scheduleFeedback()
  local wait = availabilityChanged and FEEDBACK_DEBOUNCE_MS or math.max(FEEDBACK_DEBOUNCE_MS, busyUntil - C4:GetTime())
  SetTimer("GroupFeedback", wait, function()
    evaluate()
  end)
end

local function showing(member)
  local color = member.color or {}
  return tostring(member.level) .. "," .. tostring(color.x) .. "," .. tostring(color.y)
end

--- A light reported a level or color.
--- @param member Member
--- @param before string What it showed before the report.
local function reported(member, before)
  if not active then
    return
  end
  local now = showing(member)
  feedbackChanged = feedbackChanged or now ~= before
  -- A report while the lights settle is the group's own command taking effect, but for the light the others are
  -- following: it may still be moving.
  if member.watched and now ~= before and (C4:GetTime() >= busyUntil or member == followed) then
    changedLights[member] = true
  end
  scheduleFeedback()
end

local function watch(member)
  -- A light without color has no color variable to listen to, and its listener is refused.
  local function RegisterVariableListener(...)
    local ok, err = pcall(_G.RegisterVariableListener, ...)
    if not ok then
      log:debug("No listener for variable %s of %s: %s", select(2, ...), member.name, err)
    end
  end
  RegisterVariableListener(member.id, VARIABLE.LIGHT_LEVEL, function(_, _, value)
    if member.groupProtocol then
      return
    end
    local before = showing(member)
    readLevel(member, value)
    reported(member, before)
  end)
  RegisterVariableListener(member.id, VARIABLE.LIGHT_STATE, function(_, _, value)
    if member.groupProtocol then
      return
    end
    local before = showing(member)
    readState(member, value)
    reported(member, before)
  end)
  RegisterVariableListener(member.id, VARIABLE.LIGHT_COLOR, function(_, _, value)
    if member.groupProtocol then
      return
    end
    local before = showing(member)
    readColor(member, value)
    reported(member, before)
  end)
  RegisterVariableListener(member.id, VARIABLE.DYNAMIC_CAPABILITIES, function()
    -- A listener is called once as it is set, while the group's lights are still being read.
    if member.watched then
      readCapabilities(member)
      Group.refresh()
    end
  end)
  member.watched = true
end

local function unwatch(member)
  for _, variable in pairs(VARIABLE) do
    UnregisterVariableListener(member.id, variable)
  end
end

--- @return boolean levelRead, boolean colorRead
local function readMemberState(member)
  local ok, level = pcall(function()
    local level = tofinite(C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_LEVEL))
    if level == nil then
      local state = C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_STATE)
      if state ~= nil and state ~= "" then
        if not toboolean(state) then
          level = 0
        elseif member.dimmable == false then
          level = 100
        end
      end
    end
    return level
  end)
  if not ok then
    log:warn("Could not read the level of %s [%d]: %s", member.name, member.id, tostring(level))
    return false, false
  end
  readLevel(member, level)
  local expectsColor = member.supportsColor or member.supportsCCT
  local colorOK, color = pcall(C4.GetDeviceVariable, C4, member.id, VARIABLE.LIGHT_COLOR)
  if not colorOK and expectsColor then
    log:warn("Could not read the color of %s [%d]: %s", member.name, member.id, tostring(color))
  end
  local colorRead = colorOK and readColor(member, color)
  return level ~= nil, colorRead or not expectsColor
end

---------------------------------------------------------------------------
-- Telling the light model
---------------------------------------------------------------------------

--- @param kind LightReportKind
--- @param colorConfirmed boolean
local function pushState(kind, colorConfirmed)
  if not light or #members == 0 then
    return
  end
  light:declare(Group.device())
  if seeded then
    light:report({ kind = kind, on = vstate.on, level = vstate.level, color = colorConfirmed and vstate.color or nil })
  end
end

local function setVColor(color)
  vstate.color =
    { mode = color.mode == COLOR_MODE_CCT and "cct" or "xy", x = color.x, y = color.y, kelvin = color.kelvin }
end

--- @class GroupStatus
--- @field total integer
--- @field known integer Lights with a level and no reported loss.
--- @field on integer Lights last reported on.
--- @field offline integer Lights that have explicitly reported a loss.
--- @field inSync boolean

--- @return GroupStatus
function Group.status()
  local on, known, offline = 0, 0, 0
  for _, member in ipairs(members) do
    if member.online == false then
      offline = offline + 1
    elseif member.level ~= nil then
      known = known + 1
    end
    if (member.level or 0) > 0 then
      on = on + 1
    end
  end
  return {
    total = #members,
    known = known,
    on = on,
    offline = offline,
    inSync = known == #members and Aggregate.inSync(members, vLevel()),
  }
end

local function loseConnection()
  refreshAsked, pendingReport, availabilityChanged, feedbackChanged = false, false, false, false
  busyUntil, levelBusyUntil, colorBusyUntil = 0, 0, 0
  queue, spacing, changedLights, followed = {}, false, {}, nil
  CancelTimer("GroupQueue")
  CancelTimer("GroupFeedback")
  if light and light.online then
    light:lost()
  end
end

--- Reads the lights' own levels and colors into the group's state, once they have settled.
--- @param force boolean|nil Read them now, and tell the light model even if nothing differs.
evaluate = function(force)
  if #members == 0 then
    return
  end
  local reachable = {}
  for _, member in ipairs(members) do
    if member.online ~= false then
      reachable[#reachable + 1] = member
    end
  end
  if #reachable == 0 then
    loseConnection()
    onChange(Group.status())
    return
  end
  if not force and C4:GetTime() < busyUntil then
    if availabilityChanged then
      onChange(Group.status())
    end
    availabilityChanged = false
    scheduleFeedback()
    return
  end
  local reconcile = feedbackChanged or pendingReport or refreshAsked or force or (light and not light.online)
  availabilityChanged, feedbackChanged = false, false
  if not reconcile then
    onChange(Group.status())
    return
  end
  -- One light changed by itself takes the others with it. Several changed together is a scene, or programming,
  -- which set each light where it wants it.
  local source, count = nil, 0
  for member in pairs(changedLights) do
    source, count = member, count + 1
  end
  changedLights = {}
  followed = nil
  if settings.keepSync and count == 1 and not force and Group.follow(source) then
    onChange(Group.status())
    return
  end
  local kind, colorConfirmed = "push", true
  if (refreshAsked or pendingReport) and C4:GetTime() >= busyUntil then
    local levelConfirmed = true
    for _, member in ipairs(reachable) do
      if not member.groupProtocol then
        local levelRead, colorRead = readMemberState(member)
        levelConfirmed = levelConfirmed and levelRead
        colorConfirmed = colorConfirmed and colorRead
      end
    end
    kind = refreshAsked and "final" or "push"
    refreshAsked = false
    if not levelConfirmed then
      pendingReport = false
      onChange(Group.status())
      return
    end
  end
  local dims, color, cct = abilities()
  local changed = force or kind == "final" or pendingReport or (light and not light.online)
  if vstate.color and ((vstate.color.mode == "xy" and not color) or (vstate.color.mode == "cct" and not cct)) then
    vstate.color = nil
  end
  local commanded = vLevel()
  -- Ignore still reads the lights once, at start, for a level to show.
  local first = not seeded
  local tracking = settings.brightnessTracking
  if first and tracking == Aggregate.Brightness.IGNORE then
    tracking = Aggregate.Brightness.AVERAGE
  end
  local level = Aggregate.level(reachable, tracking, settings.trackedId, commanded)
  if level ~= nil then
    seeded = true
  end
  if level and not dims and level > 0 then
    level = 100
  end
  if
    level and (level > 0) ~= (commanded > 0) or (level and math.abs(level - commanded) > Aggregate.LEVEL_TOLERANCE)
  then
    log:debug("The lights are at %d%%; the group was at %d%%", level, commanded)
    vstate.on = level > 0
    if level > 0 then
      vstate.level = level / 100
    end
    changed = true
  end
  if colorConfirmed and (color or cct) then
    local colorTracking = settings.colorTracking
    if first and colorTracking == Aggregate.Color.IGNORE then
      colorTracking = Aggregate.Color.AVERAGE
    end
    local shown = Aggregate.color(reachable, colorTracking, settings.trackedId)
    if shown and shown.mode == COLOR_MODE_FULL and not color then
      shown = nil
    elseif shown and shown.mode == COLOR_MODE_CCT and not cct then
      shown = nil
    end
    if shown and not Aggregate.sameColor(shown, vColor()) then
      log:debug("The lights' color differs from the group's")
      setVColor(shown)
      changed = true
    end
  end
  if changed then
    pendingReport = false
    -- The status below is still shown if the light model raises.
    local ok, err = xpcall(function()
      pushState(kind, colorConfirmed)
    end, debug.traceback)
    if not ok then
      log:error("The group's state could not be told to the proxy: %s", err)
    end
  end
  onChange(Group.status())
end

---------------------------------------------------------------------------
-- Commanding the lights
---------------------------------------------------------------------------

local function dispatch(entry)
  local member, command, params = entry.member, entry.command, entry.params
  local color = command == "SET_COLOR_TARGET" or (command == "LIGHT_GROUP_COMMAND" and params.X ~= nil)
  local level = command ~= "SET_COLOR_TARGET" and not (command == "LIGHT_GROUP_COMMAND" and params.KIND == "color")
  local priorLevel, priorColor = member.lastLevelCommand, member.lastColorCommand
  if color then
    member.lastColorCommand = entry.sequence
  end
  if level then
    member.lastLevelCommand = entry.sequence
  end
  record(member, command, params, "send", entry.sequence)
  local target = command == "LIGHT_GROUP_COMMAND" and member.protocolId or member.id
  local ok, err = pcall(SendToDevice, target, command, params)
  if not ok then
    member.lastLevelCommand, member.lastColorCommand = priorLevel, priorColor
    record(member, command, { ERROR = tostring(err) }, "failed", entry.sequence)
    log:error("Command #%d to %s [%d] failed: %s", entry.sequence, member.name, target, tostring(err))
    return false
  end
  if color then
    member.colorBusyUntil = C4:GetTime() + (tonumber(params.RATE) or 0) + settings.feedbackDelay
  end
  record(member, command, {}, "sent", entry.sequence)
  return true
end

local function drain()
  local entry = table.remove(queue, 1)
  if not entry then
    spacing = false
    return
  end
  dispatch(entry)
  spacing = true
  SetTimer("GroupQueue", settings.commandDelay, drain)
end

local function enqueue(member, command, params)
  commandSequence = commandSequence + 1
  local entry = { member = member, command = command, params = params, sequence = commandSequence }
  record(member, command, params, "requested", entry.sequence)
  if settings.commandDelay <= 0 then
    dispatch(entry)
    return
  end
  -- A newer command of the same kind replaces one still waiting for the same light.
  local native = command == "LIGHT_GROUP_COMMAND"
  local kind = (command == "SET_COLOR_TARGET" or (native and params.KIND == "color")) and "color" or "level"
  if native then
    -- Keep the latest queued level and color without losing an earlier combined color when only level changes.
    for i = #queue, 1, -1 do
      local waiting = queue[i]
      if waiting.member == member and waiting.command == command then
        if kind == "level" and (params.X or params.KIND == "off") and waiting.kind == "color" then
          record(member, waiting.command, {}, "superseded", waiting.sequence)
          table.remove(queue, i)
        elseif kind == "color" and waiting.kind == "level" then
          for _, key in ipairs({ "X", "Y", "KELVIN", "MODE" }) do
            waiting.params[key] = nil
          end
        elseif kind == "level" and params.KIND ~= "off" and not params.X and waiting.kind == "level" then
          for _, key in ipairs({ "X", "Y", "KELVIN", "MODE" }) do
            params[key] = waiting.params[key]
          end
        end
      end
    end
  end
  entry.kind = kind
  for i, waiting in ipairs(queue) do
    if waiting.member == member and waiting.kind == kind then
      record(member, waiting.command, {}, "superseded", waiting.sequence)
      queue[i] = entry
      return
    end
  end
  queue[#queue + 1] = entry
  if not spacing then
    drain()
  end
end

local function colorParams(member, color)
  local params
  if color.mode == "cct" and color.kelvin then
    local groupMin, groupMax = kelvinRange()
    if member.supportsCCT then
      local kelvin =
        Aggregate.mapKelvin(color.kelvin, groupMin, groupMax, member.minKelvin, member.maxKelvin, settings.scaled)
      member.sentKelvin = nil
      -- What the light answers with is its own white for the group's, and reads back as the group's.
      member.sentWhite = { asked = color.kelvin, sent = math.floor(kelvin + 0.5) }
      -- A white goes as its temperature: on OS 4.3 a light's proxy did nothing with one sent as xy.
      params = {
        LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = math.floor(kelvin + 0.5),
        LIGHT_COLOR_TARGET_MODE = COLOR_MODE_CCT,
      }
    elseif member.supportsColor and settings.emulate then
      local x, y = C4:ColorCCTtoXY(color.kelvin)
      member.sentKelvin = color.kelvin
      member.sentWhite = nil
      params = { LIGHT_COLOR_TARGET_X = x, LIGHT_COLOR_TARGET_Y = y, LIGHT_COLOR_TARGET_MODE = COLOR_MODE_FULL }
    end
  elseif member.supportsColor then
    member.sentKelvin = nil
    member.sentWhite = nil
    params = {
      LIGHT_COLOR_TARGET_X = color.x,
      LIGHT_COLOR_TARGET_Y = color.y,
      LIGHT_COLOR_TARGET_MODE = COLOR_MODE_FULL,
    }
  end
  return params
end

local function sendColor(member, color, rate, onlyIfChanged)
  local params = colorParams(member, color)
  if params then
    -- A color command can turn an off light on at its own rate before the following brightness ramp reaches it.
    -- Compare on the light's own range, and only skip a settled color: a queued or moving color still needs replacing.
    if onlyIfChanged and C4:GetTime() >= (member.colorBusyUntil or 0) then
      local pending = false
      for _, entry in ipairs(queue) do
        pending = pending or (entry.member == member and entry.command == "SET_COLOR_TARGET")
      end
      local target = {
        mode = params.LIGHT_COLOR_TARGET_MODE,
        x = params.LIGHT_COLOR_TARGET_X,
        y = params.LIGHT_COLOR_TARGET_Y,
        kelvin = params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE,
      }
      if target.kelvin then
        target.x, target.y = C4:ColorCCTtoXY(target.kelvin)
      end
      if not pending and Aggregate.sameColor(member.deviceColor, target) then
        return
      end
    end
    params.RATE = rate
    enqueue(member, "SET_COLOR_TARGET", params)
  end
end

local function sendLevel(member, level, rate, plainOn)
  if member.dimmable == false then
    enqueue(member, level > 0 and "ON" or "OFF", {})
  elseif level == 0 and settings.offCommand == "Off" then
    enqueue(member, "OFF", {})
  elseif plainOn then
    -- A group that only switches leaves each light to its own on level.
    enqueue(member, "ON", {})
  else
    -- On OS 4.3 a light's proxy did nothing with SET_BRIGHTNESS_TARGET sent by another driver, and acted on a
    -- level and a time.
    enqueue(member, "RAMP_TO_LEVEL", { LEVEL = level, TIME = rate })
  end
end

--- A confirmed template member accepts the final brightness and mapped color together.
local function sendCombined(member, level, color, rate)
  local mapped = color and colorParams(member, color) or nil
  if level == nil and not mapped then
    return
  end
  local params = {
    GROUP_ID = tostring(C4:GetDeviceID()),
    KIND = level ~= nil and (level > 0 and "level" or "off") or "color",
    LEVEL = level ~= nil and tostring(level) or nil,
    RATE = tostring(level == 0 and settings.offCommand == "Off" and 0 or rate),
  }
  if mapped then
    params.X, params.Y = mapped.LIGHT_COLOR_TARGET_X, mapped.LIGHT_COLOR_TARGET_Y
    params.KELVIN = mapped.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE
    if params.KELVIN then
      params.X, params.Y = C4:ColorCCTtoXY(params.KELVIN)
    end
    params.X, params.Y = tostring(params.X), tostring(params.Y)
    params.MODE = mapped.LIGHT_COLOR_TARGET_MODE == COLOR_MODE_CCT and "cct" or "xy"
    if params.KELVIN then
      params.KELVIN = tostring(params.KELVIN)
    end
    member.colorBusyUntil = C4:GetTime() + rate + settings.feedbackDelay
  end
  enqueue(member, "LIGHT_GROUP_COMMAND", params)
end

--- One command from the shared engine, translated to each member's Light V2 transport.
local function send(cmd, except)
  if cmd.kind == "preOn" then
    return
  end
  local rate = math.max(0, math.floor((cmd.transitionMs or 0) + 0.5))
  local wasOn = vstate.on
  local level = cmd.setsLevel and (cmd.on and Range.percent(cmd.level) or 0) or nil
  local plainOn = level and level > 0 and not abilities()
  vstate.on, vstate.level = cmd.on, cmd.level
  if cmd.color then
    vstate.color = cmd.color
  end
  -- Color while off is held by lib.light. A color alone leaves an individually off member off.
  local color = cmd.setsColor and cmd.on and cmd.color or nil
  for _, member in ipairs(members) do
    if member ~= except then
      local memberColor = color and (level or member.level ~= 0) and color or nil
      -- A group that already reads On can contain an off member. Rejoining it also restores the group's color;
      -- the engine correctly carries that color without marking a color change on the group itself.
      if level and level > 0 and member.level == 0 and cmd.color then
        memberColor = cmd.color
      end
      if member.groupProtocol and not plainOn then
        sendCombined(member, level, memberColor, rate)
      else
        if memberColor then
          sendColor(member, memberColor, (member.level or 0) > 0 and wasOn and rate or 0, level ~= nil and rate > 0)
        end
        if level then
          sendLevel(member, level, rate, plainOn)
        end
      end
    end
  end
  local settled = C4:GetTime() + rate + settings.commandDelay * #queue + settings.feedbackDelay
  if level then
    levelBusyUntil = settled
  end
  if color then
    colorBusyUntil = settled
  end
  busyUntil = math.max(levelBusyUntil, colorBusyUntil)
  pendingReport = true
  seeded = true
  scheduleFeedback()
end

--- Attach the light made once by the driver's top-level chunk.
function Group.attach(instance)
  light, active = instance, true
  EC.LIGHT_GROUP_STATE = function(params)
    if not active then
      return
    end
    local id = tointeger(Select(params, "MEMBER_ID"))
    for _, member in ipairs(members) do
      if member.id == id and member.groupJoined then
        -- Only a reply to this connection's join confirms the custom protocol. A generic load-group capability
        -- alone does not: ordinary Light V2 drivers keep the standard transport.
        member.groupProtocol = true
        local wasOnline = member.online
        member.online = toboolean(Select(params, "ONLINE"))
        availabilityChanged = availabilityChanged or (wasOnline ~= member.online)
        if not member.online then
          -- A lost member's report can have an empty level and color. Keep its last real state.
          changedLights[member] = nil
          if followed == member then
            followed = nil
          end
          if wasOnline ~= false then
            scheduleFeedback()
          end
          return
        end
        local before = showing(member)
        if toboolean(Select(params, "ON")) then
          readLevel(member, Select(params, "LEVEL"))
        else
          member.level = 0
        end
        local x, y = tonumber(Select(params, "X")), tonumber(Select(params, "Y"))
        if x and y then
          readColor(
            member,
            x .. "," .. y .. "," .. (Select(params, "MODE") == "cct" and "1" or "0"),
            Select(params, "KELVIN")
          )
        end
        if wasOnline == false then
          feedbackChanged = true
          scheduleFeedback()
        else
          reported(member, before)
        end
        return
      end
    end
  end
end

--- @return LightProfile
function Group.profile()
  return {
    api = 1,
    links = { top = 300, toggle = 301, bottom = 302 },
    dims = true,
    color = true,
    cct = true,
    fades = true,
    maxMs = Caps.RATE_LIMIT,
    defaultOn = true,
    scenes = true,
    onModes = true,
    flash = true,
  }
end

--- @return LightAdapter
function Group.adapter()
  return {
    send = function(_, cmd)
      return send(cmd)
    end,
    refresh = function()
      if #members == 0 then
        return
      end
      refreshAsked = true
      evaluate()
    end,
    show = function(_, shown)
      displayed = shown
      onChange(Group.status())
    end,
  }
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------

--- Tells the light model what the group is and shows now, after its lights or settings changed.
function Group.refresh()
  if #members == 0 then
    loseConnection()
    onChange(Group.status())
    return
  end
  evaluate(true)
end

--- Sets the group's lights.
--- @param devices { id: integer, name: string }[] In the order they are commanded.
function Group.setMembers(devices)
  local kept = {}
  for _, member in ipairs(members) do
    kept[member.id] = member
  end
  local now = {}
  for _, device in ipairs(devices) do
    local member = kept[device.id]
    if member then
      kept[device.id] = nil
      member.name = device.name
    else
      member = { id = device.id, name = device.name }
      watch(member)
    end
    readCapabilities(member)
    if not member.groupProtocol then
      readMemberState(member)
    end
    now[#now + 1] = member
  end
  for _, member in pairs(kept) do
    if member.groupJoined then
      local ok, err =
        pcall(SendToDevice, member.protocolId, "LIGHT_GROUP_LEAVE", { GROUP_ID = tostring(C4:GetDeviceID()) })
      if not ok then
        log:warn("Leaving %s's native group failed: %s", member.name, tostring(err))
      end
    end
    unwatch(member)
  end
  members = now
  -- Install the complete list before joins: a compatible member may answer synchronously.
  for _, member in ipairs(members) do
    if not member.groupJoined then
      -- Native commands belong to the protocol driver; feedback variables belong to the selected proxy.
      local ok, devices = pcall(C4.GetDevices, C4, { DeviceIds = tostring(member.id) })
      local device = ok and type(devices) == "table" and (devices[member.id] or devices[tostring(member.id)])
      member.protocolId = member.id
      for id in pairs(type(device) == "table" and device.protocol or {}) do
        member.protocolId = tointeger(id) or member.id
        break
      end
      member.groupJoined = true
      local joined, err = pcall(
        SendToDevice,
        member.protocolId,
        "LIGHT_GROUP_JOIN",
        { GROUP_ID = tostring(C4:GetDeviceID()), MEMBER_ID = tostring(member.id) }
      )
      if not joined then
        member.groupJoined = false
        log:warn(
          "Joining %s's native group failed: %s; standard Light V2 remains available",
          member.name,
          tostring(err)
        )
      end
    end
  end
  queue = {}
  spacing = false
  CancelTimer("GroupQueue")
  Group.refresh()
end

--- End this instance's transport work before Director unloads it. No device or proxy commands go out.
function Group.stop()
  active = false
  refreshAsked, availabilityChanged, feedbackChanged = false, false, false
  for _, name in ipairs({ "GroupQueue", "GroupFeedback", "GroupProbe" }) do
    CancelTimer(name)
  end
  queue, spacing, changedLights, followed = {}, false, {}, nil
  for _, member in ipairs(members) do
    unwatch(member)
  end
end

--- Changes the group's settings.
--- @param changes GroupSettings Only the settings named change.
function Group.configure(changes)
  for key, value in pairs(changes) do
    settings[key] = value
  end
  -- A false here would be read as "not named".
  if changes.clearTracked then
    settings.trackedId = nil
    settings.clearTracked = nil
  end
end

--- Sends the other lights what one light shows, and makes it the group's.
--- @param source Member The light changed by something other than the group.
--- @return boolean followed False when the light shows what the group already does.
function Group.follow(source)
  local dims, color, cct = abilities()
  local commanded = vLevel()
  local level = Aggregate.memberLevel(source, commanded)
  if not level then
    return false
  end
  local levelDiffers = (level > 0) ~= (commanded > 0) or math.abs(level - commanded) > Aggregate.LEVEL_TOLERANCE
  local shown = level > 0 and source.color or nil
  if shown and ((shown.mode == COLOR_MODE_CCT and not cct) or (shown.mode ~= COLOR_MODE_CCT and not color)) then
    shown = nil
  end
  local colorDiffers = shown ~= nil and not Aggregate.sameColor(shown, vColor())
  if not levelDiffers and not colorDiffers then
    return false
  end
  log:debug("%s changed; the other lights follow it", source.name)
  local cmd = {
    kind = "change",
    on = level > 0,
    level = level / 100,
    setsLevel = true,
    setsColor = colorDiffers,
    transitionMs = 0,
  }
  if colorDiffers then
    cmd.color =
      { mode = shown.mode == COLOR_MODE_CCT and "cct" or "xy", x = shown.x, y = shown.y, kelvin = shown.kelvin }
  end
  send(cmd, source)
  followed = source
  return true
end

--- The lights are about to be set by something that is not one light changed by itself, such as a scene the
--- driver activates: for this long they are not followed.
--- @param ms integer
function Group.hold(ms)
  levelBusyUntil = math.max(levelBusyUntil, C4:GetTime() + ms)
  busyUntil = math.max(levelBusyUntil, colorBusyUntil)
end

--- Sends every light the group's level and color again.
function Group.sync()
  if #members == 0 then
    return
  end
  send({
    kind = "change",
    on = vstate.on,
    level = vstate.level,
    color = vstate.color,
    setsLevel = true,
    setsColor = vstate.color ~= nil,
    transitionMs = 0,
  })
end

--- @param callback fun(status: GroupStatus) Called after the lights are read.
function Group.onChange(callback)
  onChange = callback
end

--- @return string[] lines One line per light: what it can do and shows.
function Group.describe()
  local lines = {}
  for _, member in ipairs(members) do
    local can = {}
    can[#can + 1] = member.dimmable == false and "on/off" or "dimmer"
    if member.supportsColor then
      can[#can + 1] = "color"
    end
    if member.supportsCCT then
      can[#can + 1] = string.format("color temperature %s-%sK", member.minKelvin or "?", member.maxKelvin or "?")
    end
    local shows = member.level and (member.level .. "%") or "unknown"
    if member.color then
      shows = shows
        .. (
          member.color.kelvin and string.format(", %dK", member.color.kelvin)
          or string.format(", xy %.4f,%.4f", member.color.x, member.color.y)
        )
    end
    lines[#lines + 1] = string.format("%s [%d]: %s; %s", member.name, member.id, table.concat(can, ", "), shows)
  end
  return lines
end

--- Tries each way of setting a color temperature on the group's first light, and reports what the light showed after each. For
--- finding the command a light's driver acts on.
--- @param report fun(line: string)
function Group.probe(report)
  local member = members[1]
  if not member then
    report("No lights selected")
    return
  end
  local steps = {
    { "RAMP_TO_LEVEL", { LEVEL = 50, TIME = 0 } },
    {
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 2700, LIGHT_COLOR_TARGET_MODE = 1, RATE = 0 },
      "2700K, as the group sends it",
    },
    { "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = 5000 }, "5000K, no mode" },
    { "RAMP_TO_LEVEL", { LEVEL = 0, TIME = 0 } },
  }
  local wait = 3000
  -- The group does not read its lights while they are being tried.
  Group.hold(wait * (#steps + 1))
  report(string.format("Trying %d commands on %s [%d], %d s apart", #steps, member.name, member.id, wait / 1000))
  local function shown()
    local level = tostring(C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_LEVEL))
    local x, y = string.match(tostring(C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_COLOR) or ""), "^([^,]+),([^,]+)")
    local kelvin = tonumber(x) and tonumber(y) and C4:ColorXYtoCCT(tonumber(x), tonumber(y))
    return level .. "%" .. (kelvin and string.format(" %dK", kelvin) or "")
  end
  local function run(i, before)
    local step = steps[i]
    if not step then
      report("Done")
      scheduleFeedback()
      return
    end
    C4:SendToDevice(member.id, step[1], step[2])
    SetTimer("GroupProbe", wait, function()
      local after = shown()
      report(
        string.format(
          "%s%s: %s -> %s %s",
          step[1],
          step[3] and (" (" .. step[3] .. ")") or "",
          before,
          after,
          after ~= before and "CHANGED" or "no change"
        )
      )
      run(i + 1, after)
    end)
  end
  run(1, shown())
end

--- The group and its lights as the Settings tab shows them.
--- @return table snapshot
function Group.snapshot()
  local dims, color, cct = abilities()
  local lo, hi = kelvinRange()
  local shown = vColor()
  if displayed and displayed.color then
    local c = displayed.color
    shown = { x = c.x, y = c.y, mode = c.mode == "cct" and COLOR_MODE_CCT or COLOR_MODE_FULL, kelvin = c.kelvin }
  end
  local lights = {}
  for _, member in ipairs(members) do
    lights[#lights + 1] = {
      id = member.id,
      name = member.name,
      -- False only for a light known to switch; a light that reports nothing is taken to dim.
      dimmable = member.dimmable ~= false,
      color = member.supportsColor == true,
      cct = member.supportsCCT == true,
      minKelvin = member.minKelvin,
      maxKelvin = member.maxKelvin,
      level = member.level,
      online = member.online,
      inSync = Aggregate.memberInSync(member, vLevel(), shown),
      kelvin = member.color and member.color.kelvin and math.floor(member.color.kelvin + 0.5) or nil,
      x = member.color and member.color.x or nil,
      y = member.color and member.color.y or nil,
    }
  end
  local status = Group.status()
  return {
    total = status.total,
    known = status.known,
    offline = status.offline,
    on = status.on,
    inSync = status.inSync,
    level = seeded and vLevel() or nil,
    kelvin = shown and shown.kelvin and math.floor(shown.kelvin + 0.5) or nil,
    x = shown and not shown.kelvin and shown.x or nil,
    y = shown and not shown.kelvin and shown.y or nil,
    dims = dims,
    color = color,
    cct = cct,
    minKelvin = cct and lo or nil,
    maxKelvin = cct and hi or nil,
    trackedId = settings.trackedId,
    lights = lights,
  }
end

--- @return string[] lines The last commands sent to the lights, oldest first.
function Group.controlLog()
  return controlLog
end

--- @return integer count
function Group.size()
  return #members
end

return Group
