#!/usr/bin/env bash
#
# mode-bench2.sh - 用真正压满的负载测 EC 模式 -> GPU 表现
#
# 为什么要有 v2：
#   v1 用 glxgears，被 vsync 锁在 240 FPS，GPU 停在 210 MHz 空载频率，
#   根本碰不到功耗墙，四个模式测出来完全一样。
#   这里换成真·满载：glmark2 stress > 4K vkcube 多开 > glxgears 多开。
#
set -u

MODES="${*:-quiet balanced turbo full-speed}"
SAMPLES=15
SETTLE=10
PCI="0000:01:00.0"
PM_CONTROL="/sys/bus/pci/devices/$PCI/power/control"
PM_SAVED=""
PIDS=()
LOAD_KIND=""

cleanup() {
	stop_load
	restore_pm
}
trap cleanup EXIT INT TERM

restore_pm() {
	if [[ -n "$PM_SAVED" ]]; then
		echo "$PM_SAVED" | sudo tee "$PM_CONTROL" >/dev/null 2>&1 || true
	fi
}

stop_load() {
	local p
	for p in "${PIDS[@]:-}"; do
		[[ -n "$p" ]] && kill "$p" 2>/dev/null
	done
	for p in "${PIDS[@]:-}"; do
		[[ -n "$p" ]] && wait "$p" 2>/dev/null
	done
	PIDS=()
}

gpu_util() {
	nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null |
		head -1 | tr -d ' '
}

sample_loop() {
	local n="$1" out="" i line
	for ((i = 0; i < n; i++)); do
		line="$(nvidia-smi --query-gpu="clocks.sm,temperature.gpu,utilization.gpu" \
			--format=csv,noheader,nounits 2>/dev/null | head -1)"
		[[ -n "$line" ]] && out+="$line"$'\n'
		sleep 1
	done
	echo "$out"
}

throttle_reasons() {
	nvidia-smi -q -d PERFORMANCE 2>/dev/null |
		sed -n '/Clocks Event Reasons/,/^$/p' |
		grep -iE "Sw Power Cap|SW Thermal|Hw Slowdown|Power Brake" |
		head -4 | tr -s ' ' | paste -sd'|' -
}

avg_power_limit() {
	local n=6 sum=0 v i
	for ((i = 0; i < n; i++)); do
		v="$(nvidia-smi -q -d POWER 2>/dev/null |
			grep -m1 "Current Power Limit" | grep -oE "[0-9]+\.[0-9]+" | head -1 || echo 0)"
		sum=$(awk -v s="$sum" -v x="${v:-0}" 'BEGIN{print s+x}')
		sleep 1
	done
	awk -v s="$sum" -v n="$n" 'BEGIN{printf "%.1f", s/n}'
}

start_glmark() {
	PIDS=()
	"${GLMARK_BIN:-glmark2}" --benchmark stress --run-on-battery \
		>/tmp/glmark2-bench.log 2>&1 &
	PIDS+=($!)
}

start_vkmark() {
	PIDS=()
	vkmark --benchmark scene >/tmp/vkmark-bench.log 2>&1 &
	PIDS+=($!)
}

start_vkcube4k() {
	PIDS=()
	local i
	for i in 1 2 3; do
		VK_ICD_FILENAMES=/etc/vulkan/icd.d/nvidia_icd.json \
		__NV_PRIME_RENDER_OFFLOAD=1 __NV_PRIME_OUTPUT=1 \
			vkcube --c 100000000 --width 3840 --height 2160 --wsi wayland \
			>>/tmp/vkcube-bench.log 2>&1 &
		PIDS+=($!)
	sleep 0.3
	done
}

start_gears() {
	PIDS=()
	local i
	for i in 1 2 3 4; do
		__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
		__NV_PRIME_OUTPUT=1 glxgears >/tmp/gears-bench.log 2>&1 &
	PIDS+=($!)
	sleep 0.3
	done
}

wait_for_util() {
	local target="$1" tries=0 u=0
	while ((tries < 25)); do
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

pick_load() {
	local u
	if command -v glmark2-wayland >/dev/null; then
		GLMARK_BIN=glmark2-wayland
		start_glmark
		u="$(wait_for_util 70)"
		if [[ "${u:-0}" -ge 70 ]]; then
			LOAD_KIND="glmark2-wayland-stress"
			stop_load
			return 0
		fi
		stop_load
		echo "  glmark2-wayland util=${u:-0}%"
	fi
	if command -v glmark2 >/dev/null; then
		GLMARK_BIN=glmark2
		start_glmark
		u="$(wait_for_util 70)"
		if [[ "${u:-0}" -ge 70 ]]; then
			LOAD_KIND="glmark2-stress"
			stop_load
			return 0
		fi
		stop_load
		echo "  glmark2 util=${u:-0}%"
	fi
	if command -v vkmark >/dev/null; then
		start_vkmark
		u="$(wait_for_util 70)"
		if [[ "${u:-0}" -ge 70 ]]; then
			LOAD_KIND="vkmark-scene"
			stop_load
			return 0
		fi
		stop_load
		echo "  vkmark util=${u:-0}%："
		tail -3 /tmp/vkmark-bench.log 2>/dev/null | sed 's/^/    /'
	fi
	if command -v vkcube >/dev/null; then
		start_vkcube4k
		u="$(wait_for_util 70)"
		if [[ "${u:-0}" -ge 70 ]]; then
			LOAD_KIND="vkcube-4K x3"
			stop_load
			return 0
		fi
		stop_load
		echo "  vkcube-4K util=${u:-0}%："
		tail -3 /tmp/vkcube-bench.log 2>/dev/null | sed 's/^/    /'
	fi
	start_gears
	u="$(wait_for_util 50)"
	if [[ "${u:-0}" -ge 50 ]]; then
		LOAD_KIND="glxgears x4"
		stop_load
		return 0
	fi
	stop_load
	echo "  glxgears util=${u:-0}%"
	return 1
}

sudo -v
sudo modprobe redmi_perf_wmi 2>/dev/null || true

if [[ -r "$PM_CONTROL" ]]; then
	PM_SAVED="$(cat "$PM_CONTROL" 2>/dev/null || echo auto)"
	echo on | sudo tee "$PM_CONTROL" >/dev/null 2>&1 || true
	echo "dGPU 运行时挂起: 已禁用（结束后恢复 $PM_SAVED）"
fi
echo "nvidia-powerd: $(systemctl is-active nvidia-powerd 2>/dev/null || echo 未安装)"
echo

echo "=== EC 性能模式实测（满载）==="
echo "每模式: 切换后静置 ${SETTLE}s，满载，采样 ${SAMPLES} 次"
echo

if ! pick_load; then
	echo "错误: 所有负载都压不满 GPU（util < 70%）" >&2
	echo "建议先 sudo apt install -y glmark2" >&2
	exit 1
fi
echo "负载方式: $LOAD_KIND"
echo

printf "%-12s %-8s %-9s %-11s %-7s %-7s  %s\n" \
	"模式" "EC值" "限值W(均)" "SM钟MHz(均)" "温度(均)" "util(均)" "限频原因"
printf "%-12s %-8s %-9s %-11s %-7s %-7s  %s\n" \
	"----" "----" "--------" "-----------" "------" "-------" "--------"

for mode in $MODES; do
	if ! sudo redmi-perf set "$mode"; then
		echo "$mode: 设置失败"
		continue
	fi
	sleep "$SETTLE"

	ecval="$(redmi-perf get 2>&1 | grep -oE '\([0-9]+\)' | tr -d '()')"
	pl="$(avg_power_limit)"

	case "$LOAD_KIND" in
	glmark2*) start_glmark ;;
	vkmark*)  start_vkmark ;;
	vkcube*)  start_vkcube4k ;;
	*)        start_gears ;;
	esac
	u="$(wait_for_util 70 || true)"
	raw="$(sample_loop "$SAMPLES")"
	throttle="$(throttle_reasons)"
	stop_load

	sm="$(echo "$raw" | awk -F', ' '{s+=$1; n++} END{if(n) printf "%.0f", s/n}')"
	tmp="$(echo "$raw" | awk -F', ' '{s+=$2; n++} END{if(n) printf "%.0f", s/n}')"
	utl="$(echo "$raw" | awk -F', ' '{s+=$3; n++} END{if(n) printf "%.0f", s/n}')"

	printf "%-12s %-8s %-9s %-11s %-7s %-7s  %s\n" \
		"$mode" "${ecval:-?}" "${pl:-?}" "${sm:-?}" "${tmp:-?}" "${utl:-?}" "${throttle:-}"
	[[ "${sm:-0}" == "0" ]] && echo "    !! 采样为 0，负载没起来"
done

echo
echo "=== 恢复 balanced ==="
sudo redmi-perf set balanced
redmi-perf get
