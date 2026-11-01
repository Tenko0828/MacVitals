# 硬件体检 MacVitals

一个 macOS 原生 App：把这台 Mac 的**硬件状态、寿命、温度、功耗、活动监视和软件参数**集中在一个窗口里，菜单栏上常驻一个小面板。为 Apple Silicon 编写，在 M5 Pro / macOS 27 上实测。

## 能看到什么

| 页面 | 内容 |
|---|---|
| 概览 | CPU / GPU / 内存 / 芯片温度 / 功耗 / 风扇仪表，四组实时曲线，寿命与健康摘要，最耗 CPU 的进程 |
| CPU | 总占用、用户 / 系统 / 空闲，平均负载，每个簇的占用和**实时频率**，每个核心的迷你曲线，CPU 温度，缓存与指令集特性 |
| GPU | 设备 / 渲染器 / 拼接器占用，频率，显存占用，GPU 温度和功耗，显示器信息 |
| 内存 | App 内存 / 联动 / 被压缩 / 缓存文件构成，内存压力，交换用量和换入换出速率，分页活动，占内存最多的进程 |
| 存储与寿命 | 每块盘的 SMART：**剩余寿命**、累计写入/读取、备用块、通电时间、异常断电、介质错误、温度；实时读写速率；正在写盘的进程；宗卷容量 |
| 温度 · 风扇 · 功耗 | 二百多个温度传感器（按 CPU / GPU / SoC / 内存 / 存储 / 电池 / 机身分组，每个都有曲线），风扇转速，整机 / SoC / CPU / GPU / 适配器功耗 |
| 电池与电源 | 电量、健康度、循环次数、设计 / 满电 / 剩余容量、电压电流功率、适配器信息，以及电池控制器的全部原始字段 |
| 网络 | 实时流量，每个接口的 IP / MAC / MTU / 链路速度 / 网关 / DNS |
| 活动监视 | 全部进程（含 root 和系统进程）：CPU、内存、线程、能耗、磁盘读写速率和累计写入；可搜索、排序、暂停刷新，右键可结束进程或在访达中显示 |
| 外设 | 显示器、雷雳、USB、蓝牙（含电量）、音频、摄像头、NVMe |
| 系统与软件 | 机型、序列号、固件，macOS 与内核版本，安全状态（SIP / 文件保险箱 / Gatekeeper / 防火墙），软件更新，开发工具和运行时版本，Homebrew，应用统计（含 Intel-only），启动项，电源设置，账户与区域，代理与共享，显示与外观等 13 组参数 |

工具栏可以切换曲线时间范围（1–10 分钟）、重新读取慢速数据，或者把全部数据导出成 JSON（⌘E）。

## 安装

需要 macOS 14 以上和 Xcode 或 Command Line Tools。硬盘寿命要用 smartmontools：

```bash
brew install smartmontools
```

```bash
./build.sh install
```

只想打包不安装，运行 `./build.sh`，产物在 `build/MacVitals.app`。App 用本地临时签名，只适合在自己的电脑上编译使用。

## 不需要 root

所有数据都以普通用户身份读取，不需要输入密码，也不安装任何后台服务：

- 温度：IOHIDEventSystem 和 AppleSMC
- 风扇、整机功耗：AppleSMC
- 频率、GPU 功耗：IOReport
- 进程：libproc；其他用户的进程用系统自带的 `ps` 补齐
- 硬盘寿命：`smartctl`
- 其余：sysctl、IORegistry、system_profiler

## 已知限制

- **CPU 功耗是估算值**：M5 / macOS 27 上，不用 root 读到的 CPU、神经网络引擎、内存能量计数器不会更新。CPU 功耗按「SoC 合计（SMC `PHPC`）− GPU 功耗（IOReport）」估算，界面上会标出“估算”；神经网络引擎和内存功耗不显示。
- 温度传感器的名字来自 SMC / HID 原始键（如 `Tp00`、`PMU tdie3`），苹果没有公开含义，分组是按常见约定推断的。CPU 最高温只统计核心传感器（`Tp*`、`PMU tdie*`）。
- 全部传感器每 5 秒完整扫描一次，核心温度、风扇和功耗每秒刷新。
- 运行时 App 自身占用约 3–5% CPU（一个核的百分比）。

## 结构

- `Sources/VitalsCore`：采集后端，`Models.swift` 是前后端之间的数据契约
- `Sources/CVitalsSupport`：调用 SMC / HID / IOReport / libproc 的 C 代码
- `Sources/MacVitals`：SwiftUI 界面
- `Sources/vitals-dump`：命令行调试工具，把采到的全部数据打印成 JSON（`swift run -c release vitals-dump`）
