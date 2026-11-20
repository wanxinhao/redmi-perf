#!/usr/bin/env python3
"""还原 nv-acpi.c 到打补丁前的状态。

支持 nvidia-open（``kernel-open/nvidia/nv-acpi.c``）与旧版
（``nvidia/nv-acpi.c``）两种布局，自动识别。

环境变量：
  NV_SRC_ROOT   源码树根目录；不设时自动在 /usr/src 里找。
"""

import glob
import os
import shutil
import sys

LAYOUTS = (
    ("kernel-open", "kernel-open/nvidia/nv-acpi.c"),
    ("legacy", "nvidia/nv-acpi.c"),
)


def detect(root, rel):
    path = os.path.join(root, rel)
    return path if os.path.exists(path) else None


def autodetect_src_root():
    for pattern in ("/usr/src/nvidia-*", "/var/lib/dkms/nvidia/*/build"):
        for path in glob.glob(pattern):
            if not os.path.isdir(path):
                continue
            for _, rel in LAYOUTS:
                if detect(path, rel):
                    return path
    return None


def main():
    root = os.environ.get("NV_SRC_ROOT") or autodetect_src_root()
    if not root:
        print("找不到 NVIDIA 内核模块源码树（可用 NV_SRC_ROOT 指定）。", file=sys.stderr)
        return 1

    for _, rel in LAYOUTS:
        src = detect(root, rel)
        if not src:
            continue
        bak = src + ".orig"
        if not os.path.exists(bak):
            print(f"没有备份文件 {bak}，无需还原。", file=sys.stderr)
            return 1
        shutil.copy2(bak, src)
        print(f"已从 {bak} 还原 {src}")
        return 0

    print(f"{root} 下没有找到 nv-acpi.c", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
