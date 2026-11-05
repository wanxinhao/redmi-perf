    /* ===== NVPCF software shim: 命名空间回退 =====
     *
     * 驱动把 ACPI 路径硬编码成 \_SB.NPCF._DSM。如果 BIOS 把 NPCF 挂在别的
     * 位置（例如 \_SB.PCI0.NPCF），这条路径必然扑空，表现出来就是那两条
     * "failed to get platform power mode / target temp from SBIOS" 断言。
     *
     * nvpcf_handle 是内核遍历 ACPI 命名空间时找到的 NPCF 对象句柄，
     * 用它 + "_DSM" 再试一次。
     */
    if ((rmStatus != NV_OK) && acpiNvpcfDsmFunction &&
        nvpcf_shim_fallback && nvpcf_handle)
    {
        pr_err("NVPCF-SHIM: hardcoded path \\_SB.NPCF._DSM failed, retry via namespace handle\n");
        rmStatus = nv_acpi_evaluate_dsm_method(nvpcf_handle, "_DSM", pAcpiDsmGuid, acpiDsmRev,
                                               acpiDsmSubFunction, argument3, inParamSize,
                                               NV_FALSE, NULL, pOutData, pSize);
        pr_err("NVPCF-SHIM: fallback status=0x%x size=%u\n", rmStatus, *pSize);
    }

    /* ===== NVPCF software shim: 应答改写 =====
     * ACPI 调用已经返回，pOutData 里是固件给的应答（和请求共用同一个缓冲区）。
     * 在这里就地修正 RM 解析不动的字段。
     */
    if (rmStatus == NV_OK)
    {
        nvpcf_shim_rewrite(acpiDsmSubFunction, acpiNvpcfDsmFunction,
                           pAcpiDsmGuid, pInParams, inParamSize,
                           pOutData, pSize);
    }

    /* 记录固件实际返回了什么——这是判断 RM 为什么拒绝的关键证据 */
    if (nvpcf_shim_log)
    {
        pr_err("NVPCF-SHIM: RESP status=0x%x size=%u\n", rmStatus, *pSize);
        if (rmStatus == NV_OK)
            nvpcf_shim_hexdump("RESP", (const NvU8 *)pOutData, *pSize);
    }

