-- The shipping driver over two simulated Light V2 members. The transport can be generic, or answer the
-- template protocol handshake. The clock models physical fades, not just their target acknowledgements.
local D = require("light_drivers")
local F = require("c4_fixtures")
local Light = require("lib.light")
local P = require("light_proxy_fake")

local CAPS = "<DynamicCapabilities><dimmer>True</dimmer><supports_color>True</supports_color>"
  .. "<supports_color_correlated_temperature>True</supports_color_correlated_temperature>"
  .. "<color_correlated_temperature_min>2000</color_correlated_temperature_min>"
  .. "<color_correlated_temperature_max>6500</color_correlated_temperature_max></DynamicCapabilities>"
local M = {}

local function still(value)
  return { from = value, to = value, at = 0, ms = 0 }
end
local function at(f, now)
  local p = f.ms > 0 and math.min(1, (now - f.at) / f.ms) or 1
  return f.from + (f.to - f.from) * p
end
local function fade(f, target, now, ms)
  f.from, f.to, f.at, f.ms = at(f, now), target, now, ms
end

function M.rig(native, options)
  options = options or {}
  local rig = {
    name = native and "Combined member transport" or "Universal Light V2 transport",
    folder = "light_group",
    settleMs = 2500,
  }
  function rig.load(h, initial)
    package.loaded["group.group"], package.loaded["group.cycle"] = nil, nil
    local members, devices = {}, {}
    local me = C4:GetDeviceID()
    devices[me] = { deviceName = "Group", proxies = { [P.PROXY_DEVICE] = {} } }
    devices[P.PROXY_DEVICE] =
      { deviceName = "Group", driverFileName = "light_v2.c4i", protocol = { [me] = {} }, variables = h.proxy.vars }
    for _, id in ipairs({ 801, 802 }) do
      local color = initial and initial.color or { x = 0.3127, y = 0.329, mode = "xy" }
      local x, y, mode = color.x, color.y, color.mode or "xy"
      if color.kelvin and not x then
        x, y, mode = C4:ColorCCTtoXY(color.kelvin)
        mode = "cct"
      end
      local level = initial and initial.on and (initial.level or 1) or 0
      local member =
        { id = id, level = still(level), x = still(x), y = still(y), mode = mode, online = true, generation = 0 }
      members[#members + 1] = member
      devices[id + 1000] = { deviceName = "Protocol " .. id, proxies = { [id] = {} } }
      devices[id] = {
        deviceName = "Member " .. id,
        driverFileName = "light_v2.c4i",
        protocol = { [id + 1000] = {} },
        variables = {
          ["1000"] = { value = level > 0 and "1" or "0" },
          ["1001"] = { value = tostring(level * 100) },
          ["1200"] = { value = x .. "," .. y .. "," .. (mode == "cct" and "1" or "0") },
          ["6661"] = { value = CAPS },
        },
      }
      if options.unknown then
        devices[id].variables["1000"], devices[id].variables["1001"] = nil, nil
      end
    end
    ShimSetDevices(devices)
    local function state(member, target)
      local now = h.clock.now()
      local level = target and member.level.to or at(member.level, now)
      local x, y = target and member.x.to or at(member.x, now), target and member.y.to or at(member.y, now)
      return {
        on = level > 0,
        level = level,
        color = {
          x = x,
          y = y,
          mode = member.mode,
          kelvin = member.mode == "cct" and C4:ColorXYtoCCT(x, y) or nil,
        },
      }
    end
    local function tell(member, target)
      local s = state(member, target)
      local vars = devices[member.id].variables
      local changes = {
        [1000] = s.on and "1" or "0",
        [1001] = tostring(math.floor(s.level * 100 + 0.5)),
        [1200] = s.color.x .. "," .. s.color.y .. "," .. (s.color.mode == "cct" and "1" or "0"),
      }
      for variable, value in pairs(changes) do
        vars[tostring(variable)] = { value = value }
        OnWatchedVariableChanged(member.id, variable, value)
      end
      if native then
        ExecuteCommand("LIGHT_GROUP_STATE", {
          MEMBER_ID = tostring(member.id),
          ONLINE = tostring(member.online),
          ON = member.online and tostring(s.on) or "false",
          LEVEL = member.online and changes[1001] or "0",
          X = member.online and tostring(s.color.x) or nil,
          Y = member.online and tostring(s.color.y) or nil,
          MODE = member.online and s.color.mode or nil,
          KELVIN = member.online and s.color.kelvin and tostring(s.color.kelvin) or nil,
          DIMS = "true",
          HAS_COLOR = "true",
          CCT_MIN = "2000",
          CCT_MAX = "6500",
        })
      end
    end
    local sent, sendUI, restoreClock = C4.SendToDevice, C4.SendDataToUI, h.clock.restore
    local updateProperty = C4.UpdateProperty
    function C4:UpdateProperty(name, value)
      Properties[name] = value
    end
    C4.SendDataToUI = function() end
    h.commands = {}
    C4.SendToDevice = function(c4, id, command, params, ...)
      local member
      for _, candidate in ipairs(members) do
        if candidate.id == tonumber(id) or candidate.id + 1000 == tonumber(id) then
          member = candidate
        end
      end
      if not member then
        return sent(c4, id, command, params, ...)
      end
      if not member.online then
        return
      end
      params = params or {}
      h.commands[#h.commands + 1] = { at = h.clock.now(), id = id, command = command, params = params }
      if command == "LIGHT_GROUP_JOIN" then
        assert(tonumber(id) == member.id + 1000, "native join must target the protocol driver")
        if native then
          tell(member, false)
        end
        return
      end
      if command == "LIGHT_GROUP_LEAVE" then
        return
      end
      local now, ms = h.clock.now(), tonumber(params.TIME or params.RATE) or 0
      local level, color
      if command == "RAMP_TO_LEVEL" then
        level = tonumber(params.LEVEL) / 100
      elseif command == "ON" then
        level = 1
      elseif command == "OFF" then
        level = 0
      elseif command == "SET_COLOR_TARGET" then
        color = {
          x = tonumber(params.LIGHT_COLOR_TARGET_X),
          y = tonumber(params.LIGHT_COLOR_TARGET_Y),
          mode = tonumber(params.LIGHT_COLOR_TARGET_MODE) == 1 and "cct" or "xy",
          kelvin = tonumber(params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE),
        }
      elseif command == "LIGHT_GROUP_COMMAND" then
        assert(tonumber(id) == member.id + 1000, "native command must target the protocol driver")
        if params.KIND == "off" then
          level = 0
        elseif params.KIND == "level" then
          level = tonumber(params.LEVEL) / 100
        end
        if params.X then
          color =
            { x = tonumber(params.X), y = tonumber(params.Y), mode = params.MODE, kelvin = tonumber(params.KELVIN) }
        end
      end
      if level ~= nil then
        fade(member.level, level, now, ms)
      end
      if color then
        local x, y = color.x, color.y
        if color.mode == "cct" and color.kelvin then
          x, y = C4:ColorCCTtoXY(color.kelvin)
        end
        member.mode = color.mode
        fade(member.x, x, now, ms)
        fade(member.y, y, now, ms)
      end
      tell(member, true)
      h.clock.at(ms + 1, function()
        tell(member, false)
      end)
    end
    h.clock.restore = function()
      C4.SendToDevice, C4.SendDataToUI = sent, sendUI
      C4.UpdateProperty = updateProperty
      restoreClock()
    end
    F.dofileBuild(D.path(D.root(), rig.folder), "oss")
    h.light = Light.made[#Light.made]
    Properties["Lights"], Properties["Log Mode"] = "801,802", "Off"
    OnDriverInit()
    OnDriverLateInit()
    h.reload = function()
      OnDriverDestroyed()
      package.loaded["group.group"], package.loaded["group.cycle"] = nil, nil
      F.dofileBuild(D.path(D.root(), rig.folder), "oss")
      h.light = Light.made[#Light.made]
      OnDriverInit()
      OnDriverLateInit()
    end
    return {
      state = function()
        return state(members[1], false)
      end,
      set = function(change)
        for _, member in ipairs(members) do
          if change.level then
            member.level = still(change.level)
          end
          if change.on == false then
            member.level = still(0)
          elseif change.on and at(member.level, h.clock.now()) <= 0 then
            member.level = still(1)
          end
          if change.color then
            local color = change.color
            local x, y = color.x, color.y
            if color.kelvin and not x then
              x, y = C4:ColorCCTtoXY(color.kelvin)
            end
            member.x, member.y = still(x), still(y)
            member.mode = color.mode or (color.kelvin and "cct" or "xy")
          end
          tell(member, false)
        end
      end,
      drop = function()
        if native then
          for _, member in ipairs(members) do
            member.online = false
            tell(member, false)
          end
        else
          h.light:lost()
        end
      end,
      back = function()
        for _, member in ipairs(members) do
          member.online = true
          tell(member, false)
        end
        require("group.group").refresh()
      end,
      suspend = function()
        h.light:lost()
      end,
      resume = function()
        require("group.group").refresh()
      end,
    }
  end
  rig.reload = function(h)
    return h.reload()
  end
  return rig
end
return M
