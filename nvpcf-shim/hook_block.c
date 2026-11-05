    /* ===== NVPCF software shim: 记录所有 _DSM 调用 =====
     * 不只 NVPCF：平台请求处理器(pfmreqhndlrCallACPI)用的是 GPU 自己
     * ACPI 设备上的 _DSM，funcId 不是 NVPCF，子功能是 0x1c/0x20/0x2a/
     * 0x2b/0x2c —— "failed to get platform power mode / target temp
     * from SBIOS" 这两条断言就出自这条路径。
     */
    if (nvpcf_shim_log)
    {
        pr_err("NVPCF-SHIM: REQ rev=0x%x sub=0x%x npc=%u inLen=%u outCap=%u guid=%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n",
               acpiDsmRev, acpiDsmSubFunction, (NvU32)acpiNvpcfDsmFunction,
               inParamSize, *pSize,
               pAcpiDsmGuid[3], pAcpiDsmGuid[2], pAcpiDsmGuid[1], pAcpiDsmGuid[0],
               pAcpiDsmGuid[5], pAcpiDsmGuid[4],
               pAcpiDsmGuid[7], pAcpiDsmGuid[6],
               pAcpiDsmGuid[8], pAcpiDsmGuid[9],
               pAcpiDsmGuid[10], pAcpiDsmGuid[11], pAcpiDsmGuid[12],
               pAcpiDsmGuid[13], pAcpiDsmGuid[14], pAcpiDsmGuid[15]);
        nvpcf_shim_hexdump("REQ-in", (const NvU8 *)pInParams, inParamSize);
    }

    /* ===== NVPCF software shim: 强制改写 revision =====
     * BIOS 可能只实现了 1.0，而 RM 用 2.0 去问。
     */
    if (acpiNvpcfDsmFunction && nvpcf_shim_rev)
    {
        pr_err("NVPCF-SHIM: rewrite rev 0x%x -> 0x%x\n", acpiDsmRev, nvpcf_shim_rev);
        acpiDsmRev = nvpcf_shim_rev;
    }

