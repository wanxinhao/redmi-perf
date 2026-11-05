#!/usr/bin/env bash
#
# 彻底回退：恢复官方 DKMS 模块 + 关闭 shim。
#
# ⚠ 为什么不能只靠 /var/backups/nvidia-ko-$KVER：
#   install-prebuilt.sh 每次都会把 DEST 里现有的模块备份过去，
#   跑第二次时备份的就变成"打过 shim 的旧模块"了，恢复了也还是 shim 版。
#   所以这里优先用 DKMS 自己的 build 产物（干净的原版），
#   只有在找不到时才退到备份目录。
#
set -euo pipefail

KVER="$(uname -r)"
DEST="/lib/modules/$KVER/updates/dkms"
BACKUP="/var/backups/nvidia-ko-$KVER"

if [[ $EUID -ne 0 ]]; then
	echo "需要 root：sudo $0" >&2
	exit 1
fi

echo "==> 1/4 关闭 shim 模块参数"
rm -f /etc/modprobe.d/nvidia-nvpcf-shim.conf
echo "  已删除 /etc/modprobe.d/nvidia-nvpcf-shim.conf"

echo "==> 2/4 定位官方原版模块"
SRC=""
for d in /var/lib/dkms/nvidia/*/"$KVER"/x86_64/module; do
	if [[ -f "$d/nvidia.ko.zst" ]]; then
		SRC="$d"
	break
	fi
done
if [[ -z "$SRC" ]]; then
	for d in "$BACKUP"/official "$BACKUP"; do
	if [[ -f "$d/nvidia.ko.zst" ]]; then
		SRC="$d"
	break
	fi
	done
fi
if [[ -z "$SRC" ]]; then
	echo "  找不到官方模块，改为让 DKMS 重新安装" >&2
	dkms install --force nvidia/"$(ls /var/lib/dkms/nvidia/ | head -1)" --all
	depmod -a "$KVER"
	echo "已让 DKMS 重装官方模块，重启生效。"
	exit 0
fi
echo "  用: $SRC"

echo "==> 3/4 安装回 DEST"
for f in "$SRC"/*.ko.zst; do
	install -m 0644 "$f" "$DEST/$(basename "$f")"
	echo "  $(basename "$f")"
done
depmod -a "$KVER"

echo "==> 4/4 校验"
dkms status nvidia 2>/dev/null || true

echo
echo "已恢复官方模块，重启生效。"
echo "确认：dmesg | grep -i NVPCF-SHIM   应该没有输出"
