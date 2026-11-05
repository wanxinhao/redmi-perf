# redmi_perf_wmi

内核模块：通过小米 MIFS WMI 接口读写**平台性能模式**。

模块本身只负责把请求转给固件、把应答暴露到 sysfs，
用户态交互在 [`redmi-perf`](../../cli/) 命令行工具里。

## 安装

```bash
cd ../..                       # 仓库根
sudo ./scripts/install-redmi-perf.sh --dkms
```

不带 `--dkms` 则只对当前内核生效。

## sysfs 接口

`/sys/class/redmi_perf/redmi_perf/`：

| 文件 | 说明 |
|---|---|
| `mode` | 读写，模式名或数字 |
| `available_modes` | 可用模式列表 |
| `status` | 上次固件状态字节、ACPI 状态、当前 method_id / cmd_id |
| `raw` | 读 = 上次的 OutData 十六进制；写 = 直接发原始 InData |
| `psu` | 供电方式 |

## 模块参数

全部可实时修改，**不用重编**：

```bash
redmi-perf params
sudo sh -c 'echo 2 > /sys/module/redmi_perf_wmi/parameters/method_id'
```

| 参数 | 说明 |
|---|---|
| `method_id` | WMI method id |
| `cmd_id` | MIFS 命令 id（`0x08` = 性能模式，`0x13` = PSU 类型）|
| `in_op_idx` | InData 里操作字节的偏移（`0xFA`/`0xFB`）|
| `in_cmd_idx` | InData 里命令 id 的偏移 |
| `in_val_idx` | InData 里参数值的偏移 |
| `out_status_idx` | OutData 里状态字节的偏移 |
| `out_value_idx` | OutData 里数值字节的偏移 |
| `auto_scan` | 自动扫描固件应答里的偏移（默认开）|

`auto_scan` 打开时，后面几个 `*_idx` 会被固件的实际布局覆盖 ——
所以固件改版调整布局也不会失效。

协议细节见 [../../docs/reverse-engineering.md](../../docs/reverse-engineering.md)。

## 为什么不用上游 `bitland-mifs-wmi`

上游那个驱动（2026-08 才合入）的 DMI 匹配表只有 `TM2135` / `TM2137`，
本机 `TM2211` 匹配不上；而且内核里只有 `CONFIG_REDMI_WMI`（仅热键）。
详见 [../../docs/reverse-engineering.md](../../docs/reverse-engineering.md)。

## 风险

模块只做查询和转发，不改硬件设置，风险很低。
回退：`sudo ./scripts/install-redmi-perf.sh --uninstall`
