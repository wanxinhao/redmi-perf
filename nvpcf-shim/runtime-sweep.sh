#!/usr/bin/env bash
#
# 运行时扫描 NVPCF shim 参数。
#
# shim 的参数都是 module_param(0644)，可以直接写 /sys/module/nvidia/parameters/，
# 所以下面这些实验全部不用重编模块、不用重启，改完等 3 秒就能看结果。
#
# 要回答两个问题：
#   1) ctr0b 覆盖是不是把 "PRH failed to update thermal limit!" 弄出来的
#      （预期：ctr0b=0 保留 BIOS 原值 87 后，这条断言不再出现，
#        同时 GPU Max Operating T.Limit Temp 从 0 变成 87）
#   2) 我们注入的 platform power mode（counter 0x13）能不能影响 GPU 功耗上限
#      （counter 0x13 = (允许模式掩码<<8)|当前模式；掩码 0x1E = 模式 1..4）
#
set -uo pipefail

PARAMS=/sys/module/nvidia/parameters

pl() {   # Current Power Limit (W)
	nvidia-smi -q -d POWER 2>/dev/null |
		sed -n 's/^[[:space:]]*Current Power Limit[[:space:]]*:[[:space:]]*\([0-9.]\+\).*/\1/p' |
		head -1
}

tt() {   # GPU Target Temperature
	nvidia-smi -q -d TEMPERATURE 2>/dev/null |
		sed -n 's/^[[:space:]]*GPU Target Temperature[[:space:]]*:[[:space:]]*\([0-9.]\+\).*/\1/p' |
		head -1
}

mt() {   # GPU Max Operating T.Limit Temp
	nvidia-smi -q -d TEMPERATURE 2>/dev/null |
		sed -n 's/^[[:space:]]*GPU Max Operating T.Limit Temp[[:space:]]*:[[:space:]]*\([0-9.]\+\).*/\1/p' |
		head -1
}

sp() {   # set param
	echo "$2" | sudo tee "$PARAMS/$1" >/dev/null 2>&1
}

row() {
	printf "   %-28s PowerLimit=%-8s TargetTemp=%-6s MaxOpT=%-6s\n" "$1" "$(pl)" "$(tt)" "$(mt)"
}

echo "== 0. 当前状态 =="
for p in nvpcf_shim_mode nvpcf_shim_ctr0b nvpcf_shim_ppm nvpcf_shim_ppm_enable; do
	printf "   %-24s = %s\n" "$p" "$(cat "$PARAMS/$p" 2>/dev/null || echo '(不存在)')"
done
row "(baseline)"

echo
echo "== 1. ctr0b：关掉覆盖，保留 BIOS 原值 =="
sp nvpcf_shim_ctr0b 0
sleep 4
row "ctr0b=0"
echo "   最近 3 条 platform_request_handler 相关日志："
sudo dmesg 2>/dev/null | grep -iE "platform_request_handler|SBIOS" | tail -3 |
	sed 's/^/     /'

echo
echo "== 2. platform power mode 扫描（mask=0x1E，mode 0..7）=="
for m in 0 1 2 3 4 5 6 7; do
	v=$(printf '0x1E%02X' "$m")
	sp nvpcf_shim_ppm "$v"
	sleep 4
	row "ppm=$v (mode=$m)"
done

echo
echo "== 3. 掩码扫描（mode=4 固定，mask 0x1E/0x3E/0x7E/0xFE）=="
for mask in 0x1E 0x3E 0x7E 0xFE; do
	v=$(printf '%s04' "$mask")
	sp nvpcf_shim_ppm "$v"
	sleep 4
	row "ppm=$v"
done

echo
echo "== 4. 还原成 balanced 语义 =="
sp nvpcf_shim_ppm 0x1E01
sp nvpcf_shim_ctr0b 0
sleep 3
row "restored"

cat <<'EOF'

提示：
  * 上面只改了运行中的内核参数，重启后会失效。
    想固化：sudo sed -i 's/nvpcf_shim_ppm=0x1E01/nvpcf_shim_ppm=<你选的值>/' \
          /etc/modprobe.d/nvidia-nvpcf-shim.conf
  * 如果 1. 里断言消失了，说明之前那条 "PRH failed to update thermal limit!"
    就是 ctr0b 乱填 100 造成的，把 install-prebuilt.sh 里的 ctr0b 固定成 0 即可。
EOF
