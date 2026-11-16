-- Several shipping driver instances in separate Lua environments, sharing one Director-like device registry
-- and clock. SDK persistence is retained per instance across a real module reload; wire events reach all groups.
local F = require("c4_fixtures")
local D = require("light_drivers")
local M = {}
local root = D.root()
local realLoad, realLoadfile = load, loadfile
local path = package.path

local function sandbox()
  local env = {}
  for name in
    ("_VERSION assert collectgarbage coroutine debug error getfenv getmetatable ipairs io jit math module newproxy next os pairs pcall print rawequal rawget rawset select setfenv setmetatable string table tonumber tostring type unpack xpcall"):gmatch(
      "%S+"
    )
  do
    env[name] = _G[name]
  end
  env._G = env
  env.package = {}
  for key, value in pairs(package) do
    env.package[key] = value
  end
  env.package.loaded = {}
  env.load = function(source, name)
    local fn, err = realLoad(source, name)
    if fn then
      setfenv(fn, env)
    end
    return fn, err
  end
  env.loadstring = env.load
  env.require = function(name)
    local loaded = env.package.loaded
    if loaded[name] ~= nil then
      return loaded[name]
    end
    local file = package.searchpath(name, path)
    if not file then
      return require(name)
    end -- native modules (ffi, bit, socket)
    loaded[name] = true
    local fn = assert(realLoadfile(file))
    setfenv(fn, env)
    local result = fn(name)
    if result ~= nil then
      loaded[name] = result
    end
    return loaded[name]
  end
  return env
end

function M.new()
  local clock = F.virtualClock()
  local project = { clock = clock, scopes = {}, devices = {}, members = {}, commands = {} }
  local timer = C4.SetTimer
  local CAPS = "<DynamicCapabilities><dimmer>True</dimmer><supports_color_correlated_temperature>True</supports_color_correlated_temperature>"
    .. "<color_correlated_temperature_min>2000</color_correlated_temperature_min><color_correlated_temperature_max>6500</color_correlated_temperature_max></DynamicCapabilities>"

  function project:member(id, native)
    local x, y = C4:ColorCCTtoXY(3200)
    self.members[id] = { id = id, native = native, joined = {}, level = 0, x = x, y = y }
    self.devices[id] = {
      deviceName = "Member " .. id,
      driverFileName = "light_v2.c4i",
      protocol = { [id + 1000] = {} },
      variables = {
        ["1000"] = { value = "0" },
        ["1001"] = { value = "0" },
        ["1200"] = { value = x .. "," .. y .. ",1" },
        ["6661"] = { value = CAPS },
      },
    }
    self.devices[id + 1000] = { deviceName = "Protocol " .. id, proxies = { [id] = {} } }
  end

  local function publish(member)
    local values = {
      [1000] = member.level > 0 and "1" or "0",
      [1001] = tostring(member.level),
      [1200] = member.x .. "," .. member.y .. ",1",
    }
    for variable, value in pairs(values) do
      project.devices[member.id].variables[tostring(variable)] = { value = value }
      for _, scope in pairs(project.scopes) do
        scope.env.OnWatchedVariableChanged(member.id, variable, value)
      end
    end
    for group, memberId in pairs(member.joined) do
      local scope = project.scopes[group]
      if scope then
        scope.env.ExecuteCommand("LIGHT_GROUP_STATE", {
          MEMBER_ID = memberId,
          ONLINE = "true",
          ON = values[1000],
          LEVEL = values[1001],
          X = tostring(member.x),
          Y = tostring(member.y),
          MODE = "cct",
        })
      end
    end
  end

  function project:send(from, destination, command, params)
    self.commands[#self.commands + 1] =
      { from = from, id = destination, command = command, params = params, at = clock.now() }
    local member = self.members[tonumber(destination)] or self.members[tonumber(destination) - 1000]
    if not member then
      return
    end
    if command == "LIGHT_GROUP_JOIN" then
      if member.native then
        member.joined[tonumber(params.GROUP_ID)] = params.MEMBER_ID
        publish(member)
      end
      return
    elseif command == "LIGHT_GROUP_LEAVE" then
      member.joined[tonumber(params.GROUP_ID)] = nil
      return
    elseif command == "RAMP_TO_LEVEL" then
      member.level = tonumber(params.LEVEL)
    elseif command == "OFF" then
      member.level = 0
    elseif command == "ON" then
      member.level = 100
    elseif command == "SET_COLOR_TARGET" then
      member.x, member.y = C4:ColorCCTtoXY(tonumber(params.LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE))
    elseif command == "LIGHT_GROUP_COMMAND" then
      if params.KIND == "off" then
        member.level = 0
      elseif params.KIND == "level" then
        member.level = tonumber(params.LEVEL)
      end
      if params.X then
        member.x, member.y = tonumber(params.X), tonumber(params.Y)
      end
    end
    publish(member)
  end

  function project:load(id, members)
    local prior = self.scopes[id]
    if prior then
      prior.env.OnDriverDestroyed()
      prior.persist.land()
    end
    local env = sandbox()
    env.require("c4_shim")
    env.C4.GetDeviceID = function()
      return id
    end
    env.ON_TIMER_ERROR = function(name, err)
      clock.errors[#clock.errors + 1] = tostring(id) .. ": " .. tostring(name) .. ": " .. tostring(err)
    end
    env.ON_UNHANDLED_REJECTION = function(err)
      clock.errors[#clock.errors + 1] = tostring(id) .. ": " .. tostring(err)
    end
    env.ShimSetClock(clock.now)
    env.C4.SetTimer = timer
    env.C4.SendDataToUI = function() end
    env.C4.SendToDevice = function(_, destination, command, params)
      return project:send(id, destination, command, params or {})
    end
    local persist = prior and prior.persist
      or {
        get = env.C4.PersistGetValue,
        set = env.C4.PersistSetValue,
        delete = env.C4.PersistDeleteValue,
        land = env.ShimPersistLand,
      }
    env.C4.PersistGetValue, env.C4.PersistSetValue, env.C4.PersistDeleteValue = persist.get, persist.set, persist.delete
    local P = env.require("light_proxy_fake")
    P.PROXY_DEVICE = id + 100
    local variables = {}
    if prior then
      for variable, entry in pairs(prior.proxy.vars) do
        variables[variable] = entry.value
      end
    end
    local proxy = P.install(clock, { variables = variables })
    self.devices[id] = { deviceName = "Group " .. id, proxies = { [id + 100] = {} } }
    self.devices[id + 100] = {
      deviceName = "Group " .. id,
      driverFileName = "light_v2.c4i",
      protocol = { [id] = {} },
      variables = proxy.vars,
    }
    env.ShimSetDevices(self.devices)
    local config = env.require("light_drivers")
    config.answerConfig(config.xml(root, "light_group"))
    config.seedProperties(config.xml(root, "light_group"))
    if prior then
      for key, value in pairs(prior.env.Properties) do
        env.Properties[key] = value
      end
    end
    if not prior then
      env.Properties["Lights"] = table.concat(members, ",")
    end
    env.Properties["Log Mode"] = "Off"
    local scope = { env = env, proxy = proxy, persist = persist, members = members }
    self.scopes[id] = scope
    env.require("c4_fixtures").dofileBuild(root .. "/drivers/light_group/driver.lua", "oss")
    scope.light = env.require("lib.light").made[1]
    env.OnDriverInit()
    env.OnDriverLateInit()
    return scope
  end

  function project:done()
    for _, scope in pairs(self.scopes) do
      scope.env.OnDriverDestroyed()
    end
    clock.restore()
  end
  return project
end
return M
