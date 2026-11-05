#!/usr/bin/env python3
"""还原 nv-acpi.c 到打补丁前的状态。"""

import os
import shutil
import sys

SRC_ROOT = os.environ.get("NV_SRC_ROOT", "/usr/src/nvidia-595.112.07")
SRC = os.path.join(SRC_ROOT, "nvidia", "nv-acpi.c")
BAK = os.path.join(SRC_ROOT, "nvidia", "nv-acpi.c.orig")


def main() -> int:
    if not os.path.exists(BAK):
        print("没有备份文件，无需还原。", file=sys.stderr)
        return 1
    shutil.copy2(BAK, SRC)
    print(f"已从 {BAK} 还原 {SRC}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
