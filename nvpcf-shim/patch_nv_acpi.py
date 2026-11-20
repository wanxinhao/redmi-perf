#!/usr/bin/env python3
"""给 NVIDIA 内核模块的 nv-acpi.c 打 NVPCF shim 补丁（幂等）。

支持两种源码布局，自动识别：

  * NVIDIA 开放内核模块（open-gpu-kernel-modules，也就是 Arch 的
    ``nvidia-open-dkms``）：``<root>/kernel-open/nvidia/nv-acpi.c``
  * 官方 .run / 发行版打包的完整源码树：``<root>/nvidia/nv-acpi.c``

环境变量：
  NV_SRC_ROOT   源码树根目录。build.sh 会设置；不设时自动在 /usr/src 里找。
  NV_DRY_RUN=1  只检查能不能打，不写文件。

用法：
  python3 patch_nv_acpi.py [--check]
"""

import glob
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# nv-acpi.c 在两种布局下的相对路径，按优先级排列
LAYOUTS = (
    ("kernel-open", "kernel-open/nvidia/nv-acpi.c"),
    ("legacy", "nvidia/nv-acpi.c"),
)

ANCHOR_SHIM = "#define ACPI_NVPCF_EVENT_CHANGE    0xC0\n"
ANCHOR_HOOK = "    rmStatus = os_alloc_mem((void **)&argument3, inParamSize);\n"
ANCHOR_FALLBACK = "    os_free_mem(argument3);\n"
MARKER = "NVPCF software shim"


def detect_layout(root):
    """返回 (布局名, nv-acpi.c 路径) 或 (None, None)。"""
    for name, rel in LAYOUTS:
        path = os.path.join(root, rel)
        if os.path.exists(path):
            return name, path
    return None, None


def autodetect_src_root():
    candidates = []
    for pattern in ("/usr/src/nvidia-*", "/var/lib/dkms/nvidia/*/build"):
        for path in glob.glob(pattern):
            if not os.path.isdir(path):
                continue
            name, _ = detect_layout(path)
            if name:
                candidates.append((path, name))
    if not candidates:
        return None
    # 版本号最大的优先；kernel-open 布局优先
    candidates.sort(key=lambda c: (c[1] == "kernel-open", c[0]), reverse=True)
    return candidates[0][0]


def main(argv):
    dry_run = os.environ.get("NV_DRY_RUN") == "1" or "--check" in argv

    root = os.environ.get("NV_SRC_ROOT") or autodetect_src_root()
    if not root:
        print(
            "找不到 NVIDIA 内核模块源码树。\n"
            "  Arch: 装源码包 nvidia-open-dkms（预编译的 nvidia-open 没有源码）；\n"
            "  其他: 或用 NV_SRC_ROOT=/usr/src/nvidia-<版本> 指定。",
            file=sys.stderr,
        )
        return 1

    layout, src = detect_layout(root)
    if not src:
        print(f"{root} 下既没有 kernel-open/nvidia/nv-acpi.c 也没有 nvidia/nv-acpi.c", file=sys.stderr)
        return 1

    bak = src + ".orig"

    with open(src, "r", encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()

    if MARKER in text:
        print(f"已经打过补丁了（{layout} 布局），跳过。")
        return 0

    anchors = (
        ("ACPI_NVPCF_EVENT_CHANGE 定义", ANCHOR_SHIM),
        ("os_alloc_mem(argument3) 调用", ANCHOR_HOOK),
        ("os_free_mem(argument3) 调用", ANCHOR_FALLBACK),
    )
    missing = [name for name, anchor in anchors if anchor not in text]
    if missing:
        print(
            f"源码结构和预期不符（{layout} 布局），缺少锚点: {', '.join(missing)}。\n"
            f"  nv-acpi.c: {src}\n"
            "  通常是驱动版本变化导致，请开 issue 带上驱动版本。",
            file=sys.stderr,
        )
        return 2

    if not os.path.exists(bak) and not dry_run:
        shutil.copy2(src, bak)
        print(f"已备份原文件到 {bak}")

    if dry_run:
        print(f"{layout} 布局，锚点齐全，可以打补丁: {src}")
        return 0

    with open(os.path.join(HERE, "shim_block.c"), "r", encoding="utf-8") as fh:
        shim = fh.read()
    with open(os.path.join(HERE, "hook_block.c"), "r", encoding="utf-8") as fh:
        hook = fh.read()
    with open(os.path.join(HERE, "fallback_block.c"), "r", encoding="utf-8") as fh:
        fallback = fh.read()

    text = text.replace(ANCHOR_SHIM, ANCHOR_SHIM + "\n" + shim, 1)
    text = text.replace(ANCHOR_HOOK, hook + ANCHOR_HOOK, 1)
    text = text.replace(ANCHOR_FALLBACK, fallback + ANCHOR_FALLBACK, 1)

    with open(src, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)

    print(f"补丁已应用（{layout} 布局）: {src}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
