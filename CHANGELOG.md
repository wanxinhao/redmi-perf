# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [0.2.0] — 2026-11-20

Arch Linux 与 NVIDIA 开源内核模块（`nvidia-open`）适配。

### 发行版适配

- 新增 `scripts/lib/common.sh`：发行版、内核头文件、编译器、NVIDIA 驱动布局探测
- `scripts/install-redmi-perf.sh`：支持 pacman / apt / dnf 依赖提示，
  内核头文件包自动识别（`linux-*-headers`），DKMS 版本号从 `dkms.conf` 读取
- **clang + ThinLTO 内核（CachyOS 等）**：自动追加 `LLVM=1 LD=ld.lld`；
  DKMS 3.x 也会自动追加 `LLVM=1`
- 新增 `--check` 模式：安装前只做环境检查，不改系统
- 卸载时清理 `modules-load.d`、旧版手工安装的模块
- 新增 Arch CI（`archlinux:latest` 容器里编译内核模块并跑 `--check`）

### nvidia-open（`kernel-open/` 源码布局）

- `patch_nv_acpi.py` / `unpatch_nv_acpi.py`：自动识别
  `kernel-open/nvidia/nv-acpi.c`（nvidia-open）与 `nvidia/nv-acpi.c`（.run），
  新增 `--check`；锚点缺失时打印具体锚点名
- `build.sh`：支持两种布局的模块产物路径；自动找源码树
  （`/usr/src/nvidia-*`、`/var/lib/dkms/nvidia/*/build`）；`KVER` 可指定目标内核；
  编译器版本不一致（`Failed CC version check`）时用 `IGNORE_CC_MISMATCH=1` 重试
- `install-prebuilt.sh`：安装目录自动选择（`updates/nvpcf-shim/` 或覆盖
  `updates/` 下的官方位置），安装前校验 vermagic 与 `nvpcf_shim_*` 参数，
  清理其他目录里的旧 shim 模块
- `restore-prebuilt.sh`：从 DKMS 当前版本的编译产物恢复官方模块（带版本校验），
  清理所有 shim 目录、pacman 钩子和辅助脚本
- 新增 Arch pacman 钩子：NVIDIA 驱动包升级后自动回退到官方模块，避免
  `Driver/library version mismatch`（日志 `/var/log/nvpcf-shim.log`）；
  安装前校验 `Operation` 合法值（Install/Upgrade/Remove），写坏钩子时跳过而不是
  让 pacman 整个事务报错
- `restore-prebuilt.sh` 找不到官方模块时，恢复旧版行为：先让 DKMS 重新安装一次
  再重试（仍失败才报错）
- `install-redmi-perf.sh`：升级到 0.2.0 时清理 DKMS 里残留的旧版本
  （0.1.0 / r2 等），避免内核升级时两个版本抢同一个模块名；非 `--check`
  模式下重新要求 root（和原版一致）

### 运行时修复（nvidia-open 620.73.04）

- 新增 `nvpcf_shim_pshare_init`（默认 1）：只在初始化窗口（GPS support `0x0`
  之后、首个 `PSHAREPARAMS 0x2a` 之前）清掉 PSHARESTATUS 的
  `UPDATE_LIMIT pending` 位。620 驱动在传感器初始化前就处理该 pending，
  导致开机各打一次 `failed to get target temp / platform power mode from SBIOS`；
  运行期的平台限制更新保持不变
- `after-reboot-check.sh` 增加初始化窗口日志和 `nvpcf_shim_pshare_init` 参数显示

### 修复

- 内核 7.3+ 自带的 `bitland-mifs-wmi` 会抢先绑定同一个 MIFS WMI 设备，
  导致 `redmi_perf_wmi` 加载但不 probe、`/sys/class/redmi_perf` 不存在：
  - `redmi-perf` 失败时给出解绑/重绑提示
  - `install-redmi-perf.sh` 检测到设备被其他驱动占用时自动解绑并重新绑定
  - PKGBUILD 的 DKMS 包安装 `/usr/lib/modules-load.d/redmi-perf.conf`，
    让模块在开机时尽早加载
  - `docs/arch-linux.md` 增加对应排错步骤
  - 已在 Arch + 内核 7.3.0-2-cachyos-cjktty + nvidia-open-dkms 620.73.04
    上实机验证：两条 SBIOS 断言消失，`init window` 日志只出现一次

### 打包

- 新增 AUR 风格 PKGBUILD `packaging/arch/redmi-perf-git`：
  拆分为 `redmi-perf-git`（Rust CLI）和 `redmi-perf-dkms-git`（DKMS 模块），
  遵循 Arch 的 DKMS / Rust / VCS 打包指南；`nvpcf-shim` 不打包（需手动安装）

### 文档

- 新增 [docs/arch-linux.md](docs/arch-linux.md)：Arch 依赖、clang 内核、
  nvidia-open 源码包区别、驱动升级、恢复流程
- README / troubleshooting / nvpcf-shim README 补充 Arch 与 nvidia-open 说明

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

[0.2.0]: https://github.com/wanxinhao/redmi-perf/releases/tag/v0.2.0
[0.1.0]: https://github.com/wanxinhao/redmi-perf/releases/tag/v0.1.0
