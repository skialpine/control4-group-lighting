--- How a group reads its lights: one level and one color from many, and the color temperature each light is sent.
--- Pure functions over plain tables, apart from any Control4 call.

local Aggregate = {}

--- @enum BrightnessTracking
Aggregate.Brightness = {
  AVERAGE = "Average",
  BRIGHTEST = "Brightest",
  DIMMEST = "Dimmest",
  SELECTED = "Selected Light",
  IGNORE = "Ignore",
}

--- @enum ColorTracking
Aggregate.Color = {
  AVERAGE = "Average",
  SELECTED = "Selected Light",
  IGNORE = "Ignore",
}

--- Levels this close are one level: lights round a percent to their own steps.
Aggregate.LEVEL_TOLERANCE = 1
--- xy this close is one color.
Aggregate.XY_TOLERANCE = 0.01

--- @class MemberState
--- @field id integer
--- @field level integer|nil 0-100, nil until the light has reported.
--- @field dimmable boolean|nil False for a light that only switches.
--- @field color { mode: integer, x: number, y: number, kelvin: number|nil }|nil

--- A light's level as the group counts it. A light that only switches has no level of its own, so one that is on
--- counts as being where the group was last sent.
--- @param member MemberState
--- @param commanded integer The group's own level, 0-100.
--- @return integer|nil level
function Aggregate.memberLevel(member, commanded)
  if member.level == nil then
    return nil
  end
  if member.dimmable == false then
    return member.level > 0 and (commanded > 0 and commanded or 100) or 0
  end
  return member.level
end

--- @param members MemberState[]
--- @param id integer|nil
--- @return MemberState|nil
local function find(members, id)
  for _, member in ipairs(members) do
    if member.id == id then
      return member
    end
  end
end

--- The group's level from its lights'.
--- @param members MemberState[]
--- @param tracking BrightnessTracking
--- @param trackedId integer|nil The light Selected Light follows.
--- @param commanded integer The group's own level.
--- @return integer|nil level 0-100, or nil when no light has reported or tracking is Ignore.
function Aggregate.level(members, tracking, trackedId, commanded)
  if tracking == Aggregate.Brightness.IGNORE then
    return nil
  end
  if tracking == Aggregate.Brightness.SELECTED then
    local tracked = find(members, trackedId)
    local level = tracked and Aggregate.memberLevel(tracked, commanded)
    if level then
      return level
    end
    tracking = Aggregate.Brightness.AVERAGE
  end
  local known, sumOn, countOn, highest, lowest = 0, 0, 0, nil, nil
  for _, member in ipairs(members) do
    local level = Aggregate.memberLevel(member, commanded)
    if level then
      known = known + 1
      highest = math.max(highest or level, level)
      lowest = math.min(lowest or level, level)
      if level > 0 then
        sumOn = sumOn + level
        countOn = countOn + 1
      end
    end
  end
  if known == 0 then
    return nil
  end
  if tracking == Aggregate.Brightness.BRIGHTEST then
    return highest
  elseif tracking == Aggregate.Brightness.DIMMEST then
    return lowest
  end
  if countOn == 0 then
    return 0
  end
  return math.max(1, math.floor(sumOn / countOn + 0.5))
end

--- The group's color from its lights'. The lights that are on decide it; with none on, all do.
--- @param members MemberState[]
--- @param tracking ColorTracking
--- @param trackedId integer|nil
--- @return { mode: integer, x: number, y: number, kelvin: number|nil }|nil color
function Aggregate.color(members, tracking, trackedId)
  if tracking == Aggregate.Color.IGNORE then
    return nil
  end
  if tracking == Aggregate.Color.SELECTED then
    local tracked = find(members, trackedId)
    if tracked and tracked.color then
      return tracked.color
    end
  end
  local function collect(onlyOn)
    local colors = {}
    for _, member in ipairs(members) do
      if member.color and (not onlyOn or (member.level or 0) > 0) then
        colors[#colors + 1] = member.color
      end
    end
    return colors
  end
  local colors = collect(true)
  if #colors == 0 then
    colors = collect(false)
  end
  if #colors == 0 then
    return nil
  end
  local x, y, kelvin, allWhite = 0, 0, 0, true
  for _, color in ipairs(colors) do
    x, y = x + color.x, y + color.y
    if color.mode == 1 and color.kelvin then
      kelvin = kelvin + color.kelvin
    else
      allWhite = false
    end
  end
  return {
    mode = allWhite and 1 or 0,
    x = x / #colors,
    y = y / #colors,
    kelvin = allWhite and kelvin / #colors or nil,
  }
end

--- Whether two colors are one color.
--- @param a { mode: integer, x: number, y: number, kelvin: number|nil }|nil
--- @param b { mode: integer, x: number, y: number, kelvin: number|nil }|nil
--- @return boolean
function Aggregate.sameColor(a, b)
  if not a or not b then
    return a == b
  end
  if a.mode ~= b.mode then
    return false
  end
  if a.mode == 1 and a.kelvin and b.kelvin then
    return math.abs(a.kelvin - b.kelvin) <= math.max(50, 0.02 * a.kelvin)
  end
  return math.abs(a.x - b.x) <= Aggregate.XY_TOLERANCE and math.abs(a.y - b.y) <= Aggregate.XY_TOLERANCE
end

--- Whether every light that has reported is at one level and one color.
--- @param members MemberState[]
--- @param commanded integer
--- @return boolean
function Aggregate.inSync(members, commanded)
  local level, color
  for _, member in ipairs(members) do
    local own = Aggregate.memberLevel(member, commanded)
    if own then
      if level and math.abs(level - own) > Aggregate.LEVEL_TOLERANCE then
        return false
      end
      level = level or own
      -- A light that is off shows no color to compare.
      if own > 0 and member.color then
        if color and not Aggregate.sameColor(color, member.color) then
          return false
        end
        color = color or member.color
      end
    end
  end
  return true
end

--- The color temperature a light is sent for the group's.
--- @param kelvin number The group's color temperature.
--- @param groupMin number
--- @param groupMax number
--- @param lightMin number|nil The light's own range, when it gives one.
--- @param lightMax number|nil
--- @param scaled boolean The same position on the light's range, rather than the closest it has.
--- @return number kelvin
function Aggregate.mapKelvin(kelvin, groupMin, groupMax, lightMin, lightMax, scaled)
  if not lightMin or not lightMax or lightMax <= lightMin then
    return kelvin
  end
  if scaled and groupMax > groupMin then
    local place = math.max(0, math.min(1, (kelvin - groupMin) / (groupMax - groupMin)))
    return math.floor(lightMin + place * (lightMax - lightMin) + 0.5)
  end
  return math.max(lightMin, math.min(lightMax, kelvin))
end

return Aggregate
