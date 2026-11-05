# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.1.0] — 2026-11-05

首个公开版本。

### 内核模块 `redmi_perf_wmi`

- 通过 MIFS WMI 接口（GUID `B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B`，
  ACPI 方法 `MiInterface`）读写平台性能模式
- 命令 `0x08` = 性能模式，`0x13` = PSU 类型
- 应答偏移自动扫描（`auto_scan`），固件改版不会失效
- 全部协议参数可用 `module_param(0644)` 实时调整

### 命令行工具 `redmi-perf`

- `get` / `set` / `list` / `status` / `psu` / `params` / `raw`
- Rust 实现，零外部依赖，单静态二进制

### `nvpcf-shim`

- 给 NVIDIA 内核模块打补丁，在 ACPI 应答返回后就地补齐固件少给的字节
- 消除 `failed to get target temp from SBIOS` 与
  `failed to get platform power mode from SBIOS` 两条断言
- 补丁器带源码锚点校验，驱动版本不匹配时中止而不是乱改
- 全部 shim 参数可在运行时调整，不用重编、不用重启

### 文档

- MIFS WMI 协议格式与实测数据
- NVPCF / GPS counter 结构、断言成因、被排除的死路
- 灾难恢复流程（开不了机怎么办）

[0.1.0]: https://github.com/wanxinhao/redmi-perf/releases/tag/v0.1.0
