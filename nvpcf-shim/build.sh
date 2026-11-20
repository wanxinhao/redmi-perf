#!/usr/bin/env bash
#
# build.sh - 重新编译带 NVPCF shim 的 NVIDIA 内核模块，打包到 prebuilt/
#
# 支持两种 NVIDIA 源码布局：
#   * nvidia-open / open-gpu-kernel-modules（Arch 的 nvidia-open-dkms）
#       <源码根>/kernel-open/nvidia/nv-acpi.c，模块产物在 kernel-open/<模块>/
#   * 官方 .run / 发行版完整源码树（旧版写法）
#       <源码根>/nvidia/nv-acpi.c，模块产物在 <源码根>/<模块>/
#
# 用法:
#   ./build.sh              # 自动找源码（/usr/src/nvidia-*、DKMS build 目录）
#   ./build.sh --check      # 只做环境/布局检查，不复制、不编译
#   NV_SRC_ROOT=/usr/src/nvidia-620.73.04 ./build.sh
#   KVER=7.3.5-arch1-1 ./build.sh   # 给指定内核编译（需要对应的头文件）
#   NV_BUILD_DIR=/tmp/nvpcf-build ./build.sh  # 换编译目录（root 编过一次后）
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
[ -r "$ROOT/scripts/lib/common.sh" ] ||
	{ echo "错误: 缺少 $ROOT/scripts/lib/common.sh，请在完整仓库里运行（不要单独拷贝 nvpcf-shim/）" >&2; exit 1; }
# shellcheck source=../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

CHECK=0
case "${1:-}" in
--check) CHECK=1 ;;
-h | --help)
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
"") ;;
*)
	die "未知参数: $1（试 --help）"
	;;
esac

KVER="$(kver)"
KDIR="$(kernel_build_dir)"
# 源码副本/编译目录；sudo 编译过一次后 build/src 会变成 root 所有，
# 这时可以用 NV_BUILD_DIR 换个目录继续以普通用户编译。
BUILD="${NV_BUILD_DIR:-$HERE/build}"
SRC="$BUILD/src"
PRE="$HERE/prebuilt"

# 默认模块列表；构建后按实际产物过滤（peermem 之类不是每个内核都出）
DEFAULT_MODULES="nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem"

command -v python3 >/dev/null 2>&1 ||
	die "需要 python3（补丁器）: $(pkg_install_cmd "$( [ "$(pkg_mgr)" = pacman ] && echo python || echo python3)")"
command -v zstd >/dev/null 2>&1 ||
	die "需要 zstd（打包模块）: $(pkg_install_cmd zstd)"

echo "==> NVIDIA 驱动版本"
NVVER="$(nvidia_driver_version)"
if [ -z "$NVVER" ]; then
	die "查不到 NVIDIA 驱动版本。先装驱动，或用 NVVER=<版本> 指定。"
fi
echo "  $NVVER"

echo
echo "==> 源码树"
SRC_ROOT="$(nvidia_src_root || true)"
if [ -z "$SRC_ROOT" ]; then
	cat >&2 <<EOF
找不到 NVIDIA 内核模块源码。

  Arch: 装源码包（预编译的 nvidia-open 不带源码）：
        $(pkg_install_cmd nvidia-open-dkms)
  其他: 用 nvidia-installer --dkms 安装，或 NV_SRC_ROOT=/usr/src/nvidia-<版本> 指定。

已安装的驱动包：
$(if [ "$(distro_family)" = arch ]; then pacman -Qq 2>/dev/null | grep -i nvidia | sed 's/^/  /'; fi)
EOF
	exit 1
fi
LAYOUT="$(nvidia_layout "$SRC_ROOT")"
MOD_REL="$(nvidia_module_rel "$SRC_ROOT")"
echo "  $SRC_ROOT"
echo "  布局: $LAYOUT（模块产物在 ${MOD_REL:-.}/）"

if [ ! -f "$KDIR/Makefile" ]; then
	die "找不到内核构建目录 $KDIR。先装当前内核的头文件：
  $(kernel_headers_hint)"
fi

KMAKE_EXTRA="$(kernel_make_extra)"
if [ -n "$KMAKE_EXTRA" ]; then
	echo "  内核用 clang 构建，传参: $KMAKE_EXTRA"
fi

if [ "$CHECK" -eq 1 ]; then
	echo
	echo "==> 检查模式"
	NV_SRC_ROOT="$SRC_ROOT" NV_DRY_RUN=1 python3 "$HERE/patch_nv_acpi.py" --check
	echo "  编译命令: make -j$(nproc) KERNEL_UNAME=$KVER $KMAKE_EXTRA modules"
	echo "  检查通过，可以正式运行 ./build.sh"
	exit 0
fi

# ---------------------------------------------------------------- 源码副本 ----

# 用 sudo 编过一次后 build/ 会变成 root 所有，普通用户跑不了；
# 提前给出可操作的提示，而不是在复制/写文件时半途报错。
if [ -e "$BUILD" ] && [ ! -w "$BUILD" ]; then
	die "编译目录 $BUILD 不可写（大概之前用 sudo 编过）。
  换目录: NV_BUILD_DIR=/tmp/nvpcf-build ./build.sh
  或: sudo rm -rf '$BUILD' 后重试"
fi
if [ -d "$SRC" ] && [ ! -w "$SRC" ]; then
	die "源码副本 $SRC 不可写（之前用 sudo 编过）。
  sudo rm -rf '$SRC'
  或换目录: NV_BUILD_DIR=/tmp/nvpcf-build ./build.sh"
fi

# 驱动升级后 /usr/src/nvidia-<新版本> 会变；旧的 build/src 必须换掉，
# 否则会拿老源码编出老模块（和新的 nvidia-utils 版本错配）。
INFO="$BUILD/source-info"
WANT_INFO="driver=$NVVER
src=$SRC_ROOT"
if [ -d "$SRC" ] && { [ ! -f "$INFO" ] || [ "$(cat "$INFO")" != "$WANT_INFO" ]; }; then
	echo
	echo "==> 源码树/驱动版本变了，重新复制 build/src"
	rm -rf "$SRC"
fi

if [ ! -d "$SRC" ]; then
	echo
	echo "==> 复制源码到 $SRC（不改动 /usr/src）"
	mkdir -p "$BUILD"
	if [ "${EUID:-$(id -u)}" -eq 0 ]; then
		cp -a "$SRC_ROOT" "$SRC"
	else
		cp -a --no-preserve=ownership "$SRC_ROOT" "$SRC"
	fi
	printf '%s\n' "$WANT_INFO" >"$INFO"
fi

echo
echo "==> 1/5 打补丁"
# 每次都从 .orig 重来，保证 shim 块是当前仓库里的版本（幂等）
ACPI="$(nv_acpi_path "$SRC")" || die "源码副本里找不到 nv-acpi.c"
if [ -f "$ACPI.orig" ]; then
	cp "$ACPI.orig" "$ACPI"
fi
NV_SRC_ROOT="$SRC" python3 "$HERE/patch_nv_acpi.py"

echo
echo "==> 2/5 编译（$KVER）"
MAKE_ENV=("KERNEL_UNAME=$KVER")
LOG="$BUILD/make.log"
build_modules() {
	# $1 = 额外 make 参数（可为空）
	local extra="$1"
	# shellcheck disable=SC2086
	(cd "$SRC" && make -j"$(nproc)" "${MAKE_ENV[@]}" $KMAKE_EXTRA $extra \
		NV_EXCLUDE_BUILD_MODULES='' modules) >"$LOG" 2>&1
}
if ! build_modules ""; then
	if grep -q 'Failed CC version check' "$LOG" 2>/dev/null; then
		warn "内核与当前编译器的版本不一致（NVIDIA 的检查），用 IGNORE_CC_MISMATCH=1 重试"
		if ! (cd "$SRC" && make -j"$(nproc)" "${MAKE_ENV[@]}" $KMAKE_EXTRA \
			IGNORE_CC_MISMATCH=1 NV_EXCLUDE_BUILD_MODULES='' modules) >"$LOG" 2>&1; then
			echo "编译失败，日志尾部：" >&2
			tail -40 "$LOG" >&2
			exit 1
		fi
	else
		echo "编译失败，日志尾部：" >&2
		tail -40 "$LOG" >&2
		exit 1
	fi
fi
echo "  日志: $LOG"

echo
echo "==> 3/5 收集并校验模块"
MODULES=""
for m in ${NV_MODULES:-$DEFAULT_MODULES}; do
	ko="$SRC/$MOD_REL/$m.ko"
	if [ ! -f "$ko" ]; then
		if [ "$m" = nvidia ]; then
			die "没有生成 nvidia.ko，编译没成功？看 $LOG"
		fi
		echo "  $m: 本内核未构建，跳过"
		continue
	fi
	vm="$(modinfo -F vermagic "$ko" 2>/dev/null | head -1)"
	echo "  $m: $vm"
	if [[ "$vm" != "$KVER "* ]]; then
		die "$m 的 vermagic 不匹配（期望 $KVER …），中止"
	fi
	MODULES="$MODULES $m"
done
MODULES="${MODULES# }"

echo "  shim 字符串数: $(strings "$SRC/$MOD_REL/nvidia.ko" | grep -c 'NVPCF-SHIM' || true)"
PARM_COUNT="$(modinfo "$SRC/$MOD_REL/nvidia.ko" | grep -c 'parm:.*nvpcf_shim' || true)"
echo "  模块参数数: $PARM_COUNT"
if [ "${PARM_COUNT:-0}" -eq 0 ]; then
	die "nvidia.ko 里没有 nvpcf_shim_* 参数，补丁没生效"
fi

echo
echo "==> 4/5 打包到 prebuilt/"
mkdir -p "$PRE"
rm -f "$PRE"/*.ko.zst
for m in $MODULES; do
	zstd -q -f -19 "$SRC/$MOD_REL/$m.ko" -o "$PRE/$m.ko.zst"
done
ls -la "$PRE/"

echo
echo "==> 5/5 完成"
echo "  现在可以: $( [ "${EUID:-$(id -u)}" -eq 0 ] && echo ./install-prebuilt.sh || echo "sudo ./install-prebuilt.sh" )"
