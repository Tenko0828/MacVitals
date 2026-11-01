import SwiftUI
import VitalsCore

struct CPUView: View {
    @Environment(VitalsStore.self) private var store

    var body: some View {
        let snap = store.snapshot
        let m = store.machine
        Page(title: "CPU", subtitle: m.map { "\($0.chip) · \($0.logicalCores) 核（" + $0.cpuClusters.map { "\($0.coreCount) \($0.name)" }.joined(separator: " + ") + "）" }) {
            if let cpu = snap?.cpu {
                Card {
                    HStack(alignment: .top, spacing: 20) {
                        StatTile(title: "总占用", value: Fmt.pct(cpu.total, digits: 1), symbol: "cpu", tint: Tint.cpu)
                        StatTile(title: "用户", value: Fmt.pct(cpu.user, digits: 1))
                        StatTile(title: "系统", value: Fmt.pct(cpu.system, digits: 1))
                        StatTile(title: "空闲", value: Fmt.pct(cpu.idle, digits: 1))
                        StatTile(title: "平均负载", value: cpu.loadAverage.map { Fmt.num($0, digits: 2) }.joined(separator: "  "), detail: "1 / 5 / 15 分钟")
                        StatTile(title: "进程 / 线程", value: "\(Fmt.int(cpu.processCount)) / \(Fmt.int(cpu.threadCount))")
                    }
                    HistoryChart(series: [SeriesSpec(name: "CPU", samples: store.samples(.cpu), tint: Tint.cpu)],
                                 yMax: 100, format: { "\(Int($0))%" }, height: 150)
                }

                CardGrid(minWidth: 260) {
                    ForEach(cpu.clusters, id: \.name) { c in
                        let info = m?.cpuClusters.first { $0.name == c.name }
                        Card(title: c.name, symbol: "square.grid.3x3") {
                            HStack(alignment: .top) {
                                StatTile(title: "占用", value: Fmt.pct(c.usage, digits: 1), tint: Tint.usage(c.usage))
                                StatTile(title: "当前频率", value: Fmt.mhz(c.frequencyMHz), detail: info?.maxFrequencyMHz.map { "最高 \(Fmt.mhz($0))" })
                            }
                            if let info {
                                Text("\(info.coreCount) 核" + (info.l2CacheBytes.map { " · L2 \(Fmt.mem($0))" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Card(title: "每个核心", symbol: "square.grid.4x3.fill") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(cpu.perCore, id: \.index) { c in
                            CoreTile(core: c, cluster: store.clusterName(forCore: c.index), samples: store.samples(.core(c.index)))
                        }
                    }
                }

                let temps = (snap?.sensors.temperatures ?? []).filter { $0.group == .cpu }
                if !temps.isEmpty {
                    Card(title: "CPU 温度", symbol: "thermometer.medium", trailing: "平均 \(Fmt.temp(snap?.sensors.cpuAvgC)) · 最高 \(Fmt.temp(snap?.sensors.cpuMaxC))") {
                        TempList(sensors: temps)
                    }
                }

                if let m {
                    SectionsView(sections: m.sections.filter { $0.title.localizedCaseInsensitiveContains("CPU") || $0.title.contains("指令") || $0.title.contains("缓存") })
                }
            } else {
                Placeholder(text: "正在采样…")
            }
        }
    }
}

struct CoreTile: View {
    let core: CoreLoad
    let cluster: String?
    let samples: [Sample]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(core.index)").font(.caption.weight(.semibold))
                if let cluster { Text(cluster).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text(Fmt.pct(core.usage)).font(.caption.monospacedDigit())
            }
            Sparkline(samples: samples, tint: Tint.usage(core.usage), yMax: 100).frame(height: 30)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct GPUView: View {
    @Environment(VitalsStore.self) private var store

    var body: some View {
        let snap = store.snapshot
        Page(title: "GPU", subtitle: store.machine.map { m in
            [m.chip, m.gpuCores.map { "\($0) 核 GPU" }, m.neuralEngineCores.map { "\($0) 核神经网络引擎" }].compactMap { $0 }.joined(separator: " · ")
        }) {
            if let gpu = snap?.gpu, let snap {
                Card {
                    HStack(alignment: .top) {
                        RingGauge(title: "设备占用", value: gpu.utilization, text: Fmt.pct(gpu.utilization), tint: Tint.gpu)
                        RingGauge(title: "渲染器", value: gpu.rendererUtilization, text: Fmt.pct(gpu.rendererUtilization), tint: .indigo)
                        RingGauge(title: "拼接器", value: gpu.tilerUtilization, text: Fmt.pct(gpu.tilerUtilization), tint: .pink)
                        RingGauge(title: "温度", value: snap.sensors.gpuMaxC.map { $0 / 110 * 100 },
                                  text: snap.sensors.gpuMaxC.map { String(format: "%.0f°C", $0) } ?? "—", tint: Tint.temp(snap.sensors.gpuMaxC))
                    }
                }
                Card {
                    HStack(alignment: .top, spacing: 20) {
                        StatTile(title: "频率", value: Fmt.mhz(gpu.frequencyMHz), symbol: "waveform.path", tint: Tint.gpu)
                        StatTile(title: "GPU 功耗", value: Fmt.watts(snap.power.gpuW), symbol: "bolt", tint: Tint.power)
                        StatTile(title: "ANE 功耗", value: Fmt.watts(snap.power.aneW), symbol: "brain", tint: .mint)
                        StatTile(title: "显存在用", value: Fmt.mem(gpu.memoryInUseBytes), detail: "统一内存中由 GPU 使用的部分", symbol: "memorychip")
                        StatTile(title: "显存已分配", value: Fmt.mem(gpu.memoryAllocatedBytes))
                    }
                }
                CardGrid(minWidth: 420) {
                    Card(title: "占用历史", symbol: "chart.xyaxis.line") {
                        HistoryChart(series: [SeriesSpec(name: "GPU", samples: store.samples(.gpu), tint: Tint.gpu)], yMax: 100, format: { "\(Int($0))%" })
                    }
                    Card(title: "功耗历史", symbol: "bolt") {
                        HistoryChart(series: [
                            SeriesSpec(name: "GPU", samples: store.samples(.gpuW), tint: Tint.gpu),
                            SeriesSpec(name: "ANE", samples: store.samples(.aneW), tint: .mint),
                        ].filter { !$0.samples.isEmpty }, format: { Fmt.watts($0) })
                    }
                }
                let temps = snap.sensors.temperatures.filter { $0.group == .gpu }
                if !temps.isEmpty {
                    Card(title: "GPU 温度", symbol: "thermometer.medium", trailing: "平均 \(Fmt.temp(snap.sensors.gpuAvgC))") {
                        TempList(sensors: temps)
                    }
                }
                if let displays = store.peripherals.first(where: { $0.title.contains("显示") || $0.title.localizedCaseInsensitiveContains("display") }) {
                    SectionsView(sections: displays.devices)
                }
            } else {
                Placeholder(text: "正在采样…")
            }
        }
    }
}

struct MemoryView: View {
    @Environment(VitalsStore.self) private var store

    var body: some View {
        Page(title: "内存", subtitle: store.machine.map { m in
            [Fmt.mem(m.memoryBytes), m.memoryType, m.memoryManufacturer].compactMap { $0 }.joined(separator: " · ") + " 统一内存"
        }) {
            if let mem = store.snapshot?.memory {
                let total = Double(mem.totalBytes)
                Card(title: "构成", symbol: "chart.bar.fill", trailing: "已使用 \(Fmt.mem(mem.usedBytes)) / \(Fmt.mem(mem.totalBytes))") {
                    StackedBar(parts: [
                        .init(label: "App 内存 \(Fmt.mem(mem.appBytes))", value: Double(mem.appBytes), tint: .blue),
                        .init(label: "联动 \(Fmt.mem(mem.wiredBytes))", value: Double(mem.wiredBytes), tint: .orange),
                        .init(label: "被压缩 \(Fmt.mem(mem.compressedBytes))", value: Double(mem.compressedBytes), tint: .purple),
                        .init(label: "缓存文件 \(Fmt.mem(mem.cachedFilesBytes))", value: Double(mem.cachedFilesBytes), tint: .teal.opacity(0.6)),
                    ], total: total)
                    Text("空闲 \(Fmt.mem(mem.freeBytes))。缓存文件是系统顺手留着的文件副本，需要内存时会立刻让出，不算“用掉”。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardGrid(minWidth: 420) {
                    Card(title: "内存压力", symbol: "gauge.medium", trailing: mem.pressureLevel) {
                        HStack(alignment: .top) {
                            StatTile(title: "压力", value: Fmt.pct(mem.pressurePercent), tint: mem.pressureLevel == "正常" ? .green : .orange)
                            StatTile(title: "使用率", value: Fmt.pct(store.memoryPercent, digits: 1))
                        }
                        HistoryChart(series: [SeriesSpec(name: "使用率", samples: store.samples(.memory), tint: Tint.memory)], yMax: 100, format: { "\(Int($0))%" })
                    }
                    Card(title: "交换（Swap）", symbol: "arrow.left.arrow.right", trailing: "\(Fmt.mem(mem.swapUsedBytes)) / \(Fmt.mem(mem.swapTotalBytes))") {
                        HStack(alignment: .top) {
                            StatTile(title: "换入", value: "\(Fmt.num(mem.swapInsPerSec, digits: 0))/秒")
                            StatTile(title: "换出", value: "\(Fmt.num(mem.swapOutsPerSec, digits: 0))/秒")
                        }
                        HistoryChart(series: [SeriesSpec(name: "交换用量", samples: store.samples(.swap), tint: .orange)], format: { Fmt.mem(Int64($0)) })
                        Text("交换用量持续很高、换出频繁，说明内存不够用，会大量写 SSD、加速磨损。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card(title: "分页活动", symbol: "doc.on.doc") {
                    HStack(alignment: .top, spacing: 20) {
                        StatTile(title: "页面换入", value: "\(Fmt.num(mem.pageInsPerSec, digits: 0))/秒")
                        StatTile(title: "页面换出", value: "\(Fmt.num(mem.pageOutsPerSec, digits: 0))/秒")
                        StatTile(title: "压缩", value: "\(Fmt.num(mem.compressionsPerSec, digits: 0))/秒")
                        StatTile(title: "解压", value: "\(Fmt.num(mem.decompressionsPerSec, digits: 0))/秒")
                    }
                }
                let top = store.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(10)
                if !top.isEmpty {
                    Card(title: "占内存最多", symbol: "list.number") {
                        VStack(spacing: 6) {
                            ForEach(Array(top)) { p in
                                MeterRow(label: p.name, fraction: total > 0 ? Double(p.memoryBytes) / total : 0, value: Fmt.mem(p.memoryBytes), tint: .blue)
                            }
                        }
                    }
                }
            } else {
                Placeholder(text: "正在采样…")
            }
        }
    }
}

/// 温度传感器列表：按温度从高到低，带色条
struct TempList: View {
    let sensors: [TemperatureSensor]
    var body: some View {
        VStack(spacing: 6) {
            ForEach(sensors.sorted { $0.celsius > $1.celsius }) { s in
                MeterRow(label: s.name, fraction: s.celsius / 110, value: Fmt.temp(s.celsius), tint: Tint.temp(s.celsius))
                    .help(s.key)
            }
        }
    }
}
