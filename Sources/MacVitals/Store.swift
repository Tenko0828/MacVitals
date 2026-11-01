import SwiftUI
import VitalsCore

enum Metric: Hashable {
    case cpu, gpu, memory, swap
    case cpuTemp, gpuTemp, socTemp, ssdTemp, batteryTemp
    case systemW, packageW, cpuW, gpuW, aneW, dramW
    case diskRead, diskWrite, netRx, netTx
    case fan(Int)
    case core(Int)
    case sensor(String)
}

struct Sample: Identifiable {
    let t: Date
    let v: Double
    var id: Date { t }
}

/// 所有曲线的历史数据，最多保留 maxCount 个点（1 秒一个）
struct History {
    static let maxCount = 600
    private(set) var series: [Metric: [Sample]] = [:]

    mutating func add(_ m: Metric, _ v: Double?, at t: Date) {
        guard let v, v.isFinite else { return }
        var s = series[m, default: []]
        s.append(Sample(t: t, v: v))
        if s.count > Self.maxCount { s.removeFirst(s.count - Self.maxCount) }
        series[m] = s
    }

    /// 取最近 n 个点；超过 maxPoints 时等距抽稀，图表点数不随时间范围增长
    func samples(_ m: Metric, last n: Int, maxPoints: Int = 150) -> [Sample] {
        guard let s = series[m] else { return [] }
        let tail = s.count > n ? Array(s.suffix(n)) : s
        guard tail.count > maxPoints else { return tail }
        let step = Double(tail.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { tail[Int((Double($0) * step).rounded())] }
    }
}

/// 后端数据的唯一来源：定时在后台线程调 VitalsMonitor，再回到主线程发布
@MainActor @Observable
final class VitalsStore {
    let monitor = VitalsMonitor()

    var machine: MachineInfo?
    var software: SoftwareInfo?
    var volumes: [VolumeInfo] = []
    var drives: [DriveHealth] = []
    var battery: BatteryInfo?
    var batteryChecked = false
    var interfaces: [NetworkInterface] = []
    var peripherals: [DeviceGroup] = []
    var snapshot: Snapshot?
    var processes: [ProcessEntry] = []
    var history = History()

    var drivesLoading = true
    var peripheralsLoading = true

    /// 曲线显示最近多少秒
    var window: Int = 120

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let m = monitor

        repeatEvery(1) { m.snapshot() } apply: { $0.apply($1) }
        repeatEvery(2) { m.processes() } apply: { $0.processes = $1 }
        repeatEvery(5) { (m.battery(), m.volumes()) } apply: { s, r in
            s.battery = r.0
            s.batteryChecked = true
            s.volumes = r.1
        }
        repeatEvery(15) { m.networkInterfaces() } apply: { $0.interfaces = $1 }
        repeatEvery(300) { m.driveHealth() } apply: { s, r in
            s.drives = r
            s.drivesLoading = false
        }
        repeatEvery(60) { m.peripherals() } apply: { s, r in
            s.peripherals = r
            s.peripheralsLoading = false
        }
        // 机器和软件信息只读一次
        Task { [weak self] in
            let machine = await Task.detached(priority: .utility) { m.machine() }.value
            self?.machine = machine
            let software = await Task.detached(priority: .utility) { m.software() }.value
            self?.software = software
        }
    }

    func refreshSlow() {
        let m = monitor
        drivesLoading = true
        peripheralsLoading = true
        Task { [weak self] in
            let d = await Task.detached(priority: .userInitiated) { m.driveHealth() }.value
            self?.drives = d
            self?.drivesLoading = false
            let p = await Task.detached(priority: .userInitiated) { m.peripherals() }.value
            self?.peripherals = p
            self?.peripheralsLoading = false
            let i = await Task.detached(priority: .userInitiated) { m.networkInterfaces() }.value
            self?.interfaces = i
        }
    }

    private func repeatEvery<T: Sendable>(_ seconds: Double,
                                          _ work: @escaping @Sendable () -> T,
                                          apply: @escaping @MainActor (VitalsStore, T) -> Void) {
        Task.detached(priority: seconds <= 2 ? .userInitiated : .utility) { [weak self] in
            while !Task.isCancelled {
                let began = Date()
                let result = work()
                guard let self else { return }
                await MainActor.run { apply(self, result) }
                let rest = seconds - Date().timeIntervalSince(began)
                if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
            }
        }
    }

    private func apply(_ s: Snapshot) {
        snapshot = s
        let t = s.timestamp
        history.add(.cpu, s.cpu.total, at: t)
        history.add(.gpu, s.gpu.utilization, at: t)
        let mem = s.memory
        history.add(.memory, mem.totalBytes > 0 ? Double(mem.usedBytes) / Double(mem.totalBytes) * 100 : nil, at: t)
        history.add(.swap, Double(mem.swapUsedBytes), at: t)
        history.add(.cpuTemp, s.sensors.cpuMaxC, at: t)
        history.add(.gpuTemp, s.sensors.gpuMaxC, at: t)
        history.add(.socTemp, s.sensors.socMaxC, at: t)
        history.add(.ssdTemp, s.sensors.ssdC, at: t)
        history.add(.batteryTemp, s.sensors.batteryC, at: t)
        history.add(.systemW, s.power.systemW, at: t)
        history.add(.packageW, s.power.packageW, at: t)
        history.add(.cpuW, s.power.cpuW, at: t)
        history.add(.gpuW, s.power.gpuW, at: t)
        history.add(.aneW, s.power.aneW, at: t)
        history.add(.dramW, s.power.dramW, at: t)
        history.add(.diskRead, s.disks.reduce(0) { $0 + $1.readBytesPerSec }, at: t)
        history.add(.diskWrite, s.disks.reduce(0) { $0 + $1.writeBytesPerSec }, at: t)
        history.add(.netRx, s.network.reduce(0) { $0 + $1.rxBytesPerSec }, at: t)
        history.add(.netTx, s.network.reduce(0) { $0 + $1.txBytesPerSec }, at: t)
        for f in s.sensors.fans { history.add(.fan(f.index), f.rpm, at: t) }
        for c in s.cpu.perCore { history.add(.core(c.index), c.usage, at: t) }
        for ts in s.sensors.temperatures { history.add(.sensor(ts.key), ts.celsius, at: t) }
    }

    func samples(_ m: Metric) -> [Sample] {
        history.samples(m, last: window)
    }

    // MARK: - 便捷派生值

    var memoryPercent: Double? {
        guard let m = snapshot?.memory, m.totalBytes > 0 else { return nil }
        return Double(m.usedBytes) / Double(m.totalBytes) * 100
    }

    var internalDrive: DriveHealth? {
        drives.first(where: \.isInternal) ?? drives.first
    }

    /// 某个簇里的核（按 MachineInfo 的簇划分）
    func cores(in cluster: CPUCluster) -> [CoreLoad] {
        guard let all = snapshot?.cpu.perCore else { return [] }
        return all.filter { $0.index >= cluster.firstCoreIndex && $0.index < cluster.firstCoreIndex + cluster.coreCount }
    }

    func clusterName(forCore index: Int) -> String? {
        machine?.cpuClusters.first { index >= $0.firstCoreIndex && index < $0.firstCoreIndex + $0.coreCount }?.name
    }

    // MARK: - 导出

    struct Report: Encodable {
        let generatedAt: Date
        let machine: MachineInfo?
        let software: SoftwareInfo?
        let snapshot: Snapshot?
        let volumes: [VolumeInfo]
        let drives: [DriveHealth]
        let battery: BatteryInfo?
        let interfaces: [NetworkInterface]
        let peripherals: [DeviceGroup]
        let processes: [ProcessEntry]
    }

    func reportJSON() -> Data? {
        let r = Report(generatedAt: Date(), machine: machine, software: software, snapshot: snapshot,
                       volumes: volumes, drives: drives, battery: battery, interfaces: interfaces,
                       peripherals: peripherals, processes: processes)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try? e.encode(r)
    }
}
