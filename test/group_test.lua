-- Shared fixture for shipping-driver transport and lifecycle checks.
local T = require("testlib")
require("c4_shim")
local F = require("c4_fixtures")
local D = require("light_drivers")
local P = require("light_proxy_fake")
local R = require("group_rig")
local M = {}
function M.run(native, body, options)
  local clock = F.virtualClock()
  local proxy = P.install(clock)
  local xml = D.xml(D.root(), "light_group")
  D.seedProperties(xml)
  local restore = D.answerConfig(xml)
  local h = { clock = clock, proxy = proxy, lo = 1, hi = 100 }
  local ok, err = xpcall(function()
    h.device = R.rig(native, options).load(h, { on = false, level = 1, color = { kelvin = 3200 } })
    clock.run(3000)
    h.commands = {}
    body(h)
    T.eq("no timer raised", clock.errors, {})
  end, debug.traceback)
  restore()
  proxy:restore()
  clock.restore()
  T.check("the transport check completed", ok, not ok and err or nil)
end

return M
