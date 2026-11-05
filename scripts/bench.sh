#!/usr/bin/env bash
#
# bench.sh - 测量不同性能模式下的 GPU 实际功耗
#
# 用法:
#   ./bench.sh                 # 测 quiet / balanced / turbo / full-speed
#   ./bench.sh quiet turbo     # 只测指定模式
#
# nvidia-smi 报的 "Current Power Limit" 是驱动从 SBIOS 静态表读到的固定值，
# 不随 EC 变化，所以只能看实际功耗/频率/温度。
#
# 关键：负载方式只挑一次，全程用同一种，否则各模式之间没法比。
#
set -u

MODES="${*:-quiet balanced turbo full-speed}"
SAMPLES=12
LOAD_PID=""
LOAD_CMD=()
LOAD_KIND=""

cleanup() {
	stop_load
}
trap cleanup EXIT INT TERM

stop_load() {
	if [[ -n "$LOAD_PID" ]]; then
		kill "$LOAD_PID" 2>/dev/null
		wait "$LOAD_PID" 2>/dev/null
		LOAD_PID=""
	fi
}

gpu_util() {
	nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
		head -1 | tr -d ' '
}

# 找到 nvidia-smi 能认的字段组合（不同驱动支持的字段不一样）
pick_query() {
	local candidates=(
		"power.draw,clocks.sm,clocks.mem,temperature.gpu,utilization.gpu"
		"power.draw,clocks.sm,temperature.gpu,utilization.gpu"
		"power.draw,temperature.gpu,utilization.gpu"
		"utilization.gpu"
	)
	local q
	for q in "${candidates[@]}"; do
		if nvidia-smi --query-gpu="$q" --format=csv,noheader >/dev/null 2>&1; then
			echo "$q"
			return 0
		fi
	done
	return 1
}

start_load() {
	case "$1" in
	vkcube)
		VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json \
		__NV_PRIME_RENDER_OFFLOAD=1 __NV_PRIME_OUTPUT=1 \
			vkcube --c 1000000 --wsi wayland >/tmp/vkcube-bench.log 2>&1 &
		;;
	glxgears)
		__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
		__NV_PRIME_OUTPUT=1 glxgears >/tmp/glxgears-bench.log 2>&1 &
		;;
	esac
	LOAD_PID=$!
}

wait_for_util() {
	local target="$1" tries=0 u=0
	while ((tries < 20)); do
		sleep 1
		u="$(gpu_util)"
		if [[ "${u:-0}" -ge "$target" ]]; then
			echo "$u"
			return 0
		fi
		tries=$((tries + 1))
	done
	echo "${u:-0}"
	return 1
}

# 负载方式只挑一次
pick_load() {
	local u
	if command -v vkcube >/dev/null; then
		start_load vkcube
		u="$(wait_for_util 30)"
		if [[ "${u:-0}" -ge 30 ]]; then
			LOAD_KIND="vkcube/wayland"
			stop_load
			return 0
		fi
		stop_load
	fi
	if command -v glxgears >/dev/null; then
		start_load glxgears
		u="$(wait_for_util 30)"
		if [[ "${u:-0}" -ge 30 ]]; then
			LOAD_KIND="glxgears/x11"
			stop_load
			return 0
		fi
		stop_load
	fi
	return 1
}

sudo -v

QUERY="$(pick_query || true)"
if [[ -z "$QUERY" ]]; then
	echo "错误: nvidia-smi --query-gpu 一个字段都不认，退出" >&2
	exit 1
fi

echo "=== GPU 性能模式实测 ==="
echo "采样字段: $QUERY"
echo "注意: 这台机器 power.draw 可能是假值(空闲时恒报 588W)，以 clocks.sm 为准"
echo

if ! pick_load; then
	echo "错误: 没法把负载压到 NVIDIA GPU 上。" >&2
	echo "请到「设置 → 图形」切成「独显直连 / 仅 NVIDIA」后重试。" >&2
	exit 1
fi
echo "负载方式: $LOAD_KIND（全程统一，保证可比）"
echo

for mode in $MODES; do
	echo "------------------- $mode -------------------"
	if ! sudo redmi-perf set "$mode"; then
		echo "  !! 设置失败，跳过"
		continue
	fi
	sleep 5   # 让 EC 有时间应用新档位
	echo "  固件模式: $(redmi-perf get 2>&1)"

	start_load "$LOAD_KIND"
	u="$(wait_for_util 30 || true)"
	echo "  负载: $LOAD_KIND  (util=${u}%)"
	echo "  power.draw / clocks.sm / mem / temp / util"
	nvidia-smi --query-gpu="$QUERY" --format=csv,noheader -l 1 -c "$SAMPLES" |
		sed 's/^/    /'
	echo "  -- nvidia-smi -q -d POWER 原始值 --"
	nvidia-smi -q -d POWER 2>/dev/null |
		grep -iE "Power Draw|Current Power Limit|Requested Power Limit|Max Power Limit" |
		sed 's/^/    /'
	stop_load
	echo
done

echo "=== 恢复 balanced ==="
sudo redmi-perf set balanced
redmi-perf get
