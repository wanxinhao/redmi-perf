#!/usr/bin/env bash
#
# 直接安装预编译好的（带 NVPCF shim 的）nvidia 内核模块，绕过 DKMS。
#
# 为什么不用 dkms build：这套 DKMS 状态是 .run 安装器留下的，
# dkms build 会静默跳过；直接装更可控。
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
DEST="/lib/modules/$KVER/updates/dkms"
PRE="$HERE/prebuilt"
BACKUP="/var/backups/nvidia-ko-$KVER"

if [[ $EUID -ne 0 ]]; then
	echo "需要 root：sudo $0" >&2
	exit 1
fi

MODULES=(nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem)

echo "==> 1/4 备份官方原版模块"
# 注意：不要备份 DEST 里的内容 —— 第二次跑时那已经是打过 shim 的模块了，
# 拿它当"原版备份"会导致 restore-prebuilt.sh 恢复完还是 shim 版。
# 这里固定从 DKMS 的 build 产物取原版。
ORIG=""
for d in /var/lib/dkms/nvidia/*/"$KVER"/x86_64/module; do
	if [[ -f "$d/nvidia.ko.zst" ]]; then
		ORIG="$d"
		break
	fi
done
if [[ -n "$ORIG" ]]; then
	BACKUP="$BACKUP/official"
	mkdir -p "$BACKUP"
	cp -a "$ORIG"/*.ko.zst "$BACKUP/"
	echo "  原版来源: $ORIG"
else
	echo "  !! 没找到 DKMS build 产物，退而备份当前 DEST" >&2
	mkdir -p "$BACKUP"
	for m in "${MODULES[@]}"; do
		if [[ -f "$DEST/$m.ko.zst" ]]; then
			cp -a "$DEST/$m.ko.zst" "$BACKUP/"
		fi
	done
fi
ls -la "$BACKUP"

echo "==> 2/4 校验 vermagic"
for m in "${MODULES[@]}"; do
	vm="$(modinfo -F vermagic "$PRE/$m.ko.zst" 2>/dev/null | head -1)"
	echo "  $m: $vm"
	if [[ "$vm" != "$KVER "* ]]; then
		echo "  !! vermagic 不匹配，中止" >&2
		exit 1
	fi
done

echo "==> 3/4 安装模块"
for m in "${MODULES[@]}"; do
	install -m 0644 "$PRE/$m.ko.zst" "$DEST/$m.ko.zst"
done
depmod -a "$KVER"

echo "==> 4/4 让 redmi_perf_wmi 开机自动加载"
echo "redmi_perf_wmi" >/etc/modules-load.d/redmi-perf.conf

cat >/etc/modprobe.d/nvidia-nvpcf-shim.conf <<EOF
# NVPCF shim 参数
#   mode=1         允许改写固件应答
#   log=1          打印请求/应答
#   fallback=1     硬编码路径失败时用 ACPI 命名空间句柄重试
#   shift=0        不用了：这一代驱动自己就解不开 NVPCF 动态功耗表
#   ctr0b=0        覆盖 GPS counter 0x0b 的值（RM 会 x256 后下发给 GPU）
#                  counter 0x0b 实测 = 目标温度(℃)，BIOS 原值 87
#                  0 = 保持固件原值（不要乱填：填 100 会让 SBIOS 拒绝
#                      "set thermal limit" 指令，多出一条断言）
#   ppm_enable=1   给 GPS 支持应答打开 counter 0x13（platform power mode）位
#   ppm=0x1E01     counter 0x13 的值 = (允许模式掩码<<8)|当前模式
#                  0x1E = 模式 1..4 可用，0x01 = 当前 balanced
options nvidia nvpcf_shim_mode=1 nvpcf_shim_log=1 nvpcf_shim_fallback=1 \
	nvpcf_shim_rev=0 nvpcf_shim_shift=0 nvpcf_shim_ctr0b=0 \
	nvpcf_shim_ppm_enable=1 nvpcf_shim_ppm=0x1E01
EOF
cat /etc/modprobe.d/nvidia-nvpcf-shim.conf

echo
echo "完成。现在重启，然后："
echo "  dmesg | grep -iE 'NVPCF-SHIM|SBIOS'   # 看 RM 问了什么 + 断言还在不在"
echo "  nvidia-smi -q -d POWER,TEMPERATURE    # 看功耗上限/目标温度有没有跟着变"
echo
echo "回退：sudo $HERE/restore-prebuilt.sh"
