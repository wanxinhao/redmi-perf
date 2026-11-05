/* ===== NVPCF software shim (redmi-perf project, local patch) =====
 *
 * 插进 NVIDIA Open 内核模块的 nvidia/nv-acpi.c。
 *
 * 背景
 * ----
 * 小米/Redmi 的 BIOS 实现了 NVPCF 的 ACPI 接口 \_SB.NPCF._DSM，但动态功耗表
 * (NVPCF func 0x2) 的条目内容相对 RM 期望的布局整体后移了 6 字节，导致 RM
 * 解析出来的 TGP 字段全是 0，只能退回驱动内置默认功耗 55W：
 *     Default Power Limit : 55.00 W
 *
 * 同时，GPS (GPU Platform Settings) 的 0x2a 读计数器接口返回的
 * "platform power mode" 是 0（高字节=允许模式位掩码 0，低字节=当前模式 0），
 * RM 拿不到可用模式，于是断言：
 *     PlatformRequestHandler failed to get platform power mode from SBIOS
 *     PlatformRequestHandler failed to get target temp from SBIOS
 *
 * 做法
 * ----
 * 在胶合层 (nv_acpi_dsm_method) 记录所有 _DSM 调用，并在 ACPI 调用返回后
 * 就地改写应答缓冲区：
 *   1) NVPCF func 0x2 (动态功耗表)：把 BIOS 放在错位位置的 3 个 int16 功耗
 *      字段搬回 RM 期望的位置，并可覆盖成我们想要的 TGP。
 *   2) GPS func 0x2a 且应答第 0 字节 == 1 (platform power mode)：
 *      改写应答 offset 8 的 u32 为 (允许模式位掩码 << 8) | 当前模式。
 *
 * 单位：NVPCF 的功耗字段以 125 mW 为单位（RM 侧 imul $0x7d）。
 */

static unsigned int nvpcf_shim_log  = 1;
static unsigned int nvpcf_shim_mode = 0;   /* 0 = 只记录, 1 = 改写应答 */
static unsigned int nvpcf_shim_tgpa = 0;   /* TGP on AC  (125 mW 单位), 0 = 保持原值 */
static unsigned int nvpcf_shim_tgpd = 0;   /* TGP on DC  (125 mW 单位), 0 = 保持原值 */
static unsigned int nvpcf_shim_tgp3 = 0;   /* 第 3 个功耗字段, 0 = 保持原值 */
static unsigned int nvpcf_shim_shift = 0;  /* 1 = 把错位的功耗字段搬回 RM 期望位置 */
static unsigned int nvpcf_shim_ppm  = 0;   /* platform power mode u16: (掩码<<8)|模式, 0 = 不改 */
static unsigned int nvpcf_shim_ppm_enable = 0; /* 1 = 给 counter 0x13 打上"支持"位 */
static unsigned int nvpcf_shim_ctr0b = 0;  /* 覆盖 GPS counter 0x0b 的值, 0 = 保持原值 */
static unsigned int nvpcf_shim_fallback = 1; /* 硬编码路径失败时用命名空间句柄重试 */
static unsigned int nvpcf_shim_rev = 0;   /* 非 0: 强制改写 DSM revision */

module_param_named(nvpcf_shim_log,   nvpcf_shim_log,   uint, 0644);
module_param_named(nvpcf_shim_mode,  nvpcf_shim_mode,  uint, 0644);
module_param_named(nvpcf_shim_tgpa,  nvpcf_shim_tgpa,  uint, 0644);
module_param_named(nvpcf_shim_tgpd,  nvpcf_shim_tgpd,  uint, 0644);
module_param_named(nvpcf_shim_tgp3,  nvpcf_shim_tgp3,  uint, 0644);
module_param_named(nvpcf_shim_shift, nvpcf_shim_shift, uint, 0644);
module_param_named(nvpcf_shim_ppm,   nvpcf_shim_ppm,   uint, 0644);
module_param_named(nvpcf_shim_ppm_enable, nvpcf_shim_ppm_enable, uint, 0644);
module_param_named(nvpcf_shim_ctr0b, nvpcf_shim_ctr0b, uint, 0644);
module_param_named(nvpcf_shim_fallback, nvpcf_shim_fallback, uint, 0644);
module_param_named(nvpcf_shim_rev,   nvpcf_shim_rev,   uint, 0644);

MODULE_PARM_DESC(nvpcf_shim_log,   "NVPCF shim: 记录 DSM 流量 (0/1)");
MODULE_PARM_DESC(nvpcf_shim_mode,  "NVPCF shim: 0=只记录 1=改写应答");
MODULE_PARM_DESC(nvpcf_shim_tgpa,  "NVPCF shim: TGP on AC (125mW 单位), 0=保持原值");
MODULE_PARM_DESC(nvpcf_shim_tgpd,  "NVPCF shim: TGP on DC (125mW 单位), 0=保持原值");
MODULE_PARM_DESC(nvpcf_shim_tgp3,  "NVPCF shim: 第 3 个功耗字段, 0=保持原值");
MODULE_PARM_DESC(nvpcf_shim_shift, "NVPCF shim: 把错位的功耗字段搬回 RM 期望位置 (0/1)");
MODULE_PARM_DESC(nvpcf_shim_ppm,   "NVPCF shim: platform power mode u16 (掩码<<8|模式), 0=不改");
MODULE_PARM_DESC(nvpcf_shim_ppm_enable, "NVPCF shim: 给 GPS 支持应答打开 counter 0x13 位 (0/1)");
MODULE_PARM_DESC(nvpcf_shim_ctr0b, "NVPCF shim: 覆盖 GPS counter 0x0b 的值, 0=保持原值");
MODULE_PARM_DESC(nvpcf_shim_fallback, "NVPCF shim: 用 ACPI 命名空间句柄重试 (0/1)");
MODULE_PARM_DESC(nvpcf_shim_rev,   "NVPCF shim: 强制 DSM revision (0=保持原样)");

/* 把缓冲区打成一行十六进制，方便 grep 一次抓到（分多行会被过滤掉） */
static void nvpcf_shim_hexdump(const char *tag, const NvU8 *buf, NvU16 len)
{
    char line[512];
    NvU16 i;
    NvU32 o = 0;

    if (buf == NULL)
        return;
    if (len > 96)
        len = 96;

    for (i = 0; i < len; i++)
        o += snprintf(line + o, sizeof(line) - o, "%s%02x", (i ? " " : ""), buf[i]);
    pr_err("NVPCF-SHIM: %s (%u bytes):%s\n", tag, (NvU32)len, line);
}

/* GPS = a3132d01-8cda-49ba-a52e-bc9d46df6b81 */
static const NvU8 nvpcf_shim_gps_guid[16] = {
    0x01, 0x2d, 0x13, 0xa3, 0xda, 0x8c, 0xba, 0x49,
    0xa5, 0x2e, 0xbc, 0x9d, 0x46, 0xdf, 0x6b, 0x81
};

static NvBool nvpcf_shim_guid_is(const NvU8 *guid, const NvU8 *want)
{
    if (guid == NULL)
        return NV_FALSE;
    return (memcmp(guid, want, 16) == 0) ? NV_TRUE : NV_FALSE;
}

static void nvpcf_shim_put16(NvU8 *p, NvU32 v)
{
    p[0] = (NvU8)(v & 0xff);
    p[1] = (NvU8)((v >> 8) & 0xff);
}

static NvU32 nvpcf_shim_get16(const NvU8 *p)
{
    return (NvU32)p[0] | ((NvU32)p[1] << 8);
}

static NvU32 nvpcf_shim_get32(const NvU8 *p)
{
    return (NvU32)p[0] | ((NvU32)p[1] << 8) |
           ((NvU32)p[2] << 16) | ((NvU32)p[3] << 24);
}

static void nvpcf_shim_put32(NvU8 *p, NvU32 v)
{
    p[0] = (NvU8)(v & 0xff);
    p[1] = (NvU8)((v >> 8) & 0xff);
    p[2] = (NvU8)((v >> 16) & 0xff);
    p[3] = (NvU8)((v >> 24) & 0xff);
}

/*
 * NVPCF func 0x2 (动态功耗表) 应答改写。
 *
 * 应答布局 (RM 侧 _configUnpackStructure + schema "5b"/"4d"/"7d"):
 *   [0x00]      版本
 *   [0x01]      头长度 (5)
 *   [0x02]      公共区长度 (0x10)
 *   [0x03]      条目长度 (0x1c)
 *   [0x04]      条目数
 *   [0x05..0x14] 公共区 (16 字节)
 *   [0x15..0x30] 条目 0 (28 字节)
 *
 * RM 对条目的读法:
 *   entry[0x00..0x03] u32  标志位 (bit8 -> obj[0x48], bit9 -> obj[0x49])
 *   entry[0x04..0x05] i16  -> obj[0x18]  x125 mW   (RM 认为是 TGP on AC)
 *   entry[0x08..0x09] i16  -> obj[0x1c]  x125 mW   (RM 认为是 TGP on DC)
 *   entry[0x0c..0x0d] i16  -> obj[0x20]  x125 mW
 *   entry[0x10..0x13] u32  -> obj[0x34]
 *   entry[0x14..0x17] u32  -> obj[0x3c]
 *   entry[0x18..0x1b] u32  -> obj[0x44]
 *
 * 而这台机器的 BIOS 把 3 个功耗值放在 entry[0x0a], entry[0x0e], entry[0x12]
 * (整体后移 6 字节)，所以 RM 读到的是 0/0/0，只能用内置默认 55W。
 *
 * ⚠ 2026-11-05 复核结论（反汇编 nv-kernel.o_binary 0x332668 起）：
 * 这一代驱动自己就解不开这张表 —— case 3 的解析里，条目数在 obj+0x130，
 * 但只有 _configUnpackStructure("4d") 写过 obj+0x140..0x131，obj+0x130
 * 从头到尾都是 0，所以条目循环 (test %r10d,%r10d; jne) 一次都不进，
 * obj[0x18]/[0x1c]/[0x20] 永远不会被填。同一段代码还要求应答头是
 * [0]=版本(u32) [4]=5 [8]=16 [12]=28 的展开格式，而 BIOS 给的是
 * 24 05 10 1c 01 的紧凑格式，版本检查就先挂了。
 * => 搬字段没有意义（shift 默认 0），平台功耗表这条路在本驱动上是死路。
 * 真正在生效的是 nvidia-powerd 走 EC 的那条路（80/115/125W）。
 *
 * 实际 BIOS 应答:
 *   entry[0x0a..0x0b] = 440  -> 440*125mW = 55W  <- 正是 nvidia-smi 报的 Default Power Limit
 *   entry[0x0e..0x0f] = 80
 *   entry[0x12..0x13] = 0xffd8
 */
static void nvpcf_shim_fix_nvpcf_dyn(NvU8 *out, NvU16 size)
{
    NvU8 *entry;

    if (size < 0x31)
        return;
    if (out[1] != 0x05 || out[2] != 0x10 || out[3] != 0x1c)
        return;

    entry = out + 0x15;

    nvpcf_shim_hexdump("DYN-before", out, size);

    if (nvpcf_shim_shift)
    {
        /* 把 BIOS 放在错位位置的 2 个功耗 int16 搬回 RM 期望的槽位 */
        NvU32 v0 = nvpcf_shim_get16(entry + 0x0a);
        NvU32 v1 = nvpcf_shim_get16(entry + 0x0e);

        pr_err("NVPCF-SHIM: DYN relocate %u/%u -> %u/%u (RM slots 4/8)\n",
               v0, v1,
               nvpcf_shim_get16(entry + 0x04),
               nvpcf_shim_get16(entry + 0x08));

        nvpcf_shim_put16(entry + 0x04, v0);
        nvpcf_shim_put16(entry + 0x08, v1);
    }

    /* 覆盖功耗值: 同时写 RM 槽位和 BIOS 原槽位, 无论 RM 用哪种布局都能命中 */
    if (nvpcf_shim_tgpa)
    {
        nvpcf_shim_put16(entry + 0x04, nvpcf_shim_tgpa);
        nvpcf_shim_put16(entry + 0x0a, nvpcf_shim_tgpa);
    }
    if (nvpcf_shim_tgpd)
    {
        nvpcf_shim_put16(entry + 0x08, nvpcf_shim_tgpd);
        nvpcf_shim_put16(entry + 0x0e, nvpcf_shim_tgpd);
    }
    if (nvpcf_shim_tgp3)
    {
        nvpcf_shim_put16(entry + 0x0c, nvpcf_shim_tgp3);
        nvpcf_shim_put16(entry + 0x12, nvpcf_shim_tgp3);
    }

    nvpcf_shim_hexdump("DYN-after ", out, size);
}

/*
 * GPS func 0x2a = 读 perf sensor counter。
 *
 * 这一代驱动对 0x2a 有两种调用，靠请求缓冲区区分：
 *
 *  A) 支持位查询 (pfmreqhndlrInitSensors，初始化时一次)
 *     请求 in[0..3] == 0x00010101  (RM 的 desc[4..7] 模板)
 *     应答 in[0..3] 是"支持哪些 perf counter 槽"的位掩码:
 *        bit 8  (0x00100) -> 槽 0 = RM counter 0x0b
 *        bit 16 (0x10000) -> 槽 8 = RM counter 0x13 (platform power mode)
 *     RM 取 (resp[0..3] & 0x10100) 存进 obj[0x6c0]，采样时用
 *     mask = obj[0x6c0] | 2 去问 BIOS。
 *     本机 BIOS 只给了 bit 8 -> counter 0x13 永远"不支持" ->
 *     pfmreqhndlrGetPerfSensorCounterById(0x13) 返回 NV_ERR_INVALID_DATA ->
 *     断言 "failed to get platform power mode from SBIOS" 每次必炸。
 *
 *  B) 采样 (pfmreqhndlrSampleCounter，周期性)
 *     请求 in[0..3] == mask
 *     应答布局:
 *        in[0x00]      计数器序号
 *        in[0x01] bit0 = 有效位
 *        in[0x08..0x0b] u32  槽 0 (counter 0x0b) 的值 —— 本机是 87
 *        in[0x28..0x2b] u32  槽 8 (counter 0x13) 的值 —— BIOS 只回 40 字节，缺失
 *     RM 把 in[0x08..0x0b] 写进 counter 0x0b 的 value 字段，然后
 *     _pfmreqhndlrUpdateTgpuLimit 把它 <<8 用 ctrl cmd 0x20800ad1 下发给 GPU。
 *
 * 注入点:
 *   nvpcf_shim_ctr0b      -> 改 counter 0x0b 的值 (看 GPU 功耗上限是否跟着变)
 *   nvpcf_shim_ppm_enable -> 给支持应答补上 bit 16, 让 counter 0x13 可用
 *   nvpcf_shim_ppm        -> 槽 8 的值 = (允许模式掩码 << 8) | 当前模式
 */
static void nvpcf_shim_fix_gps_2a(const NvU8 *req, NvU16 reqSize,
                                  NvU8 *out, NvU16 *pSize)
{
    NvU32 mask;
    NvU32 ver;

    if (req == NULL || reqSize < 4 || out == NULL || pSize == NULL)
        return;

    mask = nvpcf_shim_get32(req);

    /* A) 支持位查询 */
    if (mask == 0x00010101u)
    {
        if (!nvpcf_shim_ppm_enable || *pSize < 4)
            return;

        ver = nvpcf_shim_get32(out);
        if ((ver & 0x10000u) == 0)
        {
            nvpcf_shim_put32(out, ver | 0x10000u);
            pr_err("NVPCF-SHIM: GPS support 0x%x -> 0x%x (enable counter 0x13 / platform power mode)\n",
                   ver, ver | 0x10000u);
        }
        return;
    }

    /* B) 采样应答 */
    if (*pSize < 12)
        return;

    /* 槽 0 (counter 0x0b)：RM 会把它 <<8 下发给 GPU */
    if (nvpcf_shim_ctr0b)
    {
        pr_err("NVPCF-SHIM: GPS counter 0x0b: %u -> %u (RM 会 x256 后发 ctrl 0x20800ad1)\n",
               nvpcf_shim_get32(out + 8), nvpcf_shim_ctr0b);
        nvpcf_shim_put32(out + 8, nvpcf_shim_ctr0b);
    }

    /* 槽 8 (counter 0x13 / platform power mode)：BIOS 少回 4 字节，我们补上。
     * 请求缓冲区和应答缓冲区是同一个，inLen==44 说明 RM 给了 44 字节，
     * 所以写 out[40..43] 是安全的。 */
    if (nvpcf_shim_ppm_enable && nvpcf_shim_ppm)
    {
        if (reqSize < 44)
            return;

        ver = nvpcf_shim_get32(out);
        nvpcf_shim_put32(out, ver | 0x10000u);   /* 告诉 RM 槽 8 有数据 */
        nvpcf_shim_put32(out + 40, nvpcf_shim_ppm);
        if (*pSize < 44)
            *pSize = 44;

        pr_err("NVPCF-SHIM: PPM slot8 = 0x%x (mask=0x%02x mode=%u), resp size -> %u\n",
               nvpcf_shim_ppm, (nvpcf_shim_ppm >> 8) & 0xff, nvpcf_shim_ppm & 0xff,
               *pSize);
    }
}

/* 在 ACPI 调用返回后就地改写应答 */
static void nvpcf_shim_rewrite(NvU32 acpiDsmSubFunction,
                                NvBool acpiNvpcfDsmFunction,
                                NvU8  *pAcpiDsmGuid,
                                void  *pInParams,
                                NvU16  inParamSize,
                                void  *pOutData,
                                NvU16 *pSize)
{
    NvU8 *out = (NvU8 *)pOutData;

    if (!nvpcf_shim_mode)
        return;
    if (out == NULL || pSize == NULL || *pSize == 0)
        return;

    /* NVPCF func 0x2 = 动态功耗表 */
    if (acpiNvpcfDsmFunction && acpiDsmSubFunction == 0x02)
    {
        nvpcf_shim_fix_nvpcf_dyn(out, *pSize);
        return;
    }

    /* GPS func 0x2a = 读 perf sensor counter */
    if (!acpiNvpcfDsmFunction && acpiDsmSubFunction == 0x2a &&
        nvpcf_shim_guid_is(pAcpiDsmGuid, nvpcf_shim_gps_guid))
    {
        nvpcf_shim_fix_gps_2a((const NvU8 *)pInParams, inParamSize, out, pSize);
        return;
    }
}
