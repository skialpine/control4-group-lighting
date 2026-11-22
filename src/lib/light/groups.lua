--- The groups the light belongs to: Control4 load groups, from JOIN_GROUP, LEAVE_GROUP and SET_GROUP_SYNC, and
--- group drivers built on lib.light.group, from LIGHT_GROUP_JOIN and LIGHT_GROUP_LEAVE.
---
--- A load group in sync takes the light's own on, off, toggle, level and button commands: the light hands each to
--- every group it keeps in sync with and does not act on it, and the group then moves all its members. The group's
--- own commands are never handed back. A group driver is told what the light shows whenever it changes, so it can
--- show its members' state. Membership is kept through lib.persist, since a group tells it only when its members
--- change.

local log = require("lib.logging")
local persist = require("lib.persist")

require("lib.utils")

local P_GROUPS = "load_groups"
local P_DRIVERS = "light_groups"
local CONFIRM_MISSING_MS = 1000

--- What the light tells a group driver: its facts and what its proxy shows, at the end of any change.
--- @class LightMemberState
--- @field online boolean
--- @field dims boolean
--- @field hasColor boolean
--- @field cct LightCctRange|nil
--- @field on boolean
--- @field level integer C4 level 0-100.
--- @field color LightColor|nil

--- @class LightGroups
--- @field told table<string, string> What each group driver was last told, by group id, as its params' text.
--- @field missing table<string, table<string, number>> When each membership was first missing from the project.
local Groups = {}
Groups.__index = Groups

Groups.P_GROUPS = P_GROUPS
Groups.P_DRIVERS = P_DRIVERS

--- @return LightGroups
function Groups.new()
  return setmetatable({ told = {}, missing = { [P_GROUPS] = {}, [P_DRIVERS] = {} } }, Groups)
end

local function listed(devices, id)
  return devices[id] or devices[tostring(id)]
end

--- Ignore group IDs absent from a healthy project lookup. Two observations spaced apart confirm removal.
--- @private
function Groups:_registered(key, groups)
  if next(groups) == nil then
    return groups
  end
  -- Include this light so an empty or incomplete startup registry cannot erase memberships.
  local me = C4:GetDeviceID()
  local ids = { tostring(me) }
  for groupId in pairs(groups) do
    if tointeger(groupId) then
      ids[#ids + 1] = tostring(groupId)
    end
  end
  local ok, devices = pcall(C4.GetDevices, C4, { DeviceIds = table.concat(ids, ",") })
  if not ok or type(devices) ~= "table" or not listed(devices, me) then
    self.missing[key] = {}
    return groups
  end
  local now, missing = C4:GetTime(), self.missing[key]
  local available = {}
  local changed = false
  for groupId, member in pairs(groups) do
    if listed(devices, tointeger(groupId) or groupId) then
      missing[groupId] = nil
      available[groupId] = member
    else
      local since = missing[groupId]
      if since and now - since >= CONFIRM_MISSING_MS then
        groups[groupId], missing[groupId] = nil, nil
        changed = true
      elseif not since then
        missing[groupId] = now
      end
      if key == P_DRIVERS then
        self.told[groupId] = nil
      end
    end
  end
  if changed then
    persist:set(key, groups)
  end
  return available
end

--- The groups by id, each with whether it keeps the light in sync.
--- @return table<string, boolean>
function Groups:all()
  return persist:get(P_GROUPS, {})
end

--- Join a group, or change whether it keeps the light in sync.
--- @param groupId integer
--- @param keepSync boolean
function Groups:join(groupId, keepSync)
  local groups = self:all()
  local id = tostring(groupId)
  self.missing[P_GROUPS][id] = nil
  groups[id] = keepSync
  persist:set(P_GROUPS, groups)
end

--- Leave a group.
--- @param groupId integer
function Groups:leave(groupId)
  local groups = self:all()
  local id = tostring(groupId)
  self.missing[P_GROUPS][id] = nil
  if groups[id] == nil then
    return
  end
  groups[id] = nil
  persist:set(P_GROUPS, groups)
end

--- The groups that keep the light in sync, in id order.
--- @return integer[]
function Groups:synced()
  local ids = {}
  for id, keepSync in pairs(self:_registered(P_GROUPS, self:all())) do
    local n = tointeger(id)
    if keepSync and n then
      ids[#ids + 1] = n
    end
  end
  table.sort(ids)
  return ids
end

--- Hand a command to every group in sync. Returns whether any took it, in which case the light does not act.
--- @param strCommand string
--- @param tParams table<string, string>
--- @return boolean
function Groups:forward(strCommand, tParams)
  local ids = self:synced()
  for _, id in ipairs(ids) do
    log:debug("%s handed to load group %d, which keeps the light in sync", strCommand, id)
    C4:SendToDevice(id, strCommand, tParams)
  end
  return #ids > 0
end

-----------------------------------------------------------------------------------------------------
-- Group drivers
-----------------------------------------------------------------------------------------------------

--- The group drivers the light is a member of: the id each knows the light by, by group id.
--- @return table<string, string>
function Groups:drivers()
  return persist:get(P_DRIVERS, {})
end

--- Join a group driver, which knows the light as `memberId`. It is told the light's state at once.
--- @param groupId integer
--- @param memberId string
function Groups:enroll(groupId, memberId)
  local drivers = self:drivers()
  local id = tostring(groupId)
  self.missing[P_DRIVERS][id] = nil
  drivers[id] = memberId
  persist:set(P_DRIVERS, drivers)
  self.told[id] = nil
end

--- Leave a group driver.
--- @param groupId integer
function Groups:withdraw(groupId)
  local drivers = self:drivers()
  local id = tostring(groupId)
  self.missing[P_DRIVERS][id] = nil
  if drivers[id] == nil then
    return
  end
  drivers[id] = nil
  persist:set(P_DRIVERS, drivers)
  self.told[id] = nil
end

--- @param n number|nil
--- @return string|nil
local function fixed(n)
  return n ~= nil and string.format("%.4f", n) or nil
end

--- Tell each group driver the light's state, where it differs from what that group was last told.
--- @param state LightMemberState
function Groups:tell(state)
  local color = state.color
  local params = {
    ONLINE = tostring(state.online),
    DIMS = tostring(state.dims),
    HAS_COLOR = tostring(state.hasColor),
    CCT_MIN = state.cct and tostring(state.cct.minK) or nil,
    CCT_MAX = state.cct and tostring(state.cct.maxK) or nil,
    ON = tostring(state.on),
    LEVEL = tostring(state.level),
    X = color and fixed(color.x) or nil,
    Y = color and fixed(color.y) or nil,
    MODE = color and color.mode or nil,
    KELVIN = color and color.kelvin and tostring(color.kelvin) or nil,
  }
  local keys = {}
  for k in pairs(params) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. params[k]
  end
  local text = table.concat(parts, ";")
  local drivers = self:drivers()
  local hasUpdates = false
  for groupId in pairs(drivers) do
    if self.told[groupId] ~= text then
      hasUpdates = true
      break
    end
  end
  if not hasUpdates then
    return
  end
  for groupId, memberId in pairs(self:_registered(P_DRIVERS, drivers)) do
    local id = tointeger(groupId)
    if id and self.told[groupId] ~= text then
      self.told[groupId] = text
      local sent = { MEMBER_ID = memberId }
      for k, v in pairs(params) do
        sent[k] = v
      end
      C4:SendToDevice(id, "LIGHT_GROUP_STATE", sent)
    end
  end
end

return Groups
