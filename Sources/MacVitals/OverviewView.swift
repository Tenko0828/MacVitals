import SwiftUI
import VitalsCore

struct OverviewView: View {
    @Environment(VitalsStore.self) private var store

    var body: some View {
        let snap = store.snapshot
        Page(title: store.machine.map { "\($0.modelName)" } ?? "概览", subtitle: headerLine) {
            if let snap {
                gauges(snap)
                CardGrid(minWidth: 420) {
                    Card(title: "CPU / GPU 占用", symbol: "cpu", trailing: "\(Fmt.pct(snap.cpu.total)) · \(Fmt.pct(snap.gpu.utilization))") {
                        HistoryChart(series: [
                            SeriesSpec(name: "CPU", samples: store.samples(.cpu), tint: Tint.cpu),
                            SeriesSpec(name: "GPU", samples: store.samples(.gpu), tint: Tint.gpu),
                        ], yMax: 100, format: { "\(Int($0))%" })
                    }
                    Card(title: "芯片温度", symbol: "thermometer.medium", trailing: "最高 \(Fmt.temp(snap.sensors.socMaxC))") {
                        HistoryChart(series: [
                            SeriesSpec(name: "CPU", samples: store.samples(.cpuTemp), tint: .orange),
                            SeriesSpec(name: "GPU", samples: store.samples(.gpuTemp), tint: Tint.gpu),
                            SeriesSpec(name: "SSD", samples: store.samples(.ssdTemp), tint: .teal),
                        ], format: { "\(Int($0))°" })
                    }
                    Card(title: "功耗", symbol: "bolt", trailing: Fmt.watts(snap.power.systemW ?? snap.power.packageW)) {
                        HistoryChart(series: [
                            SeriesSpec(name: "整机", samples: store.samples(.systemW), tint: Tint.power),
                            SeriesSpec(name: "CPU", samples: store.samples(.cpuW), tint: Tint.cpu),
                            SeriesSpec(name: "GPU", samples: store.samples(.gpuW), tint: Tint.gpu),
                        ].filter { !$0.samples.isEmpty }, format: { "\(Int($0)) W" })
                    }
                    Card(title: "磁盘与网络", symbol: "arrow.up.arrow.down") {
                        HistoryChart(series: [
                            SeriesSpec(name: "磁盘读", samples: store.samples(.diskRead), tint: Tint.read),
                            SeriesSpec(name: "磁盘写", samples: store.samples(.diskWrite), tint: Tint.write),
                            SeriesSpec(name: "下载", samples: store.samples(.netRx), tint: Tint.rx),
                            SeriesSpec(name: "上传", samples: store.samples(.netTx), tint: Tint.tx),
                        ], format: { Fmt.rate($0) })
                    }
                }
                CardGrid(minWidth: 420) {
                    lifespanCard(snap)
                    topProcesses
                }
            } else {
                Placeholder(text: "正在读取传感器…")
            }
        }
    }

    private var headerLine: String? {
        guard let m = store.machine else { return nil }
        var parts = [m.chip, Fmt.mem(m.memoryBytes) + " 内存"]
        if let sw = store.software { parts.append("macOS \(sw.osVersion)（\(sw.osBuild)）") }
        if let up = store.snapshot?.uptime { parts.append("已开机 \(Fmt.duration(up))") }
        return parts.joined(separator: " · ")
    }

    private func gauges(_ snap: Snapshot) -> some View {
        Card {
            HStack(alignment: .top) {
                RingGauge(title: "CPU", value: snap.cpu.total, text: Fmt.pct(snap.cpu.total),
                          detail: snap.cpu.clusters.first?.frequencyMHz.map(Fmt.mhz), tint: Tint.cpu)
                RingGauge(title: "GPU", value: snap.gpu.utilization, text: Fmt.pct(snap.gpu.utilization),
                          detail: snap.gpu.frequencyMHz.map(Fmt.mhz), tint: Tint.gpu)
                RingGauge(title: "内存", value: store.memoryPercent, text: Fmt.pct(store.memoryPercent),
                          detail: Fmt.mem(snap.memory.usedBytes), tint: snap.memory.pressureLevel == "正常" ? Tint.memory : .orange)
                RingGauge(title: "芯片温度", value: snap.sensors.socMaxC.map { $0 / 110 * 100 },
                          text: snap.sensors.socMaxC.map { String(format: "%.0f°C", $0) } ?? "—",
                          detail: snap.power.thermalState, tint: Tint.temp(snap.sensors.socMaxC))
                RingGauge(title: "功耗", value: (snap.power.systemW ?? snap.power.packageW).map { min($0 / 120 * 100, 100) },
                          text: Fmt.watts(snap.power.systemW ?? snap.power.packageW),
                          detail: snap.power.onACPower ? "电源适配器" : "电池供电", tint: Tint.power)
                if let fan = snap.sensors.fans.first {
                    RingGauge(title: "风扇", value: fan.maxRPM.map { fan.rpm / $0 * 100 }, text: String(format: "%.0f", fan.rpm),
                              detail: "rpm", tint: .mint)
                }
            }
        }
    }

    private func lifespanCard(_ snap: Snapshot) -> some View {
        Card(title: "寿命与健康", symbol: "heart.text.square") {
            VStack(alignment: .leading, spacing: 12) {
                if let d = store.internalDrive {
                    let remain = d.percentageUsed.map { 100 - $0 }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("内置 SSD 剩余寿命")
                            Spacer()
                            Text(Fmt.pct(remain)).monospacedDigit().foregroundStyle(Tint.health(remain))
                        }
                        MeterBar(fraction: (remain ?? 0) / 100, tint: Tint.health(remain))
                        Text("累计写入 \(Fmt.bytes(d.dataWrittenBytes)) · 通电 \(Fmt.hours(d.powerOnHours)) · 介质错误 \(Fmt.int(d.mediaErrors))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if store.drivesLoading {
                    Placeholder(text: "正在读取 SMART…")
                } else {
                    Text("读不到硬盘健康信息").foregroundStyle(.secondary)
                }
                if let b = store.battery {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("电池健康")
                            Spacer()
                            Text(Fmt.pct(b.healthPercent, digits: 1)).monospacedDigit().foregroundStyle(Tint.health(b.healthPercent))
                        }
                        MeterBar(fraction: (b.healthPercent ?? 0) / 100, tint: Tint.health(b.healthPercent))
                        Text("循环 \(Fmt.int(b.cycleCount)) 次 · \(b.condition ?? "—")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                let m = snap.memory
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("内存压力")
                        Spacer()
                        Text(m.pressureLevel).foregroundStyle(m.pressureLevel == "正常" ? .green : .orange)
                    }
                    MeterBar(fraction: (m.pressurePercent ?? 0) / 100, tint: m.pressureLevel == "正常" ? .green : .orange)
                    Text("交换 \(Fmt.mem(m.swapUsedBytes)) / \(Fmt.mem(m.swapTotalBytes)) · 换出 \(Fmt.num(m.swapOutsPerSec, digits: 0))/秒")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var topProcesses: some View {
        Card(title: "最耗 CPU 的进程", symbol: "flame") {
            let top = store.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(6)
            if top.isEmpty {
                Placeholder(text: "正在读取进程…")
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(top)) { p in
                        HStack {
                            Text(p.name).lineLimit(1)
                            Spacer()
                            Text(Fmt.mem(p.memoryBytes)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                            Text(Fmt.pct(p.cpuPercent, digits: 1)).frame(width: 60, alignment: .trailing)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }
}
