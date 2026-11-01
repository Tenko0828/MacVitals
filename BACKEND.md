# VitalsCore 后端

`Models.swift` 保持原样。公开入口是 `VitalsMonitor`，无第三方依赖。私有 C ABI 封装在 `Sources/CVitalsSupport`，经 `dlopen/dlsym` 加载，符号或权限不可用时降级。

| 数据 | 来源与口径 |
| --- | --- |
| CPU | `host_processor_info` 的 user/system/idle/nice 差值；`hw.perflevelN`；loadavg；Mach processor set 线程数和 libproc 进程数 |
| 频率 | `pmgr` 的 `acc-clusters`、`voltage-statesN-sram`；兼容 Hz/kHz；IOReport 活跃状态驻留时间加权，排除 IDLE/DOWN/OFF |
| GPU | IOAccelerator PerformanceStatistics、gpu-core-count；IOReport GPU Stats |
| 功耗 | IOReport Energy Model 的 nJ/µJ/mJ/J 除以采样间隔；SMC PSTR/PDTR/PDBR；AppleSmartBattery PowerTelemetryData 作为整机、输入功率后备 |
| 温度与风扇 | HID usage page 0xff00 / usage 5，温度事件 15；SMC 枚举 T/F key，支持 flt、sp78、fpe2 等；按原始 key 去重、分组、过滤无效值 |
| 内存 | HOST_VM_INFO64；App = internal − purgeable，已用 = App + wired + compressor，缓存 = external + purgeable；vm.swapusage、memorystatus |
| 磁盘 | IOBlockStorageDriver Statistics，只取 Whole 物理 IOMedia，排除虚拟盘；smartctl JSON 读取健康，NVMe data unit = 512000 字节 |
| 网络 | getifaddrs、NET_RT_IFLIST2 的 64 位计数器；SystemConfiguration；ipconfig Wi-Fi 摘要；默认路由和 resolv.conf 后备 |
| 电池 | IOPowerSources、AppleSmartBattery、BatteryData、适配器详情；原始嵌套信息完整保留在 sections |
| 进程 | proc_listallpids、PROC_PIDTASKINFO、rusage V6/V4；CPU mach ticks 经 timebase 换算；phys_footprint；getpwuid_r；PID 复用重置基线 |
| 静态与软件 | sysctl、IORegistry、system_profiler、sw_vers、uname、安全工具、开发工具版本、Homebrew、App 数量 |
| 外设 | 一次 system_profiler 请求 7 类外设，递归展开设备和蓝牙电量，缓存 60 秒 |

每个 monitor 有独立差值基线。snapshot 与 processes 分别加锁；静态缓存分别加锁。HID/SMC/IOReport 连接只在硬件采样器串行队列使用，后台每秒刷新；snapshot 只短暂锁住已完成的帧，不执行子进程。销毁实例会停止定时器并释放连接。慢接口可并发调用；machine 首次缓存，software 缓存 60 秒。

所有子进程不经过 shell，默认 5 秒超时，system_profiler 为 20 秒。超时杀死直接子进程；临时输出文件避免管道阻塞。smartctl 缺失时返回 unavailable 并提示 `brew install smartmontools`；SMART 非零退出码仍尝试解析有效 JSON。

## 构建和检查

常规环境：

```sh
swift build -c release
.build/release/vitals-dump > /tmp/vitals.json
scripts/check-backend.sh
```

检查程序仅依赖 CLT，覆盖 NVMe 单位与 2% 寿命、失败降级、温度过滤/去重/分组、Hz/kHz、两种电池温度单位、计数器重置、子进程超时进程 CPU timebase 忙循环实测以及原生接口并发调用。

本次受限执行环境禁止写默认编译缓存，并拒绝 dsymutil；以下命令已完成整个项目 release 构建：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/macvitals-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/macvitals-swift-cache \
swift build -c release --disable-sandbox -debug-info-format none \
  --cache-path /tmp/macvitals-spm-cache \
  --config-path /tmp/macvitals-spm-config \
  --security-path /tmp/macvitals-spm-security
```

这里的 `--disable-sandbox` 只关闭 SwiftPM 的构建子进程沙盒，不会解除当前执行环境的系统访问限制。CLT/Swift Build 仍报告它自动添加的两个不存在的 Developer 搜索目录；后端 Swift/C 源码无编译警告。也验证了旧 native 构建引擎可以完成包含前端的 release 构建。

## 实机验证（M5 Pro / macOS 27.0.1）

在沙盒外实测确认：温度传感器约 270 个、两个风扇、CPU 簇与 GPU 实时频率、GPU 功耗、整机功耗、SMART（已用寿命 2%、累计写入 38.9 TB）、内存压力和交换区、电池与适配器、外设都能读到；snapshot 约 1 ms，processes 约 100 ms（含 ps 补齐）。

实测后做的调整：

- **CPU 功耗**：PMGR 的 CPU / ANE / DRAM 能量计数器在这台机器上不更新（开机累计值长时间不变），只有 GPU 通道（AGX 驱动）可信。用 CPU 和 GPU 压力测试对比 SMC 功耗键：`PPMC` 只随 CPU 涨，`PHPC` ≈ CPU 簇 + 共享 + GPU。因此 SoC 合计取 `PHPC`，CPU 用「SoC 合计 − GPU」估算并设 `cpuEstimated = true`；ANE / DRAM 给 nil。
- **温度汇总**：CPU / GPU 最高温只统计核心传感器（`Tp*`、`PMU tdie*` / `Tg*`、`PMU tdev*`）。`TCMb` 常比核心高 10°C 以上，含义不明，只列出不参与汇总；`Ts0P` / `Ts1P` 是掌托温度，归入机身。
- **采样开销**：每秒只读核心 SMC key（CPU / GPU 核心温度、SSD、电池、风扇、功耗），全部 SMC 和 HID 传感器每 5 秒扫一次，App 总占用从约 20% 降到 3–5%。
- **其他用户的进程**：libproc 读不到 root、_windowserver 等进程的 CPU 时间，改用 setuid 的 `/bin/ps -A -o pid,time,rss` 补齐。
- smartctl 对苹果 SSD 每次都报 `GetLogPage failed`，属正常现象，不再作为提示显示。

## 限制与解释

- 神经引擎核心数没有稳定来源，保留 nil。
- energyImpact 是 billed energy 的每秒毫焦耳近似值（mW），不是活动监视器的专有评分；没有可用累计能量时为 nil。
- SMC/HID 仅对可确认同名 key 去重，不按相同温度合并不同物理传感器。
- 电池 0.01°C 与 0.1K 在室温区间存在歧义：优先用单位标记和 HID/SMC 独立电池温度参考，没有参考时遵循 AppleSmartBattery 常见的 0.01°C。
- ATA 的厂商自定义写入计数不能统一按扇区换算；未确认单位的读写总量保持 nil。
- 外接盘和其他机型的私有通道仍需实机覆盖；SMC 功耗键的含义是在 M5 Pro 上用压力测试推断的。
