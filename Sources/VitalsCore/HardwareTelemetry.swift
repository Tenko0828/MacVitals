import Foundation
import IOKit
import IOKit.ps
import CVitalsSupport

// SRAM 表在 M4 起使用 kHz；普通表在新芯片上还可能包含非频率编码。
func decodeFrequencyTable(_ data: Data) -> [Double] {
    guard data.count % 8 == 0 else { return [] }
    return stride(from: 0, to: data.count, by: 8).compactMap { off in
        let raw = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)) }
        let mhz = Double(raw) / (raw >= 100_000_000 ? 1e6 : 1e3)
        return mhz >= 100 && mhz <= 10000 ? mhz : nil
    }
}
struct FrequencyTables {
    var efficiency: [Double] = []
    var performance: [Double] = []
    var superCore: [Double] = []
    var gpu: [Double] = []
    var domains: [Int: [Double]] = [:]
    init() {
        var p: [String: Any] = [:]
        registryEntries("AppleARMIODevice") { e in if entryName(e).hasPrefix("pmgr") { p = registryProperties(e) } }
        func table(_ id: Int, cpu: Bool = true) -> [Double] {
            let key = "voltage-states\(id)"
            if cpu, let d = p[key + "-sram"] as? Data { return decodeFrequencyTable(d) }
            return (p[key] as? Data).map(decodeFrequencyTable) ?? []
        }
        gpu = table(9,cpu:false)
        if let clusters = p["acc-clusters"] as? Data, clusters.count % 8 == 0 {
            for off in stride(from:0,to:clusters.count,by:8) {
                let id = Int(clusters[off]); let t = table(id)
                if !t.isEmpty { domains[id] = t }
            }
        }
        if domains.isEmpty { efficiency = table(1); performance = table(5) }
        else {
            let hasSuper = (0..<8).contains { (sysString("hw.perflevel\($0).name") ?? "").lowercased().contains("super") }
            let sorted = domains.values.sorted { ($0.max() ?? 0) < ($1.max() ?? 0) }
            if hasSuper {
                superCore = sorted.last ?? []
                if sysInt("hw.perflevel1.logicalcpu") != nil { performance = sorted.first ?? [] }
            } else { efficiency = sorted.first ?? []; performance = sorted.last ?? [] }
        }
    }
    func cpuTable(_ channel: String) -> (String, [Double])? {
        if channel.contains("ecpu") || channel.contains("e-core") { return ("efficiency",efficiency) }
        if channel.contains("mcpu") { return ("performance",performance) }
        if channel.contains("pcpu") || channel.contains("p-core") { return superCore.isEmpty ? ("performance",performance) : ("super",superCore) }
        if channel.contains("scpu") || channel.contains("s-core") { return ("super",superCore) }
        return nil
    }
}

func cpuClusters(_ tables: FrequencyTables) -> [CPUCluster] {
    var result: [CPUCluster] = []
    // Apple Silicon 的 Mach 逻辑核排列通常为低功耗簇在前，perflevel 编号反过来。
    let levels = (0..<8).compactMap { level -> (String, Int, Int64?)? in
        guard let count = sysInt("hw.perflevel\(level).logicalcpu"), count > 0 else { return nil }
        return (sysString("hw.perflevel\(level).name") ?? "CPU 簇 \(level)", Int(count), sysInt("hw.perflevel\(level).l2cachesize"))
    }.reversed()
    var index = 0
    for (name, count, l2) in levels {
        let lower = name.lowercased(); let e = lower.contains("efficiency") || lower.contains("能效")
        result.append(CPUCluster(name: name, coreCount: count, firstCoreIndex: index, maxFrequencyMHz: (lower.contains("super") ? tables.superCore : e ? tables.efficiency : tables.performance).max(), l2CacheBytes: l2)); index += count
    }
    if result.isEmpty { result = [CPUCluster(name: "CPU", coreCount: ProcessInfo.processInfo.processorCount, firstCoreIndex: 0)] }
    return result
}
func sensorIdentity(_ key: String) -> (String, SensorGroup) {
    let original = key.lowercased()
    let s = original.hasPrefix("pmu ") ? String(original.dropFirst(4)) : original
    if s.contains("battery") || s.hasPrefix("tb") { return ("电池温度 · \(key)", .battery) }
    if s.contains("nand") || s.contains("ssd") || s.hasPrefix("tn") || s.hasPrefix("th") { return ("存储温度 · \(key)", .storage) }
    if key.hasPrefix("Tp") { return ("CPU 核心 · \(key)", .cpu) }
    if s.hasPrefix("tdie") { return ("CPU 晶粒 · \(key)", .cpu) }
    if key == "Ts0P" || key == "Ts1P" { return ("掌托 · \(key)", .ambient) }
    if s.contains("tdie") || s.contains("pacc") || s.contains("eacc") || s.contains("cpu") || s.hasPrefix("tp") || s.hasPrefix("tc") { return ("CPU 其它 · \(key)", .cpu) }
    if key.hasPrefix("Tg") { return ("GPU 核心 · \(key)", .gpu) }
    if s.contains("tdev") || s.contains("gpu") || s.hasPrefix("tg") { return ("GPU 温度 · \(key)", .gpu) }
    if s.contains("dram") || s.contains("memory") || s.hasPrefix("tm") { return ("内存温度 · \(key)", .memory) }
    if s.contains("ambient") || s.hasPrefix("ta") { return ("环境温度 · \(key)", .ambient) }
    if s.contains("soc") || original.contains("pmu") || s.contains("ane") || s.contains("isp") || s.hasPrefix("ts") { return ("SoC 温度 · \(key)", .soc) }
    return ("温度 · \(key)", .other)
}
func sensorReadings(_ raw: [String: Any]) -> SensorReadings {
    let hid = raw["hid"] as? [String: NSNumber] ?? [:]
    let smc = raw["smc"] as? [String: NSNumber] ?? [:]
    var sensors: [TemperatureSensor] = []
    // HID 中形如 PMU TP0P 的名称与 SMC 同一个 key，优先保留 HID。
    var aliases = Set<String>()
    for key in hid.keys.sorted() {
        let v = hid[key]!.doubleValue
        guard v.isFinite, v > 0, v <= 150 else { continue }
        let (name, group) = sensorIdentity(key)
        sensors.append(TemperatureSensor(key: key, name: name, group: group, celsius: v))
        if key.hasPrefix("PMU ") { aliases.insert(String(key.dropFirst(4)).lowercased()) }
    }
    for key in smc.keys.sorted() where key.hasPrefix("T") && !aliases.contains(key.lowercased()) {
        let v = smc[key]!.doubleValue
        guard v.isFinite, v > 0, v <= 150 else { continue }
        let (name, group) = sensorIdentity(key)
        sensors.append(TemperatureSensor(key: key, name: name, group: group, celsius: v))
    }
    var fans: [FanReading] = []
    let count = min(16, max(0, smc["FNum"]?.intValue ?? 0))
    for index in 0..<count {
        guard let rpm = smc["F\(index)Ac"]?.doubleValue, rpm.isFinite, rpm >= 0 else { continue }
        fans.append(FanReading(index: index, rpm: rpm, minRPM: smc["F\(index)Mn"]?.doubleValue, maxRPM: smc["F\(index)Mx"]?.doubleValue, targetRPM: smc["F\(index)Tg"]?.doubleValue))
    }
    func values(_ groups: [SensorGroup]) -> [Double] { sensors.filter { groups.contains($0.group) }.map(\.celsius) }
    func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0,+) / Double(a.count) }
    // 汇总只用核心传感器（SMC Tp*/Tg*、HID tdie/tdev）；TCMb 这类含义不明的推算值和 Ts0P（掌托）不参与
    func core(_ prefixes: [String]) -> [Double] {
        sensors.filter { s in prefixes.contains { s.key.hasPrefix($0) } }.map(\.celsius)
    }
    var cpuCore = core(["Tp", "PMU tdie"]), gpuCore = core(["Tg", "PMU tdev"])
    if cpuCore.isEmpty { cpuCore = values([.cpu]) }
    if gpuCore.isEmpty { gpuCore = values([.gpu]) }
    return SensorReadings(temperatures: sensors, fans: fans, cpuAvgC: avg(cpuCore), cpuMaxC: cpuCore.max(), gpuAvgC: avg(gpuCore), gpuMaxC: gpuCore.max(), socMaxC: (cpuCore + gpuCore).max(), batteryC: avg(values([.battery])), ssdC: values([.storage]).max())
}
func adapterDetails() -> [String: Any] {
    IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]
}
// 两种单位在室温区间会重叠，优先采用已知单位或独立温度参考；默认遵循 AppleSmartBattery 的 0.01°C。
func batteryTemperature(_ raw: Double?, referenceCelsius: Double? = nil, unit: String? = nil) -> Double? {
    guard let raw, raw.isFinite, raw > 0 else { return nil }
    let centiC = raw / 100, deciK = raw / 10 - 273.15
    let c: Double
    if let unit, unit.lowercased().contains("k") { c = deciK }
    else if let referenceCelsius, deciK > 0, abs(deciK-referenceCelsius) < abs(centiC-referenceCelsius) { c = deciK }
    else { c = centiC }
    return c > 0 && c <= 150 ? c : nil
}

func readBattery(referenceTemperature: Double? = nil) -> BatteryInfo? {
    let p = registryFirst("AppleSmartBattery")
    guard !p.isEmpty, p["BatteryInstalled"] as? Bool != false else { return nil }
    var source: [String: Any] = [:]
    if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
        for item in list {
            if let d = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any], d["Type"] as? String == "InternalBattery" { source = d; break }
        }
    }
    let data = p["BatteryData"] as? [String: Any] ?? [:]
    let design = n(p,"DesignCapacity") ?? n(data,"DesignCapacity")
    let maximum = n(p,"AppleRawMaxCapacity") ?? n(data,"FullChargeCapacity")
    let current = n(p,"AppleRawCurrentCapacity") ?? n(data,"RemainingCapacity")
    let voltage = n(p,"Voltage").map { $0 / 1000 }
    var amp = n(p,"Amperage")
    // 有的驱动把有符号电流装进无符号 NSNumber。
    if let raw = p["Amperage"] as? NSNumber, raw.uint64Value > UInt64(Int64.max) { amp = Double(Int64(bitPattern: raw.uint64Value)) }
    if let a = amp, a > Double(Int32.max), a <= Double(UInt32.max) { amp = Double(Int32(bitPattern: UInt32(a))) }
    let amperage = amp.map { $0 / 1000 }
    var adapter = adapterDetails()
    if adapter.isEmpty { adapter = p["AdapterDetails"] as? [String: Any] ?? [:] }
    let charging = p["IsCharging"] as? Bool ?? false
    let remaining = n(source, charging ? "Time to Full Charge" : "Time to Empty") ?? n(p,charging ? "AvgTimeToFull" : "AvgTimeToEmpty")
    let state = source["BatteryHealth"] as? String ?? p["BatteryHealth"] as? String
    var sections = [InfoSection(title: "电池详情", items: flatten(p)), InfoSection(title: "电源描述", items: flatten(source)), InfoSection(title: "适配器", items: flatten(adapter))]
    if let date = n(p,"ManufactureDate") {
        let d = Int(date); sections.append(InfoSection(title: "生产日期", items: [InfoItem("日期", String(format: "%04d-%02d-%02d", 1980 + (d >> 9), (d >> 5) & 15, d & 31))]))
    }
    let charge = n(source,"Current Capacity").flatMap { x in n(source,"Max Capacity").flatMap { $0 > 0 ? x / $0 * 100 : nil } } ?? n(p,"CurrentCapacity").flatMap { x in n(p,"MaxCapacity").flatMap { $0 > 0 ? x / $0 * 100 : nil } } ?? 0
    return BatteryInfo(chargePercent: percent(charge), isCharging: charging, isPluggedIn: p["ExternalConnected"] as? Bool ?? false, isFullyCharged: p["FullyCharged"] as? Bool ?? false, timeRemainingMinutes: remaining.flatMap { $0 > 0 && $0 < 65535 ? Int($0) : nil }, cycleCount: i64(p,"CycleCount").map(Int.init), designCapacitymAh: design.map(Int.init), maxCapacitymAh: maximum.map(Int.init), currentCapacitymAh: current.map(Int.init), healthPercent: maximum.flatMap { m in design.flatMap { $0 > 0 ? percent(m / $0 * 100) : nil } }, condition: state.map { $0.lowercased().contains("good") ? "正常" : $0 }, temperatureC: batteryTemperature(n(p,"Temperature") ?? n(data,"Temperature"), referenceCelsius: referenceTemperature, unit: p["TemperatureUnit"] as? String), voltageV: voltage, amperageA: amperage, powerW: voltage.flatMap { v in amperage.map { v * $0 } }, adapterWatts: n(adapter,"Watts"), adapterName: adapter["Name"] as? String ?? adapter["Description"] as? String, sections: sections.filter { !$0.items.isEmpty })
}
struct HardwareFrame {
    var sensors = sensorReadings([:])
    var smc: [String: NSNumber] = [:]
    var watts: [String: Double] = [:]
    var frequencies: [String: Double] = [:]
    var battery: BatteryInfo?
    var gpu: [String: Any] = [:]
    var systemW: Double?
    var adapterW: Double?
    var diagnostics: [String: Any] = [:]
}
// 所有私有连接只在此串行队列内使用；快接口只复制已完成的帧。
final class HardwareSampler: @unchecked Sendable {
    let tables: FrequencyTables
    private let native: OpaquePointer?
    private let queue = DispatchQueue(label: "MacVitals.hardware", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var frame = HardwareFrame()
    private var previousTime: Double?
    private var tick = 0
    private var lastFull: [String: Any] = [:]
    init(tables: FrequencyTables) {
        self.tables = tables; native = VCCreate()
        update()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.update() }; self.timer = timer; timer.resume()
    }
    deinit { timer?.cancel(); if let native { VCDestroy(native) } }
    func current() -> HardwareFrame { lock.holding { frame } }
    private func update() {
        guard let native else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = previousTime.map { now - $0 } ?? 0; previousTime = now
        // 全部传感器每 5 秒扫一次，其余时间只读核心 key，再叠加到上一次的完整结果上
        let full = tick % 5 == 0; tick += 1
        let fresh = VCCopySensors(native, full) as? [String: Any] ?? [:]
        if full { lastFull = fresh }
        var raw = lastFull
        raw["smc"] = (lastFull["smc"] as? [String: NSNumber] ?? [:]).merging(fresh["smc"] as? [String: NSNumber] ?? [:]) { $1 }
        let report = VCCopyReport(native) as? [[String: Any]] ?? []
        var next = HardwareFrame(); next.sensors = sensorReadings(raw); next.smc = raw["smc"] as? [String: NSNumber] ?? [:]
        next.battery = readBattery(referenceTemperature: next.sensors.batteryC)
        let batteryProperties = registryFirst("AppleSmartBattery")
        let telemetry = batteryProperties["PowerTelemetryData"] as? [String: Any] ?? [:]
        next.systemW = n(telemetry,"SystemLoad").map { $0 / 1000 }
        if let voltage = n(telemetry,"SystemVoltageIn"),let current = n(telemetry,"SystemCurrentIn") { next.adapterW = voltage * current / 1e6 }
        else { next.adapterW = n(telemetry,"SystemPowerIn").map { $0 / 1000 } }
        next.diagnostics = raw["diagnostics"] as? [String: Any] ?? [:]
        next.diagnostics["IOReport 可读通道数"] = report.count
        registryEntries("IOAccelerator") { e in if next.gpu.isEmpty { next.gpu = registryProperty(e,"PerformanceStatistics") as? [String: Any] ?? [:] } }
        var frequencyTotals: [String: (Double,Double)] = [:]
        var energyValues: [String: [(String,Double)]] = [:]
        for channel in report {
            let name = (channel["name"] as? String ?? "").lowercased()
            let group = channel["group"] as? String ?? ""
            if group == "Energy Model", dt > 0, let value = n(channel,"value"), value >= 0 {
                let unit = (channel["unit"] as? String ?? "").lowercased()
                let scale: Double?
                switch unit { case "nj": scale = 1e-9; case "uj", "µj", "μj": scale = 1e-6; case "mj": scale = 1e-3; case "j": scale = 1; default: scale = nil }
                guard let scale else { continue }
                let type: String?
                if name.contains("cpu") { type = "cpu" } else if name.contains("gpu") { type = "gpu" } else if name.contains("ane") { type = "ane" } else if name.contains("dram") || name.contains("dcs") { type = "dram" } else if name == "soc" || name.contains("package") { type = "package" } else { type = nil }
                if let type { energyValues[type, default: []].append((name,value * scale / dt)) }
            } else if let states = channel["states"] as? [[String: Any]], !states.isEmpty {
                let kind: String
                let table: [Double]
                if group == "GPU Stats", name.contains("gpu") { kind = "gpu"; table = tables.gpu }
                else if let cpu = tables.cpuTable(name) { kind = cpu.0; table = cpu.1 }
                else { continue }
                var weighted = 0.0, ticks = 0.0, activeIndex = 0
                for state in states {
                    let label = (state["name"] as? String ?? "").lowercased()
                    if ["idle","off","down","sleep"].contains(where: { label.contains($0) }) { continue }
                    let residency = n(state,"ticks") ?? 0
                    var freq: Double?
                    if label.hasSuffix("mhz") { freq = Double(label.replacingOccurrences(of: "mhz", with: "").trimmingCharacters(in: .whitespaces)) }
                    else if activeIndex < table.count { freq = table[activeIndex] }
                    activeIndex += 1
                    if let freq, residency > 0 { weighted += freq * residency; ticks += residency }
                }
                if ticks > 0 { let old = frequencyTotals[kind] ?? (0,0); frequencyTotals[kind] = (old.0 + weighted,old.1 + ticks) }
            }
        }
        for (kind,values) in energyValues {
            let aggregate = values.first { $0.0 == kind || $0.0 == kind + " energy" || $0.0 == "soc" }
            next.watts[kind] = aggregate?.1 ?? values.reduce(0) { $0 + $1.1 }
        }
        if let batteryC = next.battery?.temperatureC, next.sensors.batteryC == nil {
            next.sensors.batteryC = batteryC
            next.sensors.temperatures.append(TemperatureSensor(key:"AppleSmartBattery",name:"电池温度",group:.battery,celsius:batteryC))
        }
        for (kind,(weighted,ticks)) in frequencyTotals { next.frequencies[kind] = weighted / ticks }
        lock.holding { frame = next }
    }
}
