#!/bin/sh
DATA_FILE="/www/fan_data.json"
uci set fanctrl.fanctrl.mode='2'
uci commit fanctrl

while true; do
    CPU_T=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%d",$1/1000}')
    MOD_T=$(cpetools.sh -c temp 2>/dev/null | tr -d '\n\r ')
    PWM_V=$(cat /sys/devices/platform/pwm-fan/hwmon/hwmon0/pwm1 2>/dev/null)
    UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    FAN_P=0
    [ -n "$PWM_V" ] && FAN_P=$(awk "BEGIN {print ($PWM_V/255)*100}")
    [ -n "$UPTIME_S" ] || UPTIME_S=0

    echo "{\"cpu\":\"$CPU_T\",\"model\":\"$MOD_T\",\"fan\":\"$FAN_P\",\"uptime\":\"$UPTIME_S\"}" > "$DATA_FILE"

    NEW_SPEED=10
    if [ "$CPU_T" -ge 66 ]; then
        NEW_SPEED=50
    elif [ "$CPU_T" -ge 35 ]; then
        NEW_SPEED=30
    else
        NEW_SPEED=10
    fi

    CUR_CONF_SPEED=$(uci -q get fanctrl.fanctrl.fanspeed)
    if [ "$CUR_CONF_SPEED" != "$NEW_SPEED" ]; then
        logger -t fan_commander "Temp:$CPU_T C, Target Speed:$NEW_SPEED %"
        uci set fanctrl.fanctrl.fanspeed="$NEW_SPEED"
        uci commit fanctrl
        /etc/init.d/fanctrl restart 2>/dev/null
    fi
    sleep 5
done
