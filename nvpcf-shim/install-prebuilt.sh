#!/usr/bin/env bash
#
# 直接安装预编译好的（带 NVPCF shim 的）NVIDIA 内核模块。
#
# 同时支持：
#   * Arch Linux 的 nvidia-open-dkms（nvidia-open 布局，模块在 kernel-open/）
#   * Debian/Ubuntu 的 nvidia-dkms / .run（完整源码树布局）
#
# 安装目录自动选择：官方模块在 updates/ 下就覆盖它，否则用
# updates/nvpcf-shim/（Arch 官方模块在 kernel/drivers/video/）。
# 安装前把官方原版模块备份到 /var/backups/nvidia-ko-<内核版本>/official。
#
# 用法:
#   sudo ./install-prebuilt.sh            # 安装
#   ./install-prebuilt.sh --check         # 只检查（不需要 root）
#   sudo ./install-prebuilt.sh --no-hook  # 不装 pacman 钩子（仅 Arch）
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -r "$ROOT/scripts/lib/common.sh" ] ||
	{ echo "错误: 缺少 $ROOT/scripts/lib/common.sh，请在完整仓库里运行（不要单独拷贝 nvpcf-shim/）" >&2; exit 1; }
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

CHECK=0
INSTALL_HOOK=1
for arg in "$@"; do
	case "$arg" in
	--check) CHECK=1 ;;
	--no-hook) INSTALL_HOOK=0 ;;
	*) die "未知参数: $arg（用法: $0 [--check] [--no-hook]）" ;;
	esac
done

KVER="$(kver)"
PRE="$HERE/prebuilt"
BACKUP_ROOT="/var/backups/nvidia-ko-$KVER"
BACKUP="$BACKUP_ROOT/official"
MARKER="$BACKUP_ROOT/shim-installed"
NVVER="$(nvidia_driver_version)"

echo "==> 1/5 检查 prebuilt 模块"
if ! ls "$PRE"/*.ko.zst >/dev/null 2>&1; then
	die "$PRE 里没有 .ko.zst，先编译: ./build.sh"
fi
MODULES=()
for f in "$PRE"/*.ko.zst; do
	m="$(basename "$f" .ko.zst)"
	vm="$(modinfo -F vermagic "$f" 2>/dev/null | head -1)"
	echo "  $m: $vm"
	if [[ "$vm" != "$KVER "* ]]; then
		die "$m 的 vermagic 不是 $KVER（模块是给别的内核编的），用 KVER=$KVER ./build.sh 重编"
	fi
	MODULES+=("$m")
done
case " ${MODULES[*]} " in
*" nvidia "*) ;;
*) die "prebuilt 里没有 nvidia.ko.zst" ;;
esac
NV_PARM_OUT="$(modinfo "$PRE/nvidia.ko.zst" 2>/dev/null || true)"
if ! grep -q 'parm:.*nvpcf_shim' <<<"$NV_PARM_OUT"; then
	die "nvidia.ko 里没有 nvpcf_shim 参数，这不是打过 shim 的模块"
fi
echo "  驱动版本: ${NVVER:-未知}"

DEST="$(nvidia_shim_dest)"
OFFICIAL_DIR="$(find_official_module_dir || true)"
echo "  安装目录: $DEST"
echo "  官方原版: ${OFFICIAL_DIR:-（未找到）}"
echo "  备份目录: $BACKUP"

USERS_V="$(nvidia_userspace_version || true)"
if [ -n "$USERS_V" ] && [ -n "$NVVER" ] && [ "$USERS_V" != "$NVVER" ]; then
	warn "内核模块版本 $NVVER 与用户态 nvidia-utils $USERS_V 不一致，驱动会起不来。
     先重装/重编对应版本的驱动，再打 shim。"
fi

if [ "$CHECK" -eq 1 ]; then
	echo
	echo "==> 检查模式"
	if [ -z "$OFFICIAL_DIR" ]; then
		warn "没找到官方原版模块（DKMS 还没 build？），正式安装会拒绝。"
	else
		echo "  会备份: $(ls "$OFFICIAL_DIR"/nvidia*.ko* 2>/dev/null | wc -l) 个模块"
	fi
	for d in $(find_shim_module_dirs); do
		[ "$d" = "$DEST" ] && continue
		echo "  会清理旧 shim 目录: $d"
	done
	echo "  检查完成。正式安装: sudo $0"
	exit 0
fi

require_root

echo
echo "==> 2/5 备份官方原版模块"
if [ -z "$OFFICIAL_DIR" ]; then
	die "找不到官方原版 nvidia 模块，拒绝在没有备份的情况下覆盖。
  Arch: 先让 nvidia-open-dkms build 一次（dkms status），
        或 NV_OFFICIAL_DIR=/path/to/modules 指定备份来源。
  应急: $(pkg_install_cmd nvidia-open-dkms)"
fi
mkdir -p "$BACKUP"
rm -f "$BACKUP"/*.ko "$BACKUP"/*.ko.zst 2>/dev/null || true
for f in "$OFFICIAL_DIR"/nvidia*.ko*; do
	[ -f "$f" ] || continue
	cp -f "$f" "$BACKUP/"
	echo "  $(basename "$f")"
done

echo
echo "==> 3/5 安装 shim 模块到 $DEST"
mkdir -p "$DEST"

# 清掉别的目录里遗留的 shim 模块，避免 depmod 优先级串台（旧版装在 updates/dkms）
for d in $(find_shim_module_dirs); do
	[ "$d" = "$DEST" ] && continue
	for f in "$d"/nvidia*.ko*; do
		[ -f "$f" ] || continue
		rm -f "$f"
		echo "  清理旧 shim: $f"
	done
done

for m in "${MODULES[@]}"; do
	install -Dm644 "$PRE/$m.ko.zst" "$DEST/$m.ko.zst"
	echo "  $m.ko.zst"
done
depmod -a "$KVER"

echo
echo "==> 4/5 写模块参数"
PSHARE_INIT=0
nvidia_needs_pshare_init && PSHARE_INIT=1
cat >/etc/modprobe.d/nvidia-nvpcf-shim.conf <<EOF
# NVPCF shim 参数
#   mode=1         允许改写固件应答
#   log=1          打印请求/应答
#   fallback=1     硬编码路径失败时用 ACPI 命名空间句柄重试
#   shift=0        不用了：这一代驱动自己就解不开 NVPCF 动态功耗表
#   ctr0b=0        覆盖 GPS counter 0x0b 的值（RM 会 x256 后下发给 GPU）
#                  counter 0x0b 实测 = 目标温度(℃)，BIOS 原值 87
#                  0 = 保持固件原值（填 100 会让 SBIOS 拒绝 "set thermal
#                      limit" 指令，多出一条断言）
#   ppm_enable=1   给 GPS 支持应答打开 counter 0x13（platform power mode）位
#   ppm=0x1E01     counter 0x13 的值 = (允许模式掩码<<8)|当前模式
#                  0x1E = 模式 1..4 可用，0x01 = 当前 balanced
#   pshare_init   初始化窗口内清掉 PShareStatus 的 UPDATE_LIMIT pending，
#                  避免 nvidia-open 620 在传感器初始化前更新 limit 触发断言
#                  620+ 写 1；更旧的驱动（595 等）写 0，保持原行为
options nvidia nvpcf_shim_mode=1 nvpcf_shim_log=1 nvpcf_shim_fallback=1 \\
	nvpcf_shim_rev=0 nvpcf_shim_shift=0 nvpcf_shim_ctr0b=0 \\
	nvpcf_shim_ppm_enable=1 nvpcf_shim_ppm=0x1E01 nvpcf_shim_pshare_init=$PSHARE_INIT
EOF
echo "  /etc/modprobe.d/nvidia-nvpcf-shim.conf"
echo "redmi_perf_wmi" >/etc/modules-load.d/redmi-perf.conf

cat >"$MARKER" <<EOF
# 由 nvpcf-shim/install-prebuilt.sh 生成，restore-prebuilt.sh 用它做判断
driver=$NVVER
kernel=$KVER
dest=$DEST
modules=${MODULES[*]}
backup=$BACKUP
EOF

if [ "$INSTALL_HOOK" -eq 1 ] && [ "$(distro_family)" = arch ] && [ -d /etc/pacman.d/hooks ]; then
	echo
	echo "==> 5/5 安装 pacman 钩子（NVIDIA 驱动升级后自动撤掉旧 shim）"
	# pacman 的 Operation 只接受 Install / Upgrade / Remove。写错的话
	# 整个 pacman 事务都会报 "无效值 ..." 而失败，所以先校验再装。
	BAD_OP="$(grep -E '^[[:space:]]*Operation[[:space:]]*=' "$HERE/arch/nvpcf-shim.hook" 2>/dev/null |
		sed -e 's/^[[:space:]]*Operation[[:space:]]*=[[:space:]]*//' -e 's/[[:space:]]*$//' |
		grep -vxE 'Install|Upgrade|Remove' | head -1 || true)"
	if [ -n "$BAD_OP" ]; then
		warn "钩子里有 pacman 不认识的 Operation: '$BAD_OP'，跳过安装 pacman 钩子（模块本身已装好）"
	else
		install -Dm644 "$HERE/arch/nvpcf-shim.hook" /etc/pacman.d/hooks/90-nvpcf-shim-revert.hook
		install -Dm755 "$HERE/arch/on-nvidia-upgrade.sh" /usr/local/lib/nvpcf-shim/on-nvidia-upgrade.sh
		install -Dm755 "$HERE/restore-prebuilt.sh" /usr/local/lib/nvpcf-shim/restore-prebuilt.sh
		install -Dm644 "$ROOT/scripts/lib/common.sh" /usr/local/lib/nvpcf-shim/common.sh
		echo "  /etc/pacman.d/hooks/90-nvpcf-shim-revert.hook"
		echo "  /usr/local/lib/nvpcf-shim/"
	fi
else
	echo
	echo "==> 5/5 跳过 pacman 钩子（非 Arch 或 --no-hook）"
fi

echo
echo "完成。现在重启，然后："
echo "  dmesg | grep -iE 'NVPCF-SHIM|SBIOS'   # 看 RM 问了什么 + 断言还在不在"
echo "  nvidia-smi -q -d POWER,TEMPERATURE    # 看功耗上限/目标温度有没有跟着变"
if [ "$(distro_family)" = arch ]; then
	echo
	echo "注意: nvidia-open-dkms / nvidia-utils 升级后旧 shim 模块会失效，"
	echo "      钩子会自动回退到官方模块；想继续用就再跑一次 ./install.sh。"
fi
echo
echo "回退：sudo $HERE/restore-prebuilt.sh"
