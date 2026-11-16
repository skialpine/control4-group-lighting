-- Both transports load the shipping driver and simulate only its member lights.
local Rig = require("light_rig")
local Group = require("group_rig")
return { version = Rig.VERSION, rigs = { light_group = { Group.rig(false), Group.rig(true) } } }
