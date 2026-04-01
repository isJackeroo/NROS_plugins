module("luci.controller.fanctrl_status", package.seeall)
function index()
    entry({"admin", "status", "fanctrl"}, template("fanctrl/status"), _("风扇实时状态"), 10).dependent = true
    entry({"admin", "status", "fanctrl_set"}, call("set_fan")).leaf = true
end

function set_fan()
    local speed = tonumber(luci.http.formvalue("speed"))
    local mode = luci.http.formvalue("mode")

    if mode == "0" or mode == "1" then
        luci.sys.call("uci set fanctrl.fanctrl.manual_mode='" .. mode .. "' && uci commit fanctrl")
    end

    if speed then
        local clamped = math.max(0, math.min(100, speed))
        luci.sys.call("uci set fanctrl.fanctrl.mode='2' && uci set fanctrl.fanctrl.fanspeed='" .. clamped .. "' && uci commit fanctrl && /etc/init.d/fanctrl restart >/dev/null 2>&1")
    end

    luci.http.prepare_content("application/json")
    luci.http.write('{"status":"ok"}')
end
