#!/usr/bin/env python3
"""给 NVIDIA Open 内核模块的 nv-acpi.c 打 NVPCF shim 补丁（幂等）。"""

import os
import shutil
import sys

SRC_ROOT = os.environ.get("NV_SRC_ROOT", "/usr/src/nvidia-595.112.07")
SRC = os.path.join(SRC_ROOT, "nvidia", "nv-acpi.c")
BAK = os.path.join(SRC_ROOT, "nvidia", "nv-acpi.c.orig")
HERE = os.path.dirname(os.path.abspath(__file__))

ANCHOR_SHIM = "#define ACPI_NVPCF_EVENT_CHANGE    0xC0\n"
ANCHOR_HOOK = "    rmStatus = os_alloc_mem((void **)&argument3, inParamSize);\n"
ANCHOR_FALLBACK = "    os_free_mem(argument3);\n"
MARKER = "NVPCF software shim"


def main() -> int:
    if not os.path.exists(SRC):
        print(f"找不到 {SRC}", file=sys.stderr)
        return 1

    with open(SRC, "r", encoding="utf-8", errors="surrogateescape") as fh:
        text = fh.read()

    if MARKER in text:
        print("已经打过补丁了，跳过。")
        return 0

    if not os.path.exists(BAK):
        shutil.copy2(SRC, BAK)
        print(f"已备份原文件到 {BAK}")

    with open(os.path.join(HERE, "shim_block.c"), "r", encoding="utf-8") as fh:
        shim = fh.read()
    with open(os.path.join(HERE, "hook_block.c"), "r", encoding="utf-8") as fh:
        hook = fh.read()
    with open(os.path.join(HERE, "fallback_block.c"), "r", encoding="utf-8") as fh:
        fallback = fh.read()

    if ANCHOR_SHIM not in text or ANCHOR_HOOK not in text or ANCHOR_FALLBACK not in text:
        print("源码结构和预期不符（锚点找不到），中止。", file=sys.stderr)
        return 2

    text = text.replace(ANCHOR_SHIM, ANCHOR_SHIM + "\n" + shim, 1)
    text = text.replace(ANCHOR_HOOK, hook + ANCHOR_HOOK, 1)
    text = text.replace(ANCHOR_FALLBACK, fallback + ANCHOR_FALLBACK, 1)

    with open(SRC, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)

    print(f"补丁已应用: {SRC}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
