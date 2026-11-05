#!/usr/bin/env bash
#
# probe.sh - 用 raw 接口探测 MIFS 协议的实际布局
#
#   ./probe.sh          只读探测，不改变任何状态（默认）
#   ./probe.sh --sweep  扫描固件支持哪些 MIFS 命令
#   ./probe.sh --write  写入测试（先设 quiet=2 验证，再还原 balanced=1）
#
set -u

DEV="/sys/class/redmi_perf/redmi_perf"
RAW="$DEV/raw"

if [[ ! -e "$RAW" ]]; then
	echo "错误: 找不到 $RAW，模块没加载？先跑 ./install.sh --dkms" >&2
	exit 1
fi

send() {
	printf '%s' "$1" | sudo tee "$RAW" >/dev/null
	cat "$RAW"
}

show() {
	local name="$1" hex="$2" out
	out="$(send "$hex")"
	echo "--- $name"
	echo "    in : $hex"
	echo "    out: $out"
}

gpu_power() {
	nvidia-smi -q -d POWER 2>/dev/null |
		grep -iE "Current Power Limit|Max Power Limit" |
		head -2 | sed 's/^/    /'
}

echo "=== 只读探测（不改变任何状态）==="
echo
show "GET cmd 0x08（基线）" "00 fa 00 08 00"
show "GET cmd 0x08（重复，验证稳定性）" "00 fa 00 08 00"
show "GET cmd 0x08，InData[5..8] 填 aa bb cc dd（看是否回显）" \
	"00 fa 00 08 00 aa bb cc dd"
show "GET cmd 0x13（PSU 类型）" "00 fa 00 13 00"
show "GET cmd 0x00（对照：未知命令）" "00 fa 00 00 00"
show "GET cmd 0x01（对照）" "00 fa 00 01 00"
show "GET cmd 0x07（对照）" "00 fa 00 07 00"
show "GET cmd 0x09（对照）" "00 fa 00 09 00"

case "${1:-}" in
--sweep)
	echo
	echo "=== 命令扫描（0x00 .. 0x1f，找固件支持哪些）==="
	echo
	for i in $(seq 0 31); do
		cmd="$(printf '%02x' "$i")"
		out="$(send "00 fa 00 $cmd 00")"
		if [[ "$out" == *"80 00 $cmd"* ]]; then
			echo "  cmd 0x$cmd  支持   out: $out"
		else
			echo "  cmd 0x$cmd  不支持"
		fi
	done
	;;
--write)
	echo
	echo "=== 写入探测（会改模式，最后还原成 balanced）==="
	echo
	echo "--- 写入前 GPU 功耗上限"
	gpu_power
	echo
	show "SET cmd 0x08 value=2（quiet，安全方向）" "00 fb 00 08 02"
	show "GET cmd 0x08（确认写入生效）" "00 fa 00 08 00"
	echo "--- 写入后 GPU 功耗上限"
	gpu_power
	echo
	show "SET cmd 0x08 value=1（balanced，还原）" "00 fb 00 08 01"
	show "GET cmd 0x08（确认已还原）" "00 fa 00 08 00"
	;;
esac

echo
echo "提示: 之后用 redmi-perf get / redmi-perf psu 看高层接口"
