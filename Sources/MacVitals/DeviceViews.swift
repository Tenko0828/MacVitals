import SwiftUI
import VitalsCore

struct StorageView: View {
    @Environment(VitalsStore.self) private var store
    @Local private var showSystemVolumes = false

    /// APFS 的系统宗卷（VM、Preboot、Recovery……）和“/”共用同一个容器，默认收起
    private func isSystemVolume(_ v: VolumeInfo) -> Bool {
        v.mountPoint.hasPrefix("/System/Volumes/") || v.mountPoint == "/Volumes/Recovery" || v.totalBytes == 0
    }

    var body: some View {
        let snap = store.snapshot
        Page(title: "存储与寿命", subtitle: "SMART 数据来自 smartctl，每 5 分钟刷新一次") {
            if store.drives.isEmpty {
                if store.drivesLoading { Placeholder(text: "正在读取 SMART…") }
                else { Card { Text("没有读到任何硬盘的健康信息").foregroundStyle(.secondary) } }
            }
            ForEach(store.drives) { d in DriveCard(drive: d, io: snap?.disks.first { $0.bsdName == d.bsdName }) }

            Card(title: "读写速率", symbol: "arrow.up.arrow.down",
                 trailing: "读 \(Fmt.rate(snap?.disks.reduce(0) { $0 + $1.readBytesPerSec })) · 写 \(Fmt.rate(snap?.disks.reduce(0) { $0 + $1.writeBytesPerSec }))") {
                HistoryChart(series: [
                    SeriesSpec(name: "读取", samples: store.samples(.diskRead), tint: Tint.read),
                    SeriesSpec(name: "写入", samples: store.samples(.diskWrite), tint: Tint.write),
                ], format: { Fmt.rate($0) }, height: 140)
                if let disks = snap?.disks, !disks.isEmpty {
                    ForEach(disks) { d in
                        Text("\(d.bsdName)：开机以来读 \(Fmt.bytes(d.totalReadBytes))、写 \(Fmt.bytes(d.totalWrittenBytes)) · \(Fmt.num(d.readOpsPerSec, digits: 0)) / \(Fmt.num(d.writeOpsPerSec, digits: 0)) 次每秒")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            let writers = store.processes.filter { $0.diskWriteBytesPerSec > 0 }.sorted { $0.diskWriteBytesPerSec > $1.diskWriteBytesPerSec }.prefix(8)
            Card(title: "正在写盘的进程", symbol: "square.and.pencil") {
                if writers.isEmpty {
                    Text("现在没有进程在写盘").foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(writers)) { p in
                            HStack {
                                Text(p.name).lineLimit(1)
                                Spacer()
                                Text("累计 \(Fmt.bytes(p.totalDiskWrittenBytes))").foregroundStyle(.secondary)
                                Text(Fmt.rate(p.diskWriteBytesPerSec)).frame(width: 100, alignment: .trailing)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
            }

            Card(title: "宗卷", symbol: "externaldrive") {
                VStack(spacing: 14) {
                    ForEach(store.volumes.filter { showSystemVolumes || !isSystemVolume($0) }) { v in VolumeRow(volume: v) }
                }
                Toggle("显示系统宗卷（\(store.volumes.filter(isSystemVolume).count) 个）", isOn: $showSystemVolumes)
                    .toggleStyle(.checkbox).font(.caption)
            }
        }
    }
}

struct DriveCard: View {
    let drive: DriveHealth
    let io: DiskIO?

    var body: some View {
        let remain = drive.percentageUsed.map { max(0, 100 - $0) }
        Card(title: drive.model ?? drive.bsdName, symbol: drive.isInternal ? "internaldrive" : "externaldrive",
             trailing: [drive.bsdName, drive.capacityBytes.map(Fmt.bytes)].compactMap { $0 }.joined(separator: " · ")) {
            HStack(alignment: .top, spacing: 20) {
                RingGauge(title: "剩余寿命", value: remain, text: Fmt.pct(remain), detail: drive.smartPassed.map { $0 ? "SMART 通过" : "SMART 失败" }, tint: Tint.health(remain))
                    .frame(width: 140)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        StatTile(title: "已用寿命", value: Fmt.pct(drive.percentageUsed), detail: "厂商估计，100% 是标称写入量")
                        StatTile(title: "累计写入", value: Fmt.bytes(drive.dataWrittenBytes), detail: writeRate)
                        StatTile(title: "累计读取", value: Fmt.bytes(drive.dataReadBytes))
                        StatTile(title: "温度", value: Fmt.temp(drive.temperatureC), tint: Tint.temp(drive.temperatureC))
                    }
                    HStack(alignment: .top) {
                        StatTile(title: "备用块", value: Fmt.pct(drive.availableSpare), detail: drive.availableSpareThreshold.map { "阈值 \(Fmt.pct($0))" }, tint: Tint.health(drive.availableSpare))
                        StatTile(title: "通电时间", value: Fmt.hours(drive.powerOnHours))
                        StatTile(title: "通电次数", value: Fmt.int(drive.powerCycles))
                        StatTile(title: "异常断电", value: Fmt.int(drive.unsafeShutdowns))
                    }
                    HStack(alignment: .top) {
                        StatTile(title: "介质错误", value: Fmt.int(drive.mediaErrors), tint: (drive.mediaErrors ?? 0) > 0 ? .red : .secondary)
                        StatTile(title: "错误日志", value: Fmt.int(drive.errorLogEntries))
                        StatTile(title: "严重警告", value: drive.criticalWarning.map { $0 == 0 ? "无" : String(format: "0x%02X", $0) } ?? "—")
                        StatTile(title: "固件", value: drive.firmware ?? "—", detail: drive.serial.map { "序列号 \($0)" })
                    }
                }
            }
            if let note = drive.note {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            Text("数据来源：\(drive.source)").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 平均每通电小时写多少
    private var writeRate: String? {
        guard let w = drive.dataWrittenBytes, let h = drive.powerOnHours, h > 0 else { return nil }
        return "约 \(Fmt.bytes(w / Int64(h))) / 通电小时"
    }
}

struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        let used = volume.totalBytes - (volume.availableBytes ?? volume.freeBytes)
        let frac = volume.totalBytes > 0 ? Double(used) / Double(volume.totalBytes) : 0
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(volume.name).font(.callout.weight(.medium))
                Text(volume.mountPoint).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.bytes(used)) / \(Fmt.bytes(volume.totalBytes))").font(.callout.monospacedDigit())
            }
            MeterBar(fraction: frac, tint: frac > 0.9 ? .red : (frac > 0.75 ? .orange : .blue))
            HStack(spacing: 8) {
                Text(volume.fileSystem.uppercased())
                if let b = volume.bsdName { Text(b) }
                Text("空闲 \(Fmt.bytes(volume.freeBytes))")
                if let a = volume.availableBytes, a != volume.freeBytes { Text("含可清除 \(Fmt.bytes(a))") }
                if volume.isReadOnly { Text("只读") }
                if !volume.isInternal { Text("外接") }
                if volume.isRemovable { Text("可移除") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 温度 · 风扇 · 功耗

struct SensorsView: View {
    @Environment(VitalsStore.self) private var store
    @Local private var showKeys = false

    var body: some View {
        let snap = store.snapshot
        Page(title: "温度 · 风扇 · 功耗", subtitle: snap.map { "\($0.sensors.temperatures.count) 个温度传感器 · 散热状态：\($0.power.thermalState)" }) {
            if let snap {
                Card {
                    HStack(alignment: .top, spacing: 20) {
                        StatTile(title: "芯片最高", value: Fmt.temp(snap.sensors.socMaxC), symbol: "flame", tint: Tint.temp(snap.sensors.socMaxC))
                        StatTile(title: "CPU", value: Fmt.temp(snap.sensors.cpuMaxC), detail: "平均 \(Fmt.temp(snap.sensors.cpuAvgC))", tint: Tint.temp(snap.sensors.cpuMaxC))
                        StatTile(title: "GPU", value: Fmt.temp(snap.sensors.gpuMaxC), detail: "平均 \(Fmt.temp(snap.sensors.gpuAvgC))", tint: Tint.temp(snap.sensors.gpuMaxC))
                        StatTile(title: "SSD", value: Fmt.temp(snap.sensors.ssdC))
                        StatTile(title: "电池", value: Fmt.temp(snap.sensors.batteryC))
                    }
                    HistoryChart(series: [
                        SeriesSpec(name: "芯片最高", samples: store.samples(.socTemp), tint: .red),
                        SeriesSpec(name: "CPU", samples: store.samples(.cpuTemp), tint: .orange),
                        SeriesSpec(name: "GPU", samples: store.samples(.gpuTemp), tint: Tint.gpu),
                        SeriesSpec(name: "SSD", samples: store.samples(.ssdTemp), tint: .teal),
                        SeriesSpec(name: "电池", samples: store.samples(.batteryTemp), tint: .green),
                    ].filter { !$0.samples.isEmpty }, format: { "\(Int($0))°" }, height: 160)
                }

                Card(title: "功耗", symbol: "bolt.fill", trailing: snap.power.lowPowerMode ? "低电量模式" : nil) {
                    HStack(alignment: .top, spacing: 20) {
                        StatTile(title: "整机", value: Fmt.watts(snap.power.systemW), tint: Tint.power)
                        StatTile(title: "SoC 合计", value: Fmt.watts(snap.power.packageW))
                        StatTile(title: "CPU", value: Fmt.watts(snap.power.cpuW), detail: snap.power.cpuEstimated ? "估算：SoC 合计 − GPU" : nil, tint: Tint.cpu)
                        StatTile(title: "GPU", value: Fmt.watts(snap.power.gpuW), tint: Tint.gpu)
                        StatTile(title: "神经网络引擎", value: Fmt.watts(snap.power.aneW), tint: .mint)
                        StatTile(title: "内存", value: Fmt.watts(snap.power.dramW), tint: Tint.memory)
                        StatTile(title: "适配器输入", value: Fmt.watts(snap.power.adapterW))
                    }
                    HistoryChart(series: [
                        SeriesSpec(name: "整机", samples: store.samples(.systemW), tint: Tint.power),
                        SeriesSpec(name: "CPU", samples: store.samples(.cpuW), tint: Tint.cpu),
                        SeriesSpec(name: "GPU", samples: store.samples(.gpuW), tint: Tint.gpu),
                        SeriesSpec(name: "ANE", samples: store.samples(.aneW), tint: .mint),
                        SeriesSpec(name: "内存", samples: store.samples(.dramW), tint: Tint.memory),
                    ].filter { !$0.samples.isEmpty }, format: { Fmt.watts($0) }, height: 140)
                }

                if !snap.sensors.fans.isEmpty {
                    Card(title: "风扇", symbol: "fan") {
                        ForEach(snap.sensors.fans) { f in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("风扇 \(f.index + 1)").font(.callout.weight(.medium))
                                    Spacer()
                                    Text(Fmt.rpm(f.rpm)).font(.callout.monospacedDigit())
                                }
                                MeterBar(fraction: f.maxRPM.map { f.rpm / $0 } ?? 0, tint: .mint)
                                Text("最低 \(Fmt.rpm(f.minRPM)) · 最高 \(Fmt.rpm(f.maxRPM)) · 目标 \(Fmt.rpm(f.targetRPM))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Sparkline(samples: store.samples(.fan(f.index)), tint: .mint, yMax: f.maxRPM).frame(height: 36)
                            }
                        }
                    }
                }

                HStack {
                    Text("全部传感器").font(.title2.weight(.semibold))
                    Spacer()
                    Toggle("显示原始名", isOn: $showKeys).toggleStyle(.switch).controlSize(.small)
                }
                CardGrid(minWidth: 400) {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        let list = snap.sensors.temperatures.filter { $0.group == g }.sorted { $0.celsius > $1.celsius }
                        if !list.isEmpty {
                            Card(title: g.title, trailing: "\(list.count) 个") {
                                VStack(spacing: 6) {
                                    ForEach(list) { s in
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 0) {
                                                Text(s.name).lineLimit(1)
                                                if showKeys { Text(s.key).font(.caption2).foregroundStyle(.tertiary) }
                                            }
                                            .frame(width: 150, alignment: .leading)
                                            Sparkline(samples: store.samples(.sensor(s.key)), tint: Tint.temp(s.celsius)).frame(height: 20)
                                            Text(Fmt.temp(s.celsius)).monospacedDigit().foregroundStyle(Tint.temp(s.celsius)).frame(width: 64, alignment: .trailing)
                                        }
                                        .font(.callout)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Placeholder(text: "正在读取传感器…")
            }
        }
    }
}

extension SensorGroup {
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "芯片其它部分"
        case .memory: "内存"
        case .storage: "存储"
        case .battery: "电池"
        case .ambient: "机身 / 环境"
        case .other: "其它"
        }
    }
}

// MARK: - 电池与电源

struct BatteryView: View {
    @Environment(VitalsStore.self) private var store

    var body: some View {
        let power = store.snapshot?.power
        Page(title: "电池与电源", subtitle: power.map { [$0.onACPower ? "使用电源适配器" : "使用电池", $0.lowPowerMode ? "低电量模式已开" : nil].compactMap { $0 }.joined(separator: " · ") }) {
            if let b = store.battery {
                Card {
                    HStack(alignment: .top) {
                        RingGauge(title: "电量", value: b.chargePercent, text: Fmt.pct(b.chargePercent),
                                  detail: b.isFullyCharged ? "已充满" : (b.isCharging ? "充电中" : (b.isPluggedIn ? "未在充电" : "放电中")),
                                  tint: b.chargePercent > 20 ? .green : .red)
                        RingGauge(title: "健康度", value: b.healthPercent, text: Fmt.pct(b.healthPercent, digits: 1), detail: b.condition, tint: Tint.health(b.healthPercent))
                        RingGauge(title: "循环次数", value: b.cycleCount.map { Double($0) / 10 }, text: Fmt.int(b.cycleCount), detail: "设计 1000 次", tint: .blue)
                        let temp = b.temperatureC ?? store.snapshot?.sensors.batteryC
                        RingGauge(title: "温度", value: temp.map { $0 / 60 * 100 }, text: Fmt.temp(temp), tint: Tint.temp(temp))
                    }
                }
                CardGrid(minWidth: 380) {
                    Card(title: "容量", symbol: "battery.100percent") {
                        HStack(alignment: .top) {
                            StatTile(title: "设计容量", value: b.designCapacitymAh.map { "\($0) mAh" } ?? "—")
                            StatTile(title: "当前满电", value: b.maxCapacitymAh.map { "\($0) mAh" } ?? "—")
                            StatTile(title: "当前剩余", value: b.currentCapacitymAh.map { "\($0) mAh" } ?? "—")
                        }
                        Text(b.isCharging ? "充满还需 \(Fmt.minutes(b.timeRemainingMinutes))" : "预计可用 \(Fmt.minutes(b.timeRemainingMinutes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Card(title: "电气", symbol: "bolt") {
                        HStack(alignment: .top) {
                            StatTile(title: "电压", value: b.voltageV.map { String(format: "%.2f V", $0) } ?? "—")
                            StatTile(title: "电流", value: b.amperageA.map { String(format: "%+.2f A", $0) } ?? "—")
                            StatTile(title: "电池功率", value: b.powerW.map { String(format: "%+.1f W", $0) } ?? "—", detail: "正为充入，负为放出")
                        }
                        HStack(alignment: .top) {
                            StatTile(title: "适配器", value: b.adapterWatts.map { "\(Int($0)) W" } ?? "—", detail: b.adapterName)
                            StatTile(title: "实时输入", value: Fmt.watts(power?.adapterW))
                            StatTile(title: "整机功耗", value: Fmt.watts(power?.systemW))
                        }
                    }
                }
                SectionsView(sections: b.sections)
            } else if store.batteryChecked {
                Card { Label("这台 Mac 没有电池", systemImage: "powerplug").foregroundStyle(.secondary) }
            } else {
                Placeholder(text: "正在读取电池…")
            }
        }
    }
}

// MARK: - 网络

struct NetworkView: View {
    @Environment(VitalsStore.self) private var store
    @Local private var showAll = false

    var body: some View {
        let snap = store.snapshot
        Page(title: "网络") {
            Card(title: "流量", symbol: "arrow.up.arrow.down",
                 trailing: "↓ \(Fmt.rate(snap?.network.reduce(0) { $0 + $1.rxBytesPerSec })) · ↑ \(Fmt.rate(snap?.network.reduce(0) { $0 + $1.txBytesPerSec }))") {
                HistoryChart(series: [
                    SeriesSpec(name: "下载", samples: store.samples(.netRx), tint: Tint.rx),
                    SeriesSpec(name: "上传", samples: store.samples(.netTx), tint: Tint.tx),
                ], format: { Fmt.rate($0) }, height: 150)
            }
            // 默认只看有 IPv4 地址或开机以来有流量的接口；anpi/awdl/utun 这类虚拟接口收起
            let active = Set(snap?.network.filter { $0.totalRxBytes + $0.totalTxBytes > 0 }.map(\.bsdName) ?? [])
            let all = store.interfaces.sorted { ($0.ipv4.isEmpty ? 1 : 0, $0.bsdName) < ($1.ipv4.isEmpty ? 1 : 0, $1.bsdName) }
            let ifaces = showAll ? all : all.filter { $0.kind != "回环" && (!$0.ipv4.isEmpty || (active.contains($0.bsdName) && $0.kind != "其它")) }
            if all.isEmpty { Placeholder(text: "正在读取网络接口…") }
            Toggle("显示全部接口（共 \(all.count) 个，含虚拟接口）", isOn: $showAll).toggleStyle(.checkbox).font(.callout)
            CardGrid(minWidth: 420) {
                ForEach(ifaces) { i in
                    let io = snap?.network.first { $0.bsdName == i.bsdName }
                    Card(title: "\(i.displayName)（\(i.bsdName)）", symbol: symbol(i.kind)) {
                        HStack { Pill(text: i.isUp ? "已连接" : "未连接", tint: i.isUp ? .green : .secondary); Pill(text: i.kind) }
                        if let io {
                            HStack(alignment: .top) {
                                StatTile(title: "下载", value: Fmt.rate(io.rxBytesPerSec), detail: "开机以来 \(Fmt.bytes(io.totalRxBytes))", tint: Tint.rx)
                                StatTile(title: "上传", value: Fmt.rate(io.txBytesPerSec), detail: "开机以来 \(Fmt.bytes(io.totalTxBytes))", tint: Tint.tx)
                            }
                        }
                        KVGrid(items: [
                            InfoItem("MAC", i.macAddress ?? "—"),
                            InfoItem("IPv4", i.ipv4.isEmpty ? "—" : i.ipv4.joined(separator: "\n")),
                            InfoItem("IPv6", i.ipv6.isEmpty ? "—" : i.ipv6.joined(separator: "\n")),
                            InfoItem("MTU", Fmt.int(i.mtu)),
                            InfoItem("链路速度", i.linkSpeedMbps.map { $0 >= 1000 ? String(format: "%.1f Gbps", $0 / 1000) : String(format: "%.0f Mbps", $0) } ?? "—"),
                        ] + i.sections.flatMap(\.items))
                    }
                }
            }
        }
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "Wi-Fi": "wifi"
        case "以太网": "cable.connector.horizontal"
        case "VPN": "lock.shield"
        case "雷雳网桥": "bolt.horizontal"
        default: "network"
        }
    }
}

// MARK: - 外设

struct PeripheralsView: View {
    @Environment(VitalsStore.self) private var store
    @Local private var query = ""

    var body: some View {
        Page(title: "外设", subtitle: "来自 system_profiler，每分钟刷新") {
            if store.peripheralsLoading && store.peripherals.isEmpty {
                Placeholder(text: "正在读取外设（第一次需要几秒）…")
            }
            ForEach(store.peripherals) { g in
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(g.title)（\(g.devices.count)）", systemImage: g.symbol).font(.title2.weight(.semibold))
                    if g.devices.isEmpty {
                        Text("没有设备").foregroundStyle(.secondary)
                    } else {
                        SectionsView(sections: g.devices.map(cleaned), filter: query)
                    }
                }
                .padding(.top, 6)
            }
        }
        .searchable(text: $query, prompt: "搜索外设")
    }
}

/// system_profiler 的原始键值带 spdisplays_ / sppci_ 之类前缀，显示前去掉，并把 yes/no 换成中文
private func cleaned(_ section: InfoSection) -> InfoSection {
    func strip(_ s: String) -> String {
        s.replacingOccurrences(of: #"^sp[a-z0-9]+[_ ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=/ )sp[a-z0-9]+[_ ]"#, with: "", options: .regularExpression)
    }
    let words = ["yes": "是", "no": "否", "on": "开", "off": "关", "supported": "支持", "builtin": "内置", "attrib_yes": "是", "attrib_no": "否"]
    return InfoSection(title: strip(section.title), items: section.items.map { item in
        let v = strip(item.value)
        return InfoItem(strip(item.key), words[v.lowercased()] ?? v)
    })
}
