#!/usr/bin/env bash
#
# 回退：恢复官方（未打补丁）NVIDIA 内核模块 + 关闭 shim。
#
# 支持 Arch 的 nvidia-open-dkms 与 Debian/Ubuntu 的 nvidia-dkms 布局：
#   * 官方模块优先从 /var/lib/dkms 的编译产物取（版本必须和当前驱动一致），
#     其次用安装时留下的备份 /var/backups/nvidia-ko-<内核版本>/official。
#   * 会清掉所有目录里的 shim 模块（含旧版装在 updates/dkms 里的），
#     再把官方模块放回去，避免 depmod 优先级串台。
#
# 用法:
#   sudo ./restore-prebuilt.sh          # 回退
#   ./restore-prebuilt.sh --check       # 只检查（不需要 root）
#   sudo ./restore-prebuilt.sh --quiet  # 静默（pacman 钩子用）
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# 正常在仓库里跑；也可能被 install-prebuilt.sh 拷到 /usr/local/lib/nvpcf-shim/
if [ -r "$ROOT/scripts/lib/common.sh" ]; then
	# shellcheck source=../scripts/lib/common.sh
	source "$ROOT/scripts/lib/common.sh"
elif [ -r "$HERE/common.sh" ]; then
	# shellcheck source=../scripts/lib/common.sh
	source "$HERE/common.sh"
else
	echo "找不到 scripts/lib/common.sh（仓库不完整？）" >&2
	exit 1
fi

CHECK=0
QUIET=0
for arg in "$@"; do
	case "$arg" in
	--check) CHECK=1 ;;
	--quiet) QUIET=1 ;;
	*) die "未知参数: $arg（用法: $0 [--check] [--quiet]）" ;;
	esac
done

say() {
	[ "$QUIET" -eq 1 ] && return 0
	echo "$@"
}

KVER="$(kver)"
BACKUP_ROOT="/var/backups/nvidia-ko-$KVER"
BACKUP="$BACKUP_ROOT/official"
MARKER="$BACKUP_ROOT/shim-installed"
NVVER="$(nvidia_driver_version)"

# 上次装到哪（marker 里记着），没有就按当前布局推算
DEST=""
if [ -r "$MARKER" ]; then
	DEST="$(sed -n 's/^dest=//p' "$MARKER" | head -1)"
fi
[ -n "$DEST" ] || DEST="$(nvidia_shim_dest)"

# 官方模块来源：DKMS 当前版本的编译产物 > 安装时备份（版本要对得上）
OFFICIAL_SRC=""
OFFICIAL_SRC="$(find_official_module_dir || true)"
if [ -z "$OFFICIAL_SRC" ] && has_nvidia_modules "$BACKUP"; then
	# 备份里可能是 .ko 也可能是 .ko.zst；取任意一个 nvidia.ko* 读版本
	BAK_KO="$(ls "$BACKUP"/nvidia.ko* 2>/dev/null | head -1)"
	bv="$(modinfo -F version "$BAK_KO" 2>/dev/null | head -1)"
	if [ -n "$bv" ] && { [ -z "$NVVER" ] || [ "$bv" = "$NVVER" ]; }; then
		OFFICIAL_SRC="$BACKUP"
	elif [ -z "$bv" ]; then
		warn "读不出备份模块的版本（$BAK_KO），跳过备份来源"
	fi
fi

say "==> 1/4 关闭 shim 模块参数"
say "  删除 /etc/modprobe.d/nvidia-nvpcf-shim.conf"
say "  删除 pacman 钩子（如果有）"

say
say "==> 2/4 定位官方原版模块"
# 和旧版行为一致：实在找不到官方模块时，先让 DKMS 重新编一遍再找
if [ -z "$OFFICIAL_SRC" ] && [ "${EUID:-$(id -u)}" -eq 0 ] && \
	[ -n "$NVVER" ] && command -v dkms >/dev/null 2>&1; then
	say "  没找到现成模块，尝试让 DKMS 重新安装 nvidia/$NVVER"
	dkms install -m nvidia -v "$NVVER" -k "$KVER" --force >/dev/null 2>&1 || true
	OFFICIAL_SRC="$(find_official_module_dir || true)"
fi
if [ -z "$OFFICIAL_SRC" ]; then
	die "找不到与当前驱动（${NVVER:-未知}）匹配的官方 nvidia 模块。
  Arch: 先重装/重建驱动：
      $(pkg_install_cmd nvidia-open-dkms)
      sudo dkms install nvidia/${NVVER} -k $KVER --force
  Debian: sudo dkms install nvidia/${NVVER} --all
  也可以 NV_OFFICIAL_DIR=/path/to/modules 指定。"
fi
say "  来源: $OFFICIAL_SRC"
say "  目标: $DEST"

if [ "$CHECK" -eq 1 ]; then
	say
	say "==> 检查模式"
	for d in $(find_shim_module_dirs); do
		say "  会清理 shim: $d"
	done
	say "  会把官方模块放回: $DEST"
	say "  检查完成。正式回退: sudo $0"
	exit 0
fi

require_root

say
say "==> 3/4 恢复官方模块"
rm -f /etc/modprobe.d/nvidia-nvpcf-shim.conf

# 先清掉所有 shim（包括旧版装在 updates/dkms 的），再放官方模块
for d in $(find_shim_module_dirs); do
	for f in "$d"/nvidia*.ko*; do
		[ -f "$f" ] || continue
		rm -f "$f"
		say "  清理 shim: $f"
	done
done

mkdir -p "$DEST"
for f in "$OFFICIAL_SRC"/nvidia*.ko*; do
	[ -f "$f" ] || continue
	install -m 0644 "$f" "$DEST/$(basename "$f")"
	say "  恢复: $(basename "$f")"
done
depmod -a "$KVER"

# 钩子和拷贝进去的辅助脚本也一起撤掉
rm -f /etc/pacman.d/hooks/90-nvpcf-shim-revert.hook
rm -rf /usr/local/lib/nvpcf-shim
rm -f "$MARKER"

say
say "==> 4/4 校验"
if MODPATH="$(modinfo -n nvidia 2>/dev/null)"; then
	MODINFO_OUT="$(modinfo "$MODPATH" 2>/dev/null || true)"
	if grep -q 'parm:.*nvpcf_shim' <<<"$MODINFO_OUT"; then
		warn "$MODPATH 里仍有 shim 参数，回退不完整；请检查 $DEST"
	else
		say "  $MODPATH（官方模块）"
	fi
else
	warn "modinfo 找不到 nvidia 模块，请检查 $DEST 并运行 depmod -a $KVER"
fi

say
say "已恢复官方模块，重启生效。"
say "确认：dmesg | grep -i NVPCF-SHIM   应该没有输出"
