--- The scene cycle: the Advanced Lighting Scenes that use the group's lights, stepped through one at a time from a
--- keypad button, programming or the Settings tab.
---
--- A driver cannot ask the controller for its scenes. The Settings tab can, through the controller's own API, so it
--- reads them whenever it is opened and hands them here, where they are kept.

require("lib.utils")
require("drivers-common-public.global.lib")

local log = require("lib.logging")
local persist = require("lib.persist")

local Cycle = {}

local SCENES_KEY = "cycle_scenes"
local CHOICE_KEY = "cycle_choice"
local POSITION_KEY = "cycle_position"

--- The step that turns the group off, when the cycle has one.
local OFF_ID = -1

--- @class CycleScene
--- @field id integer
--- @field name string
--- @field members integer[] The lights in the scene, by proxy id.
--- @field targets table<string, { level: number|nil, kelvin: number|nil, x: number|nil, y: number|nil }>|nil Where
---   the scene leaves each light, by its id as text.

--- @class CycleStep
--- @field id integer OFF_ID for the off step.
--- @field name string
--- @field off boolean|nil

local settings = {
  --- Scenes with any of the group's lights, rather than scenes with only the group's lights.
  any = true,
  skipToggle = true,
  offStep = false,
  backAndForth = false,
  --- Seconds idle after which the next step is the first; 0 for never.
  restartAfter = 0,
  --- Follow the lights: the scene they match is the current one, and none is when they match none.
  track = true,
}

--- Levels this close are one level, and color temperatures within this share.
local LEVEL_TOLERANCE = 2
local KELVIN_TOLERANCE = 0.03
local XY_TOLERANCE = 0.02
--- How long after a step the lights are left to reach it before they are compared (ms).
local SETTLE_MS = 5000
local holdUntil = 0

--- @type table<integer, true> The group's lights, and the group itself.
local lights = {}
local direction = 1
local lastAt = nil
local activate = function() end
local onChange = function() end

local function stored()
  return persist:get(SCENES_KEY) or {}
end

local function choice()
  return persist:get(CHOICE_KEY) or {}
end

--- @param scene CycleScene
--- @param names table<string, true> Every scene's name.
--- @return boolean eligible, boolean others Whether it is offered, and whether it has lights outside the group.
local function eligible(scene, names)
  local mine, others = 0, 0
  for _, id in ipairs(scene.members or {}) do
    if lights[id] then
      mine = mine + 1
    else
      others = others + 1
    end
  end
  if mine == 0 or (not settings.any and others > 0) then
    return false, others > 0
  end
  -- Composer makes a "(Toggle)" twin of a scene, which turns the scene off.
  local base = scene.name:match("^(.-) %(Toggle%)$")
  if settings.skipToggle and base and names[base] then
    return false, others > 0
  end
  return true, others > 0
end

--- The scenes the cycle may hold, in its order, each marked as included or left out by hand.
--- @return { id: integer, name: string, included: boolean, others: boolean }[]
function Cycle.catalog()
  local names = {}
  local scenes = stored().scenes or {}
  for _, scene in ipairs(scenes) do
    names[scene.name] = true
  end
  local picked = choice()
  local excluded, place = {}, {}
  for _, id in ipairs(picked.excluded or {}) do
    excluded[id] = true
  end
  for i, id in ipairs(picked.order or {}) do
    place[id] = i
  end
  local catalog = {}
  for _, scene in ipairs(scenes) do
    local ok, others = eligible(scene, names)
    if ok then
      catalog[#catalog + 1] = { id = scene.id, name = scene.name, included = not excluded[scene.id], others = others }
    end
  end
  -- Scenes placed by hand first, in that order; the rest by id, as Composer lists them.
  table.sort(catalog, function(a, b)
    local pa, pb = place[a.id], place[b.id]
    if pa and pb then
      return pa < pb
    elseif pa or pb then
      return pa ~= nil
    end
    return a.id < b.id
  end)
  return catalog
end

--- @return CycleStep[] steps What Next goes through.
function Cycle.steps()
  local steps = {}
  for _, scene in ipairs(Cycle.catalog()) do
    if scene.included then
      steps[#steps + 1] = { id = scene.id, name = scene.name }
    end
  end
  if settings.offStep and #steps > 0 then
    steps[#steps + 1] = { id = OFF_ID, name = "Off", off = true }
  end
  return steps
end

--- @return integer position 0 before the first step, or when the step it was at has gone.
local function position()
  local at = tointeger(persist:get(POSITION_KEY)) or 0
  return at <= #Cycle.steps() and at or 0
end

--- @return { position: integer, id: integer|nil, name: string, off: boolean }
function Cycle.current()
  local at = position()
  local step = Cycle.steps()[at]
  return {
    position = at,
    id = step and not step.off and step.id or nil,
    name = step and step.name or "",
    off = step and step.off or false,
  }
end

--- @param at integer
--- @param reason string
local function go(at, reason)
  local steps = Cycle.steps()
  local step = steps[at]
  if not step then
    log:debug("The scene cycle has no step %s", at)
    return
  end
  persist:set(POSITION_KEY, at)
  lastAt = C4:GetTime()
  holdUntil = lastAt + SETTLE_MS
  log:info("Scene cycle: %s (%d of %d, %s)", step.name, at, #steps, reason)
  activate(step)
  onChange(Cycle.current(), at == #steps)
end

--- @param shown table<integer, { level: number|nil, kelvin: number|nil, x: number|nil, y: number|nil }>
--- @return boolean|nil matches Whether the lights are where a scene leaves them; nil when none can be compared.
local function sceneMatches(scene, shown)
  local compared = 0
  for member, target in pairs(scene.targets or {}) do
    local light = shown[tointeger(member)]
    if light and light.level then
      if target.level then
        compared = compared + 1
        if math.abs(light.level - target.level) > LEVEL_TOLERANCE then
          return false
        end
      end
      -- A light that is off shows no color to compare.
      if light.level > 0 and target.kelvin and light.kelvin then
        compared = compared + 1
        if math.abs(light.kelvin - target.kelvin) > KELVIN_TOLERANCE * target.kelvin then
          return false
        end
      elseif light.level > 0 and target.x and target.y and light.x and light.y then
        compared = compared + 1
        if math.abs(light.x - target.x) > XY_TOLERANCE or math.abs(light.y - target.y) > XY_TOLERANCE then
          return false
        end
      end
    end
  end
  if compared == 0 then
    return nil
  end
  return true
end

--- Follows the lights: the step they match becomes the current one, without being activated, and none is current
--- when they match none.
--- @param shown table<integer, { level: number|nil, kelvin: number|nil, x: number|nil, y: number|nil }> What the
---   group and each of its lights show, by id.
function Cycle.track(shown)
  if not settings.track or C4:GetTime() < holdUntil then
    return
  end
  local byId = {}
  for _, scene in ipairs(stored().scenes or {}) do
    byId[scene.id] = scene
  end
  local function matches(step)
    if step.off then
      local any = false
      for _, light in pairs(shown) do
        if light.level then
          any = true
          if light.level > 0 then
            return false
          end
        end
      end
      return any
    end
    return byId[step.id] and sceneMatches(byId[step.id], shown)
  end
  local steps = Cycle.steps()
  local was = position()
  local now = 0
  local current = steps[was] and matches(steps[was])
  if current == true or (current == nil and steps[was] and not steps[was].off) then
    -- Still there, or a scene whose lights cannot be compared: left as it is.
    now = was
  else
    for at, step in ipairs(steps) do
      if matches(step) == true then
        now = at
        break
      end
    end
  end
  if now ~= was then
    log:debug("Scene cycle: the lights now match %s", steps[now] and steps[now].name or "no scene")
    persist:set(POSITION_KEY, now)
    onChange(Cycle.current(), false)
  end
end

--- Forgets where the cycle is, so the next step is the first.
function Cycle.restart()
  persist:set(POSITION_KEY, 0)
  direction = 1
  lastAt = nil
  onChange(Cycle.current(), false)
end

function Cycle.next()
  local count = #Cycle.steps()
  if count == 0 then
    log:info("The scene cycle has no scenes: open the Settings tab to read them")
    return
  end
  local at = position()
  if settings.restartAfter > 0 and lastAt and C4:GetTime() - lastAt > settings.restartAfter * 1000 then
    at, direction = 0, 1
  end
  if settings.backAndForth and count > 1 then
    if at + direction > count then
      direction = -1
    elseif at + direction < 1 then
      direction = 1
    end
    at = at + direction
  else
    at = at % count + 1
  end
  go(at, "next")
end

function Cycle.previous()
  local count = #Cycle.steps()
  if count == 0 then
    return
  end
  go((position() - 2) % count + 1, "previous")
end

--- @param scene integer|string A scene's id or name, or "Off".
function Cycle.goTo(scene)
  for at, step in ipairs(Cycle.steps()) do
    if step.id == tointeger(scene) or step.name == scene then
      go(at, "chosen")
      return
    end
  end
  log:warn("The scene cycle has no scene %s", scene)
end

--- The scenes the Settings tab read from the controller.
--- @param scenes CycleScene[]
--- @param agentId integer|nil The Advanced Lighting agent.
function Cycle.setScenes(scenes, agentId)
  local kept = {}
  for _, scene in ipairs(scenes or {}) do
    local id = tointeger(scene.id)
    if id and type(scene.name) == "string" then
      local members = {}
      for _, member in ipairs(scene.members or {}) do
        members[#members + 1] = tointeger(member)
      end
      local targets = {}
      for member, target in pairs(type(scene.targets) == "table" and scene.targets or {}) do
        if tointeger(member) and type(target) == "table" then
          targets[tostring(tointeger(member))] = {
            level = tonumber(target.level),
            kelvin = tonumber(target.kelvin),
            x = tonumber(target.x),
            y = tonumber(target.y),
          }
        end
      end
      kept[#kept + 1] = { id = id, name = scene.name, members = members, targets = targets }
    end
  end
  persist:set(SCENES_KEY, { scenes = kept, agentId = tointeger(agentId), read = os.time() })
  onChange(Cycle.current(), false)
end

--- The order and the scenes left out, as set by hand.
--- @param order integer[]
--- @param excluded integer[]
function Cycle.setChoice(order, excluded)
  local function ids(list)
    local out = {}
    for _, id in ipairs(list or {}) do
      out[#out + 1] = tointeger(id)
    end
    return out
  end
  -- The step it was at keeps its place if it is still a step.
  local was = Cycle.current()
  persist:set(CHOICE_KEY, { order = ids(order), excluded = ids(excluded) })
  local at = 0
  for i, step in ipairs(Cycle.steps()) do
    if (was.off and step.off) or (was.id and step.id == was.id) then
      at = i
    end
  end
  persist:set(POSITION_KEY, at)
  onChange(Cycle.current(), false)
end

--- @param ids table<integer, true> The group's lights, and the group itself.
function Cycle.setLights(ids)
  lights = ids
end

--- @param changes table Only the settings named change.
function Cycle.configure(changes)
  for key, value in pairs(changes) do
    settings[key] = value
  end
end

--- @return integer|nil agentId The Advanced Lighting agent the Settings tab found.
function Cycle.agentId()
  return stored().agentId
end

--- @return integer|nil read When the scenes were last read (os.time).
function Cycle.readAt()
  return stored().read
end

--- @return integer count Every scene read, in the cycle or not.
function Cycle.known()
  return #(stored().scenes or {})
end

--- @param fn fun(step: CycleStep) Activates a step.
function Cycle.onActivate(fn)
  activate = fn
end

--- @param fn fun(current: table, atEnd: boolean) Called after the cycle moves or changes.
function Cycle.onChange(fn)
  onChange = fn
end

return Cycle
