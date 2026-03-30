module("luci.controller.fanctrl_status", package.seeall)
function index()
    entry({"admin", "status", "fanctrl"}, template("fanctrl/status"), _("风扇实时状态"), 10).dependent = true
end
