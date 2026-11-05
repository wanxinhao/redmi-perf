# 参与开发

## 目录约定

```
kernel/redmi-perf-wmi/    内核模块（C）
cli/                      用户态命令行工具（Rust）
nvpcf-shim/               NVIDIA 驱动补丁（C 片段 + Python 补丁器）
scripts/                  安装与诊断脚本
tools/                    逆向分析工具
docs/                     文档
```

## 内核模块的规矩

**内核代码必须是 GPL-2.0**（要链接 Linux 内核）。用户态工具同许可。

改内核模块时注意：

- 所有 `pr_*` 日志前缀用 `redmi_perf_wmi:` 或 `NVPCF-SHIM:`，方便 `dmesg | grep`；
- **不要**在模块里做可能睡眠或加锁太久的操作 —— 这是热路径；
- 新增可调参数一律用 `module_param_named(..., 0644)`，让用户能在线改、
  不用重编；
- 提交前至少在两个内核版本上编译通过。

## NVPCF 补丁的规矩

`patch_nv_acpi.py` 靠**源码锚点**定位插入点，驱动版本变了锚点可能对不上。
所以：

- **锚点找不到时必须中止**，不能「猜一个位置插进去」；
- 补丁必须**幂等**（重复跑不重复插入）；
- 改 `shim_block.c` 后要同步更新 `nvpcf-shim/README.md` 里的参数表；
- `nvpcf_shim_ctr0b` 默认必须是 `0`（counter `0x0b` 是目标温度不是功耗）。

## 提交前自检

```bash
make -C /lib/modules/$(uname -r)/build M=$PWD/kernel/redmi-perf-wmi modules
cargo build --release --manifest-path cli/Cargo.toml
shellcheck scripts/*.sh nvpcf-shim/*.sh
```

## 报告硬件差异

固件行为各家不同。如果你的机器上行为不一样，请开 issue 并附上：

```bash
sudo dmidecode -s system-product-name
sudo dmidecode -s bios-version
sudo ./scripts/probe.sh
```

## License

提交即表示你同意你的贡献以 GPL-2.0-only 授权。
