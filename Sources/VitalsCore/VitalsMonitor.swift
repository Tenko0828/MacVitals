import Foundation
import Darwin
import IOKit
import CVitalsSupport

public final class VitalsMonitor: @unchecked Sendable {
    let tables: FrequencyTables
    let clusters: [CPUCluster]
    let hardware: HardwareSampler
    let snapshotLock = NSLock()
    let processLock = NSLock()
    let machineLock = NSLock()
    let softwareLock = NSLock()
    let peripheralLock = NSLock()
    var machineCache: MachineInfo?
    var softwareCache: (Date, SoftwareInfo)?
    var peripheralCache: (Date, [DeviceGroup])?
    var previousSnapshotTime: Double?
    var previousTicks: [[UInt32]] = []
    var previousVM: [Double] = []
    var previousDisks: [String: [Double]] = [:]
    var previousNetwork: [String: [Double]] = [:]
    var previousProcessTime: Double?
    var previousProcesses: [Int32: [Double]] = [:]
    let totalMemory: Int64

    public init() {
        let tables = FrequencyTables(); self.tables = tables; clusters = cpuClusters(tables)
        totalMemory = sysInt("hw.memsize") ?? Int64(ProcessInfo.processInfo.physicalMemory)
        hardware = HardwareSampler(tables: tables)
    }
    public func battery() -> BatteryInfo? { readBattery(referenceTemperature: hardware.current().sensors.batteryC) }
    public func snapshot() -> Snapshot {
        snapshotLock.holding {
            let now = ProcessInfo.processInfo.systemUptime
            let dt = previousSnapshotTime.map { now - $0 } ?? 0
            previousSnapshotTime = now
            let h = hardware.current()
            let cpu = sampleCPU(h)
            let memory = sampleMemory(dt)
            let gpu = GPULoad(utilization: n(h.gpu,"Device Utilization %").map(percent), rendererUtilization: n(h.gpu,"Renderer Utilization %").map(percent), tilerUtilization: n(h.gpu,"Tiler Utilization %").map(percent), frequencyMHz: h.frequencies["gpu"], memoryInUseBytes: i64(h.gpu,"In use system memory"), memoryAllocatedBytes: i64(h.gpu,"Alloc system memory"))
            let thermal: String
            switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = "正常"; case .fair: thermal = "偏高"; case .serious: thermal = "严重"; case .critical: thermal = "危急"; @unknown default: thermal = "未知" }
            let adapterW = h.smc["PDTR"]?.doubleValue ?? h.smc["PDBR"]?.doubleValue ?? h.adapterW
            // M5 / macOS 27 上 PMGR 的 CPU/ANE/DRAM 能量计数器不更新（读数恒为 0），只有 GPU 通道可信；
            // 这时 SoC 合计取 SMC PHPC（实测 ≈ CPU 簇 PPMC + 共享 PPSC + GPU），CPU 用“SoC 合计 − GPU”估算
            let gpuW = h.watts["gpu"]
            let pmgrAlive = (h.watts["cpu"] ?? 0) > 0.01
            let packageW = h.watts["package"].flatMap { $0 > 0.01 ? $0 : nil } ?? h.smc["PHPC"]?.doubleValue
            let cpuW = pmgrAlive ? h.watts["cpu"] : packageW.map { max(0, $0 - (gpuW ?? 0)) }
            let power = PowerStatus(systemW: h.smc["PSTR"]?.doubleValue ?? h.systemW, cpuW: cpuW, gpuW: gpuW, aneW: pmgrAlive ? h.watts["ane"] : nil, dramW: pmgrAlive ? h.watts["dram"] : nil, packageW: packageW, adapterW: adapterW, batteryPercent: h.battery?.chargePercent, isCharging: h.battery?.isCharging, onACPower: h.battery?.isPluggedIn ?? true, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: thermal, cpuEstimated: !pmgrAlive && cpuW != nil)
            return Snapshot(timestamp: Date(), uptime: now, cpu: cpu, gpu: gpu, memory: memory, sensors: h.sensors, power: power, disks: sampleDisks(dt), network: sampleNetwork(dt))
        }
    }
    func sampleCPU(_ hardware: HardwareFrame) -> CPULoad {
        var coreCount: natural_t = 0, info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        var cores: [CoreLoad] = []
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &count) == KERN_SUCCESS, let info {
            defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
            var ticks: [[UInt32]] = []
            for index in 0..<Int(coreCount) {
                let current = (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[index * Int(CPU_STATE_MAX) + $0]) }
                ticks.append(current)
                let old = index < previousTicks.count ? previousTicks[index] : current
                let diff = zip(current,old).map { Double($0 &- $1) }
                let sum = diff.reduce(0,+)
                let user = sum > 0 ? (diff[Int(CPU_STATE_USER)] + diff[Int(CPU_STATE_NICE)]) / sum * 100 : 0
                let system = sum > 0 ? diff[Int(CPU_STATE_SYSTEM)] / sum * 100 : 0
                cores.append(CoreLoad(index: index, usage: percent(user + system), user: percent(user), system: percent(system)))
            }
            previousTicks = ticks
        }
        let denominator = Double(max(1,cores.count))
        let user = cores.map(\.user).reduce(0,+) / denominator
        let system = cores.map(\.system).reduce(0,+) / denominator
        let loads = clusters.map { c -> ClusterLoad in
            let values = cores.filter { $0.index >= c.firstCoreIndex && $0.index < c.firstCoreIndex + c.coreCount }
            let name = c.name.lowercased()
            let key = name.contains("super") ? "super" : name.contains("efficiency") ? "efficiency" : "performance"
            return ClusterLoad(name: c.name, usage: values.isEmpty ? 0 : values.map(\.usage).reduce(0,+) / Double(values.count), frequencyMHz: hardware.frequencies[key])
        }
        var averages = [Double](repeating: 0,count: 3); let averageCount = getloadavg(&averages,3)
        let counts = VCCopySystemCounts() as? [String: Any] ?? [:]
        return CPULoad(total: percent(user + system), user: user, system: system, idle: max(0,100-user-system), perCore: cores, clusters: loads, loadAverage: averageCount > 0 ? Array(averages.prefix(Int(averageCount))) : [], processCount: i64(counts,"processes").map(Int.init), threadCount: (sysInt("kern.num_threads") ?? i64(counts,"threads")).map(Int.init))
    }
    func sampleMemory(_ dt: Double) -> MemoryStatus {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        var pageSize: vm_size_t = 0; host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)
        let app = max(0,Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page
        let wired = Int64(vm.wire_count) * page, compressed = Int64(vm.compressor_page_count) * page
        let cached = (Int64(vm.external_page_count) + Int64(vm.purgeable_count)) * page
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        let counters = [Double(vm.pageins),Double(vm.pageouts),Double(vm.swapins),Double(vm.swapouts),Double(vm.compressions),Double(vm.decompressions)]
        let rates = counters.enumerated().map { index,value in previousVM.count == counters.count ? delta(value,previousVM[index],dt) : 0 }
        previousVM = counters
        let pressure = sysInt("kern.memorystatus_vm_pressure_level")
        let level = pressure == 4 ? "严重" : pressure == 2 ? "警告" : pressure == 1 ? "正常" : "未知"
        return MemoryStatus(totalBytes: totalMemory, usedBytes: app + wired + compressed, appBytes: app, wiredBytes: wired, compressedBytes: compressed, cachedFilesBytes: cached, freeBytes: Int64(vm.free_count) * page, swapUsedBytes: Int64(clamping: swap.xsu_used), swapTotalBytes: Int64(clamping: swap.xsu_total), pressurePercent: sysInt("kern.memorystatus_level").map { percent(100 - Double($0)) }, pressureLevel: level, pageInsPerSec: rates[0], pageOutsPerSec: rates[1], swapInsPerSec: rates[2], swapOutsPerSec: rates[3], compressionsPerSec: rates[4], decompressionsPerSec: rates[5])
    }
    func sampleDisks(_ dt: Double) -> [DiskIO] {
        var next: [String: [Double]] = [:]
        let result = physicalDisks().compactMap { disk -> DiskIO? in
            let s = disk.statistics
            guard ["Bytes (Read)","Bytes (Write)","Operations (Read)","Operations (Write)"].allSatisfy({ s[$0] is NSNumber }) else { return nil }
            let values = [n(s,"Bytes (Read)") ?? 0,n(s,"Bytes (Write)") ?? 0,n(s,"Operations (Read)") ?? 0,n(s,"Operations (Write)") ?? 0]
            let old = previousDisks[disk.name] ?? values; next[disk.name] = values
            let rates = zip(values,old).map { delta($0,$1,dt) }
            return DiskIO(bsdName: disk.name, readBytesPerSec: rates[0], writeBytesPerSec: rates[1], readOpsPerSec: rates[2], writeOpsPerSec: rates[3], totalReadBytes: i64(s,"Bytes (Read)") ?? 0, totalWrittenBytes: i64(s,"Bytes (Write)") ?? 0)
        }
        previousDisks = next; return result
    }
    func sampleNetwork(_ dt: Double) -> [NetIO] {
        let counters = VCCopyNetworkCounters() as? [[String: Any]] ?? []
        var next: [String: [Double]] = [:]
        let result = counters.compactMap { d -> NetIO? in
            guard let name = d["name"] as? String else { return nil }
            let values = [n(d,"rx") ?? 0,n(d,"tx") ?? 0]; let old = previousNetwork[name] ?? values; next[name] = values
            return NetIO(bsdName: name, rxBytesPerSec: delta(values[0],old[0],dt), txBytesPerSec: delta(values[1],old[1],dt), totalRxBytes: i64(d,"rx") ?? 0, totalTxBytes: i64(d,"tx") ?? 0)
        }
        previousNetwork = next; return result.sorted { $0.bsdName < $1.bsdName }
    }
    public func processes() -> [ProcessEntry] {
        processLock.holding {
            let now = ProcessInfo.processInfo.systemUptime
            let dt = previousProcessTime.map { now - $0 } ?? 0; previousProcessTime = now
            var records = VCCopyProcesses() as? [[String: Any]] ?? []
            // 其他用户（root、_windowserver……）的进程 libproc 读不到，用 setuid 的 /bin/ps 补 CPU 时间和内存
            if records.contains(where: { $0["cpuNS"] == nil }) {
                let ps = psCounters()
                records = records.map { d in
                    guard d["cpuNS"] == nil, let pid = i64(d,"pid"), let c = ps[Int32(pid)] else { return d }
                    var d = d; d["cpuNS"] = c.cpuNS; d["resident"] = c.rss; d["footprint"] = c.rss; return d
                }
            }
            var next: [Int32: [Double]] = [:]
            let result = records.compactMap { d -> ProcessEntry? in
                guard let pid = i64(d,"pid") else { return nil }
                let id = Int32(pid)
                let values = [n(d,"cpuNS") ?? 0,n(d,"read") ?? 0,n(d,"write") ?? 0,n(d,"identity") ?? n(d,"start") ?? 0,n(d,"energy") ?? 0]
                let old = previousProcesses[id].flatMap { $0[3] == values[3] ? $0 : nil } ?? values
                next[id] = values
                let path = d["path"] as? String
                return ProcessEntry(pid: id, ppid: Int32(i64(d,"ppid") ?? 0), name: d["name"] as? String ?? "PID \(pid)", path: path, user: d["user"] as? String ?? "", cpuPercent: delta(values[0],old[0],dt) / 1e9 * 100, memoryBytes: i64(d,"footprint") ?? 0, residentBytes: i64(d,"resident") ?? 0, threads: Int(i64(d,"threads") ?? 0), diskReadBytesPerSec: delta(values[1],old[1],dt), diskWriteBytesPerSec: delta(values[2],old[2],dt), totalDiskReadBytes: i64(d,"read") ?? 0, totalDiskWrittenBytes: i64(d,"write") ?? 0, energyImpact: values[4] > 0 ? delta(values[4],old[4],dt) / 1e6 : nil, startTime: n(d,"start").map { Date(timeIntervalSince1970: $0) }, isApp: path?.contains(".app/") ?? false)
            }
            previousProcesses = next; return result.sorted { $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent }
        }
    }
}

/// ps -A 的累计 CPU 时间（纳秒）和常驻内存（字节）
func psCounters() -> [Int32: (cpuNS: Double, rss: Int64)] {
    let task = Process(); let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-A", "-o", "pid=,time=,rss="]
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    var result: [Int32: (cpuNS: Double, rss: Int64)] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count == 3, let pid = Int32(f[0]), let rss = Int64(f[2]) else { continue }
        // time 形如 [[dd-]hh:]mm:ss.cc
        var t = f[1][...]; var days = 0.0
        if let dash = t.firstIndex(of: "-") { days = Double(t[..<dash]) ?? 0; t = t[t.index(after: dash)...] }
        let secs = t.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) } + days * 86400
        result[pid] = (secs * 1e9, rss * 1024)
    }
    return result
}
