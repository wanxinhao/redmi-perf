#!/usr/bin/env bash
#
# build.sh - 重新编译带 shim 的 nvidia 模块并打包到 prebuilt/
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/build/src"
MODULES=(nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem)

if [[ -z "${NVVER:-}" ]]; then
	# 自动找 /usr/src/nvidia-<版本>，取版本号最大的那个
	NVVER="$(ls -d /usr/src/nvidia-* 2>/dev/null |
		sed 's|.*/nvidia-||' | sort -V | tail -1)"
fi
if [[ -z "$NVVER" ]]; then
	echo "找不到 /usr/src/nvidia-*/，请手动指定：NVVER=595.112.07 $0" >&2
	exit 1
fi
echo "驱动版本: $NVVER"

if [[ ! -d "$SRC" ]]; then
	echo "首次构建：从 /usr/src 复制源码"
	if [[ ! -d "/usr/src/nvidia-$NVVER" ]]; then
		echo "  找不到 /usr/src/nvidia-$NVVER" >&2
		exit 1
	fi
	mkdir -p "$HERE/build"
	cp -a "/usr/src/nvidia-$NVVER" "$SRC"
fi

echo "==> 1/4 从原始 nv-acpi.c 重新打补丁"
if [[ -f "$SRC/nvidia/nv-acpi.c.orig" ]]; then
	cp "$SRC/nvidia/nv-acpi.c.orig" "$SRC/nvidia/nv-acpi.c"
fi
NV_SRC_ROOT="$SRC" python3 "$HERE/patch_nv_acpi.py"

echo "==> 2/4 编译"
(cd "$SRC" && make -j"$(nproc)" NV_EXCLUDE_BUILD_MODULES='' \
	KERNEL_UNAME="$(uname -r)" modules >"$HERE/build/make.log" 2>&1) ||
	{ echo "编译失败，日志尾部："; tail -30 "$HERE/build/make.log"; exit 1; }

echo "==> 3/4 校验"
for m in "${MODULES[@]}"; do
	vm="$(modinfo -F vermagic "$SRC/$m.ko" 2>/dev/null | head -1)"
	echo "  $m: $vm"
	[[ "$vm" == "$(uname -r) "* ]] || { echo "vermagic 不匹配" >&2; exit 1; }
done
echo "  shim 字符串数: $(strings "$SRC/nvidia.ko" | grep -c 'NVPCF-SHIM')"
echo "  模块参数数: $(modinfo "$SRC/nvidia.ko" | grep -c 'parm:.*nvpcf_shim')"

echo "==> 4/4 打包"
mkdir -p "$HERE/prebuilt"
for m in "${MODULES[@]}"; do
	zstd -q -f -19 "$SRC/$m.ko" -o "$HERE/prebuilt/$m.ko.zst"
done
ls -la "$HERE/prebuilt/"
echo
echo "完成。现在可以 sudo $HERE/install-prebuilt.sh"
