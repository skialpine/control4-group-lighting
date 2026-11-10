--- The group's lights: which they are, what each can do and shows, the commands each is sent, and the one state the
--- group reports for them all.
---
--- To the light model (group/light.lua) the group is one device. `Group.adapter()` is that device's adapter: a
--- command in the model's channel fields goes out to every light as Light V2 proxy commands, and the device's state
--- is the last command sent. Once the lights have settled, their own levels and colors are read back, and where they
--- differ from what was sent (a light switched at the wall, a light that cannot reach the color), the group's state
--- follows them as the tracking settings say.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local Aggregate = require("group.aggregate")
local light = require("group.light")

local Group = {}

local ColorMode = light.ColorMode

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

--- The group's own command is answered this long after it, as a device would.
local ECHO_MS = 20
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

--- @type Member[]
local members = {}

--- The group's state as a device's, in the light model's channel fields.
local vstate = {
  state = false,
  brightness = 0,
  color_mode = ColorMode.COLOR_MODE_UNKNOWN,
  color_brightness = 1,
  red = 1,
  green = 1,
  blue = 1,
  white = 0,
  color_temperature = 0,
  cold_white = 0,
  warm_white = 0,
}

--- When the lights have settled after the group's last command (C4:GetTime, ms).
local busyUntil = 0
--- Its two parts: a level command replaces the level ramp before it, and a color command the color fade.
local levelBusyUntil, colorBusyUntil = 0, 0
--- Whether the lights have been read into the group once, which Ignore still allows.
local seeded = false
-- A failed proxy send must be retried even when no member's level changes.
local publicationPending = false
--- The lights changed by something other than the group since they were last read, for the others to follow one
--- when kept in sync.
local changedLights = {}
--- The light the others were last sent after: its further reports still count while they settle.
local followed = nil
local queue = {}
local controlLog = {}
local onChange = function() end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function isTrue(value)
  return value == true or (type(value) == "string" and value:lower() == "true")
end

--- h 0-360, s and v 0-100, to r, g, b 0-1.
local function hsvToRGB(h, s, v)
  s, v = s / 100, v / 100
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b
  if h < 60 then
    r, g, b = c, x, 0
  elseif h < 120 then
    r, g, b = x, c, 0
  elseif h < 180 then
    r, g, b = 0, c, x
  elseif h < 240 then
    r, g, b = 0, x, c
  elseif h < 300 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  return r + m, g + m, b + m
end

--- r, g, b 0-1 to h 0-360 and s 0-100.
local function rgbToHS(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then
      h = 60 * (((g - b) / d) % 6)
    elseif mx == g then
      h = 60 * ((b - r) / d + 2)
    else
      h = 60 * ((r - g) / d + 4)
    end
  end
  return h < 0 and h + 360 or h, mx > 0 and (d / mx) * 100 or 0
end

local function vLevel()
  if not vstate.state then
    return 0
  end
  return math.max(1, math.min(100, math.floor(vstate.brightness * 100 + 0.5)))
end

--- The group's color as the lights' colors are compared, or nil before it has one.
local function vColor()
  if vstate.color_mode == ColorMode.COLOR_MODE_COLOR_TEMPERATURE and vstate.color_temperature > 0 then
    local kelvin = 1e6 / vstate.color_temperature
    local x, y = C4:ColorCCTtoXY(kelvin)
    return { mode = COLOR_MODE_CCT, x = x, y = y, kelvin = kelvin }
  elseif vstate.color_mode == ColorMode.COLOR_MODE_RGB then
    local h, s = rgbToHS(vstate.red, vstate.green, vstate.blue)
    local x, y = C4:ColorHSVtoXY(h, s, 100)
    return { mode = COLOR_MODE_FULL, x = x, y = y }
  end
end

local function record(member, command, params)
  local parts = {}
  for key, value in pairs(params or {}) do
    parts[#parts + 1] = key .. "=" .. tostring(value)
  end
  table.sort(parts)
  controlLog[#controlLog + 1] = string.format(
    "%s  %s [%d]  %s %s",
    os.date("%Y-%m-%d %H:%M:%S"),
    member.name,
    member.id,
    command,
    table.concat(parts, " ")
  )
  while #controlLog > CONTROL_LOG_SIZE do
    table.remove(controlLog, 1)
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

--- The group as the light model's device: its color modes and color temperature range.
--- @return table entity
function Group.entity()
  local dims, color, cct = abilities()
  local modes = {}
  if color then
    modes[#modes + 1] = ColorMode.COLOR_MODE_RGB
  end
  if cct then
    modes[#modes + 1] = ColorMode.COLOR_MODE_COLOR_TEMPERATURE
  end
  if #modes == 0 then
    modes[1] = dims and ColorMode.COLOR_MODE_BRIGHTNESS or ColorMode.COLOR_MODE_ON_OFF
  end
  table.sort(modes)
  local lo, hi = kelvinRange()
  return { supported_color_modes = modes, min_mireds = 1e6 / hi, max_mireds = 1e6 / lo }
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
  end
end

local function readState(member, value)
  -- The level says more than on or off, so the state only fills in for a light with no level yet, or turns one off.
  local text = type(value) == "string" and value:lower() or value
  local on
  if text == true or text == 1 or text == "1" or text == "true" then
    on = true
  elseif text == false or text == 0 or text == "0" or text == "false" then
    on = false
  else
    return -- Missing/undefined is not an observed off state.
  end
  if not on then
    member.level = 0
  elseif (member.level or 0) == 0 then
    local level = tofinite(C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_LEVEL))
    if level and level > 0 then
      readLevel(member, level)
    else
      -- Only a switch's valid on state establishes its full brightness.
      member.level = member.dimmable == false and 100 or nil
    end
  end
end

local function readColor(member, value)
  local x, y, mode = string.match(tostring(value or ""), "^([^,]+),([^,]+),([^,]+)$")
  x, y, mode = tonumber(x), tonumber(y), tonumber(mode)
  if not x or not y then
    return
  end
  local color = { mode = mode == COLOR_MODE_CCT and COLOR_MODE_CCT or COLOR_MODE_FULL, x = x, y = y }
  if color.mode == COLOR_MODE_CCT then
    color.kelvin = tonumber(C4:ColorXYtoCCT(x, y))
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
end

local evaluate

local function scheduleFeedback()
  local wait = math.max(FEEDBACK_DEBOUNCE_MS, busyUntil - C4:GetTime())
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
  local now = showing(member)
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
    local before = showing(member)
    readLevel(member, value)
    reported(member, before)
  end)
  RegisterVariableListener(member.id, VARIABLE.LIGHT_STATE, function(_, _, value)
    local before = showing(member)
    readState(member, value)
    reported(member, before)
  end)
  RegisterVariableListener(member.id, VARIABLE.LIGHT_COLOR, function(_, _, value)
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

local function readAll(member)
  readCapabilities(member)
  pcall(function()
    readLevel(member, C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_LEVEL))
    if member.level == nil then
      readState(member, C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_STATE))
    end
    readColor(member, C4:GetDeviceVariable(member.id, VARIABLE.LIGHT_COLOR))
  end)
end

---------------------------------------------------------------------------
-- Telling the light model
---------------------------------------------------------------------------

local function pushState()
  if #members == 0 then
    return
  end
  local state = {}
  for field, value in pairs(vstate) do
    state[field] = value
  end
  local ok, err = xpcall(function()
    light.state(Group.entity(), state)
  end, debug.traceback)
  publicationPending = not ok
  if ok then
    CancelTimer("GroupProxyRetry")
  else
    log:error("The group's state could not be told to the proxy: %s", err)
    SetTimer("GroupProxyRetry", 1000, function()
      pushState()
    end)
  end
end

local function setVColor(color)
  if color.mode == COLOR_MODE_CCT and color.kelvin and color.kelvin > 0 then
    vstate.color_mode = ColorMode.COLOR_MODE_COLOR_TEMPERATURE
    vstate.color_temperature = 1e6 / color.kelvin
  else
    local h, s = C4:ColorXYtoHSV(color.x, color.y)
    vstate.color_mode = ColorMode.COLOR_MODE_RGB
    vstate.red, vstate.green, vstate.blue = hsvToRGB(h or 0, s or 0, 100)
  end
end

--- @return { total: integer, on: integer, inSync: boolean }
function Group.status()
  local on = 0
  for _, member in ipairs(members) do
    if (member.level or 0) > 0 then
      on = on + 1
    end
  end
  return { total = #members, on = on, inSync = Aggregate.inSync(members, vLevel()) }
end

--- Reads the lights' own levels and colors into the group's state, once they have settled.
--- @param force boolean|nil Read them now, and tell the light model even if nothing differs.
evaluate = function(force)
  if #members == 0 then
    return
  end
  if not force and C4:GetTime() < busyUntil then
    scheduleFeedback()
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
  local dims, color, cct = abilities()
  local changed = force or publicationPending or not seeded
  -- A mode the group no longer has, after its lights or Light Type changed, is none.
  if
    (vstate.color_mode == ColorMode.COLOR_MODE_RGB and not color)
    or (vstate.color_mode == ColorMode.COLOR_MODE_COLOR_TEMPERATURE and not cct)
  then
    vstate.color_mode = ColorMode.COLOR_MODE_UNKNOWN
  end
  local commanded = vLevel()
  -- Ignore still reads the lights once, at start, for a level to show.
  local first = not seeded
  local tracking = settings.brightnessTracking
  if first and tracking == Aggregate.Brightness.IGNORE then
    tracking = Aggregate.Brightness.AVERAGE
  end
  local level = Aggregate.level(members, tracking, settings.trackedId, commanded)
  if first and level == nil then
    publicationPending = false
    CancelTimer("GroupProxyRetry")
    if light.isOnline() then
      light.disconnect(true)
    end
    onChange(Group.status())
    return
  end
  seeded = true
  if level and not dims and level > 0 then
    level = 100
  end
  if
    level and (level > 0) ~= (commanded > 0) or (level and math.abs(level - commanded) > Aggregate.LEVEL_TOLERANCE)
  then
    log:debug("The lights are at %d%%; the group was at %d%%", level, commanded)
    vstate.state = level > 0
    if level > 0 then
      vstate.brightness = level / 100
    end
    changed = true
  end
  if color or cct then
    local colorTracking = settings.colorTracking
    if first and colorTracking == Aggregate.Color.IGNORE then
      colorTracking = Aggregate.Color.AVERAGE
    end
    local shown = Aggregate.color(members, colorTracking, settings.trackedId)
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
    pushState()
  end
  onChange(Group.status())
end

---------------------------------------------------------------------------
-- Commanding the lights
---------------------------------------------------------------------------

local function dispatch(entry)
  record(entry.member, entry.command, entry.params)
  SendToDevice(entry.member.id, entry.command, entry.params)
end

--- Whether a command went out less than the command delay ago.
local spacing = false

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
  local entry = { member = member, command = command, params = params }
  if settings.commandDelay <= 0 then
    dispatch(entry)
    return
  end
  -- A newer command of the same kind replaces one still waiting for the same light.
  local kind = command == "SET_COLOR_TARGET" and "color" or "level"
  entry.kind = kind
  for i, waiting in ipairs(queue) do
    if waiting.member == member and waiting.kind == kind then
      queue[i] = entry
      return
    end
  end
  queue[#queue + 1] = entry
  if not spacing then
    drain()
  end
end

--- The color a command asks for, or nil.
--- @return { kelvin: number }|{ x: number, y: number }|nil
local function commandColor(cmd)
  if cmd.has_color_temperature and (cmd.color_temperature or 0) > 0 then
    return { kelvin = 1e6 / cmd.color_temperature }
  elseif cmd.has_rgb then
    local h, s = rgbToHS(cmd.red or 0, cmd.green or 0, cmd.blue or 0)
    local x, y = C4:ColorHSVtoXY(h, s, 100)
    return { x = x, y = y }
  end
end

local function sendColor(member, color, rate)
  local params
  if color.kelvin then
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
    params =
      { LIGHT_COLOR_TARGET_X = color.x, LIGHT_COLOR_TARGET_Y = color.y, LIGHT_COLOR_TARGET_MODE = COLOR_MODE_FULL }
  end
  if params then
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

--- A command from the light model, in its channel fields.
--- @param except Member|nil A light already showing what is sent.
local function send(cmd, except)
  -- The model lights a fading-on device dimly first so a change of color mode does not show. The lights fade up
  -- by themselves, and the command that follows carries the same color.
  if cmd.preOn then
    return
  end
  local rate = math.max(0, math.floor((cmd.transition_length or 0) + 0.5))
  local wasOn = vstate.state

  local level, plainOn
  if cmd.has_state and cmd.state == false then
    -- A color set while the group is off names the off again; the lights are not sent it.
    if wasOn or not (cmd.has_rgb or cmd.has_color_temperature or cmd.has_color_mode) then
      level = 0
    end
    vstate.state = false
  elseif cmd.has_brightness then
    level = math.max(1, math.min(100, math.floor((cmd.brightness or 1) * 100 + 0.5)))
    vstate.state = true
    vstate.brightness = cmd.brightness or 1
  elseif cmd.has_state and cmd.state and not (cmd.has_rgb or cmd.has_color_temperature or cmd.has_color_mode) then
    -- Also for a group that reads as on: some of its lights may be off.
    level, plainOn = 100, true
    vstate.state = true
    vstate.brightness = 1
  end

  for _, field in ipairs({ "color_mode", "color_brightness", "red", "green", "blue", "white", "color_temperature" }) do
    if cmd[field] ~= nil then
      vstate[field] = cmd[field]
    end
  end

  -- A color temperature sent without a mode moves a device that is showing a color to its white mode.
  if cmd.has_color_temperature and not cmd.has_color_mode then
    vstate.color_mode = ColorMode.COLOR_MODE_COLOR_TEMPERATURE
  end

  -- A color set while the group is off is the color it next comes on in: the model sends it again with that on,
  -- so the lights are not sent it now, when some would turn on for it.
  local color = vstate.state and commandColor(cmd) or nil
  for _, member in ipairs(members) do
    if member ~= except then
      -- A light that is off by itself while the group is on is left off: some turn on for a color.
      if color and (level or member.level ~= 0) then
        -- A light that is off takes its color at once, then fades up in it.
        sendColor(member, color, (member.level or 0) > 0 and wasOn and rate or 0)
      end
      if level then
        sendLevel(member, level, rate, plainOn)
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
  if not level and not color then
    levelBusyUntil = math.max(levelBusyUntil, settled)
  end
  busyUntil = math.max(levelBusyUntil, colorBusyUntil)
  SetTimer("GroupEcho", ECHO_MS, pushState)
  scheduleFeedback()
end

--- The group as the light model's device.
--- @return table adapter
function Group.adapter()
  return {
    send = send,
    -- Lights ramp evenly, so a stop mid-ramp finds them a like share of the way.
    curve = function(p)
      return p
    end,
    -- A level the group shows that some of its lights are not at is still sent.
    apart = function(level)
      for _, member in ipairs(members) do
        local own = Aggregate.memberLevel(member, level)
        if
          own
          and (
            (own > 0) ~= (level > 0) or (member.dimmable ~= false and math.abs(own - level) > Aggregate.LEVEL_TOLERANCE)
          )
        then
          return true
        end
      end
      return false
    end,
    capabilities = { has_extras = false, brightness_rate_max = 86400000, color_rate_max = 86400000 },
  }
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------

--- Tells the light model what the group is and shows now, after its lights or settings changed.
function Group.refresh()
  if #members == 0 then
    publicationPending = false
    CancelTimer("GroupProxyRetry")
    if light.isOnline() then
      light.disconnect()
    end
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
    readAll(member)
    now[#now + 1] = member
  end
  for _, member in pairs(kept) do
    unwatch(member)
  end
  members = now
  seeded = false
  queue = {}
  spacing = false
  CancelTimer("GroupQueue")
  Group.refresh()
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
  local cmd = { has_state = true, state = level > 0, has_transition_length = true, transition_length = 0 }
  if level > 0 and dims then
    cmd.has_brightness, cmd.brightness = true, level / 100
  elseif level > 0 then
    -- Read as a plain on.
    vstate.state = false
  end
  if colorDiffers and shown.mode == COLOR_MODE_CCT and shown.kelvin then
    cmd.has_color_temperature, cmd.color_temperature = true, 1e6 / shown.kelvin
  elseif colorDiffers then
    local h, s = C4:ColorXYtoHSV(shown.x, shown.y)
    cmd.has_rgb = true
    cmd.red, cmd.green, cmd.blue = hsvToRGB(h or 0, s or 0, 100)
    cmd.has_color_mode, cmd.color_mode = true, ColorMode.COLOR_MODE_RGB
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
  local cmd = { has_state = true, state = vstate.state, has_transition_length = true, transition_length = 0 }
  if vstate.state then
    local dims = abilities()
    if dims then
      cmd.has_brightness, cmd.brightness = true, vstate.brightness
    else
      -- Read as a plain on.
      vstate.state = false
    end
    if vstate.color_mode == ColorMode.COLOR_MODE_COLOR_TEMPERATURE then
      cmd.has_color_temperature, cmd.color_temperature = true, vstate.color_temperature
    elseif vstate.color_mode == ColorMode.COLOR_MODE_RGB then
      cmd.has_rgb, cmd.red, cmd.green, cmd.blue = true, vstate.red, vstate.green, vstate.blue
    end
  end
  send(cmd)
end

--- @param callback fun(status: { total: integer, on: integer, inSync: boolean }) Called after the lights are read.
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
      kelvin = member.color and member.color.kelvin and math.floor(member.color.kelvin + 0.5) or nil,
      x = member.color and member.color.x or nil,
      y = member.color and member.color.y or nil,
    }
  end
  local status = Group.status()
  return {
    total = status.total,
    on = status.on,
    inSync = status.inSync,
    level = vLevel(),
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
