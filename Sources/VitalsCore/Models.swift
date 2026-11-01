import Foundation

// 前后端契约：VitalsCore 负责填充这些结构，App 只读不写。
// 约定：
// - 单位：字节 = Int64/UInt64 原始字节；速率 = 字节/秒；温度 = 摄氏度；功率 = 瓦；频率 = MHz；百分比 = 0...100
// - 读不到的值一律给 nil，不要用 0 或 -1 冒充
// - 结构里只放机器能稳定读到的“骨架”字段；其余想展示的信息塞进 InfoSection（键值对），越多越好

// MARK: - 通用键值信息

public struct InfoItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var value: String
    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

public struct InfoSection: Codable, Sendable, Hashable, Identifiable {
    public var id: String { title }
    public var title: String
    public var items: [InfoItem]
    public init(title: String, items: [InfoItem]) {
        self.title = title
        self.items = items
    }
}

// MARK: - 静态信息（启动时读一次，之后很少变）

public struct CPUCluster: Codable, Sendable, Hashable {
    public var name: String            // 例如 "性能核" / "能效核"（hw.perflevelN.name）
    public var coreCount: Int
    public var firstCoreIndex: Int     // 这个簇的第一个逻辑核在 CPULoad.perCore 里的下标
    public var maxFrequencyMHz: Double?
    public var l2CacheBytes: Int64?
    public init(name: String, coreCount: Int, firstCoreIndex: Int, maxFrequencyMHz: Double? = nil, l2CacheBytes: Int64? = nil) {
        self.name = name
        self.coreCount = coreCount
        self.firstCoreIndex = firstCoreIndex
        self.maxFrequencyMHz = maxFrequencyMHz
        self.l2CacheBytes = l2CacheBytes
    }
}

public struct MachineInfo: Codable, Sendable {
    public var modelName: String               // "MacBook Pro"
    public var modelIdentifier: String         // "Mac17,2"
    public var chip: String                    // "Apple M5 Pro"
    public var serialNumber: String?
    public var cpuClusters: [CPUCluster]
    public var logicalCores: Int
    public var gpuCores: Int?
    public var neuralEngineCores: Int?
    public var memoryBytes: Int64
    public var memoryType: String?             // "LPDDR5X"
    public var memoryManufacturer: String?
    public var firmwareVersion: String?
    public var osLoaderVersion: String?
    public var isLaptop: Bool
    public var sections: [InfoSection]         // 其余所有硬件信息（缓存大小、指令集特性、页大小……）
    public init(modelName: String, modelIdentifier: String, chip: String, serialNumber: String?, cpuClusters: [CPUCluster], logicalCores: Int, gpuCores: Int?, neuralEngineCores: Int?, memoryBytes: Int64, memoryType: String?, memoryManufacturer: String?, firmwareVersion: String?, osLoaderVersion: String?, isLaptop: Bool, sections: [InfoSection]) {
        self.modelName = modelName
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.serialNumber = serialNumber
        self.cpuClusters = cpuClusters
        self.logicalCores = logicalCores
        self.gpuCores = gpuCores
        self.neuralEngineCores = neuralEngineCores
        self.memoryBytes = memoryBytes
        self.memoryType = memoryType
        self.memoryManufacturer = memoryManufacturer
        self.firmwareVersion = firmwareVersion
        self.osLoaderVersion = osLoaderVersion
        self.isLaptop = isLaptop
        self.sections = sections
    }
}

public struct SoftwareInfo: Codable, Sendable {
    public var osName: String                  // "macOS Tahoe" 之类，读不到就 "macOS"
    public var osVersion: String               // "27.0.1"
    public var osBuild: String
    public var kernelVersion: String           // uname -v
    public var hostname: String
    public var computerName: String
    public var userName: String
    public var bootTime: Date
    public var sipEnabled: Bool?
    public var fileVaultOn: Bool?
    public var gatekeeperOn: Bool?
    public var firewallOn: Bool?
    public var sections: [InfoSection]         // 安全、开发工具、语言运行时、Homebrew、App 数量、登录项、区域时区……越多越好
    public init(osName: String, osVersion: String, osBuild: String, kernelVersion: String, hostname: String, computerName: String, userName: String, bootTime: Date, sipEnabled: Bool?, fileVaultOn: Bool?, gatekeeperOn: Bool?, firewallOn: Bool?, sections: [InfoSection]) {
        self.osName = osName
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.kernelVersion = kernelVersion
        self.hostname = hostname
        self.computerName = computerName
        self.userName = userName
        self.bootTime = bootTime
        self.sipEnabled = sipEnabled
        self.fileVaultOn = fileVaultOn
        self.gatekeeperOn = gatekeeperOn
        self.firewallOn = firewallOn
        self.sections = sections
    }
}

// MARK: - 存储与寿命

public struct VolumeInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { mountPoint }
    public var name: String
    public var mountPoint: String
    public var fileSystem: String              // "apfs"
    public var bsdName: String?                // "disk3s1s1"
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var availableBytes: Int64?          // 含可清除空间（volumeAvailableCapacityForImportantUsage）
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isReadOnly: Bool
    public init(name: String, mountPoint: String, fileSystem: String, bsdName: String?, totalBytes: Int64, freeBytes: Int64, availableBytes: Int64?, isInternal: Bool, isRemovable: Bool, isReadOnly: Bool) {
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.bsdName = bsdName
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
    }
}

public struct DriveHealth: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String                 // "disk0"
    public var model: String?
    public var serial: String?
    public var firmware: String?
    public var capacityBytes: Int64?
    public var isInternal: Bool
    public var smartPassed: Bool?
    public var criticalWarning: Int?
    public var temperatureC: Double?
    public var percentageUsed: Double?         // 已用寿命 %
    public var availableSpare: Double?
    public var availableSpareThreshold: Double?
    public var dataReadBytes: Int64?
    public var dataWrittenBytes: Int64?
    public var powerOnHours: Int?
    public var powerCycles: Int?
    public var unsafeShutdowns: Int?
    public var mediaErrors: Int?
    public var errorLogEntries: Int?
    public var source: String                  // "smartctl" / "IOKit" / "unavailable"
    public var note: String?                   // 例如“未安装 smartmontools，brew install smartmontools 后可读寿命”
    public init(bsdName: String, model: String? = nil, serial: String? = nil, firmware: String? = nil, capacityBytes: Int64? = nil, isInternal: Bool, smartPassed: Bool? = nil, criticalWarning: Int? = nil, temperatureC: Double? = nil, percentageUsed: Double? = nil, availableSpare: Double? = nil, availableSpareThreshold: Double? = nil, dataReadBytes: Int64? = nil, dataWrittenBytes: Int64? = nil, powerOnHours: Int? = nil, powerCycles: Int? = nil, unsafeShutdowns: Int? = nil, mediaErrors: Int? = nil, errorLogEntries: Int? = nil, source: String, note: String? = nil) {
        self.bsdName = bsdName
        self.model = model
        self.serial = serial
        self.firmware = firmware
        self.capacityBytes = capacityBytes
        self.isInternal = isInternal
        self.smartPassed = smartPassed
        self.criticalWarning = criticalWarning
        self.temperatureC = temperatureC
        self.percentageUsed = percentageUsed
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.dataReadBytes = dataReadBytes
        self.dataWrittenBytes = dataWrittenBytes
        self.powerOnHours = powerOnHours
        self.powerCycles = powerCycles
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.errorLogEntries = errorLogEntries
        self.source = source
        self.note = note
    }
}

// MARK: - 电池

public struct BatteryInfo: Codable, Sendable {
    public var chargePercent: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    public var timeRemainingMinutes: Int?      // 放电时为剩余时间，充电时为充满时间
    public var cycleCount: Int?
    public var designCapacitymAh: Int?
    public var maxCapacitymAh: Int?            // 当前满电容量（AppleRawMaxCapacity）
    public var currentCapacitymAh: Int?
    public var healthPercent: Double?          // maxCapacity / designCapacity
    public var condition: String?              // "正常" / "建议维修"
    public var temperatureC: Double?
    public var voltageV: Double?
    public var amperageA: Double?              // 正 = 充电，负 = 放电
    public var powerW: Double?                 // 电池端功率，正 = 充入
    public var adapterWatts: Double?
    public var adapterName: String?
    public var sections: [InfoSection]         // 序列号、生产日期、电芯电压、优化充电、AppleSmartBattery 里其它字段……
    public init(chargePercent: Double, isCharging: Bool, isPluggedIn: Bool, isFullyCharged: Bool, timeRemainingMinutes: Int?, cycleCount: Int?, designCapacitymAh: Int?, maxCapacitymAh: Int?, currentCapacitymAh: Int?, healthPercent: Double?, condition: String?, temperatureC: Double?, voltageV: Double?, amperageA: Double?, powerW: Double?, adapterWatts: Double?, adapterName: String?, sections: [InfoSection]) {
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFullyCharged = isFullyCharged
        self.timeRemainingMinutes = timeRemainingMinutes
        self.cycleCount = cycleCount
        self.designCapacitymAh = designCapacitymAh
        self.maxCapacitymAh = maxCapacitymAh
        self.currentCapacitymAh = currentCapacitymAh
        self.healthPercent = healthPercent
        self.condition = condition
        self.temperatureC = temperatureC
        self.voltageV = voltageV
        self.amperageA = amperageA
        self.powerW = powerW
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
        self.sections = sections
    }
}

// MARK: - 网络与外设

public struct NetworkInterface: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String                 // "en0"
    public var displayName: String             // "Wi-Fi"
    public var kind: String                    // "Wi-Fi" / "以太网" / "雷雳网桥" / "VPN" / "回环" / "其它"
    public var macAddress: String?
    public var ipv4: [String]
    public var ipv6: [String]
    public var isUp: Bool
    public var mtu: Int?
    public var linkSpeedMbps: Double?
    public var sections: [InfoSection]         // Wi-Fi 信道/频段/信号/噪声/PHY 模式、路由器、DNS……
    public init(bsdName: String, displayName: String, kind: String, macAddress: String?, ipv4: [String], ipv6: [String], isUp: Bool, mtu: Int?, linkSpeedMbps: Double?, sections: [InfoSection]) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.kind = kind
        self.macAddress = macAddress
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.isUp = isUp
        self.mtu = mtu
        self.linkSpeedMbps = linkSpeedMbps
        self.sections = sections
    }
}

/// 一类外设，例如“显示器”“USB”“雷雳”“蓝牙”“音频”“摄像头”；每个设备是一个 InfoSection（title = 设备名）
public struct DeviceGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: String { title }
    public var title: String
    public var symbol: String                  // SF Symbols 名，例如 "display" / "cable.connector" / "dot.radiowaves.left.and.right"
    public var devices: [InfoSection]
    public init(title: String, symbol: String, devices: [InfoSection]) {
        self.title = title
        self.symbol = symbol
        self.devices = devices
    }
}

// MARK: - 实时采样（每秒一次）

public struct CoreLoad: Codable, Sendable, Hashable {
    public var index: Int
    public var usage: Double                   // 0...100
    public var user: Double
    public var system: Double
    public init(index: Int, usage: Double, user: Double, system: Double) {
        self.index = index
        self.usage = usage
        self.user = user
        self.system = system
    }
}

public struct ClusterLoad: Codable, Sendable, Hashable {
    public var name: String                    // 与 CPUCluster.name 对应
    public var usage: Double                   // 该簇平均占用
    public var frequencyMHz: Double?           // 当前平均频率（IOReport，读不到给 nil）
    public init(name: String, usage: Double, frequencyMHz: Double?) {
        self.name = name
        self.usage = usage
        self.frequencyMHz = frequencyMHz
    }
}

public struct CPULoad: Codable, Sendable {
    public var total: Double
    public var user: Double
    public var system: Double
    public var idle: Double
    public var perCore: [CoreLoad]
    public var clusters: [ClusterLoad]
    public var loadAverage: [Double]           // 1/5/15 分钟
    public var processCount: Int?
    public var threadCount: Int?
    public init(total: Double, user: Double, system: Double, idle: Double, perCore: [CoreLoad], clusters: [ClusterLoad], loadAverage: [Double], processCount: Int?, threadCount: Int?) {
        self.total = total
        self.user = user
        self.system = system
        self.idle = idle
        self.perCore = perCore
        self.clusters = clusters
        self.loadAverage = loadAverage
        self.processCount = processCount
        self.threadCount = threadCount
    }
}

public struct GPULoad: Codable, Sendable {
    public var utilization: Double?            // Device Utilization %
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    public var frequencyMHz: Double?
    public var memoryInUseBytes: Int64?        // In use system memory
    public var memoryAllocatedBytes: Int64?    // Alloc system memory
    public init(utilization: Double?, rendererUtilization: Double?, tilerUtilization: Double?, frequencyMHz: Double?, memoryInUseBytes: Int64?, memoryAllocatedBytes: Int64?) {
        self.utilization = utilization
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.frequencyMHz = frequencyMHz
        self.memoryInUseBytes = memoryInUseBytes
        self.memoryAllocatedBytes = memoryAllocatedBytes
    }
}

public struct MemoryStatus: Codable, Sendable {
    public var totalBytes: Int64
    public var usedBytes: Int64                // 与活动监视器“已使用内存”口径一致：App 内存 + 联动 + 被压缩
    public var appBytes: Int64
    public var wiredBytes: Int64
    public var compressedBytes: Int64
    public var cachedFilesBytes: Int64
    public var freeBytes: Int64
    public var swapUsedBytes: Int64
    public var swapTotalBytes: Int64
    public var pressurePercent: Double?        // 内存压力 0...100（kern.memorystatus_level 反算）
    public var pressureLevel: String           // "正常" / "警告" / "严重"
    public var pageInsPerSec: Double
    public var pageOutsPerSec: Double
    public var swapInsPerSec: Double
    public var swapOutsPerSec: Double
    public var compressionsPerSec: Double
    public var decompressionsPerSec: Double
    public init(totalBytes: Int64, usedBytes: Int64, appBytes: Int64, wiredBytes: Int64, compressedBytes: Int64, cachedFilesBytes: Int64, freeBytes: Int64, swapUsedBytes: Int64, swapTotalBytes: Int64, pressurePercent: Double?, pressureLevel: String, pageInsPerSec: Double, pageOutsPerSec: Double, swapInsPerSec: Double, swapOutsPerSec: Double, compressionsPerSec: Double, decompressionsPerSec: Double) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressurePercent = pressurePercent
        self.pressureLevel = pressureLevel
        self.pageInsPerSec = pageInsPerSec
        self.pageOutsPerSec = pageOutsPerSec
        self.swapInsPerSec = swapInsPerSec
        self.swapOutsPerSec = swapOutsPerSec
        self.compressionsPerSec = compressionsPerSec
        self.decompressionsPerSec = decompressionsPerSec
    }
}

public enum SensorGroup: String, Codable, Sendable, CaseIterable {
    case cpu, gpu, soc, memory, storage, battery, ambient, other
}

public struct TemperatureSensor: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String                     // 原始名，例如 "PMU tdie3" / SMC "Tp01"，要唯一
    public var name: String                    // 给人看的名字，例如 "CPU 性能核 3"
    public var group: SensorGroup
    public var celsius: Double
    public init(key: String, name: String, group: SensorGroup, celsius: Double) {
        self.key = key
        self.name = name
        self.group = group
        self.celsius = celsius
    }
}

public struct FanReading: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var rpm: Double
    public var minRPM: Double?
    public var maxRPM: Double?
    public var targetRPM: Double?
    public init(index: Int, rpm: Double, minRPM: Double?, maxRPM: Double?, targetRPM: Double?) {
        self.index = index
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
    }
}

public struct SensorReadings: Codable, Sendable {
    public var temperatures: [TemperatureSensor]
    public var fans: [FanReading]
    public var cpuAvgC: Double?
    public var cpuMaxC: Double?
    public var gpuAvgC: Double?
    public var gpuMaxC: Double?
    public var socMaxC: Double?                // 整颗芯片的最高温
    public var batteryC: Double?
    public var ssdC: Double?
    public init(temperatures: [TemperatureSensor], fans: [FanReading], cpuAvgC: Double?, cpuMaxC: Double?, gpuAvgC: Double?, gpuMaxC: Double?, socMaxC: Double?, batteryC: Double?, ssdC: Double?) {
        self.temperatures = temperatures
        self.fans = fans
        self.cpuAvgC = cpuAvgC
        self.cpuMaxC = cpuMaxC
        self.gpuAvgC = gpuAvgC
        self.gpuMaxC = gpuMaxC
        self.socMaxC = socMaxC
        self.batteryC = batteryC
        self.ssdC = ssdC
    }
}

public struct PowerStatus: Codable, Sendable {
    public var systemW: Double?                // 整机功耗（SMC PSTR 等）
    public var cpuW: Double?                   // IOReport Energy Model
    public var gpuW: Double?
    public var aneW: Double?
    public var dramW: Double?
    public var packageW: Double?               // CPU + GPU + ANE + 其它 SoC 部分
    public var adapterW: Double?               // 适配器输入功率（实时）
    public var batteryPercent: Double?
    public var isCharging: Bool?
    public var onACPower: Bool
    public var lowPowerMode: Bool
    public var thermalState: String            // "正常" / "偏高" / "严重" / "危急"（ProcessInfo.thermalState）
    public var cpuEstimated: Bool              // cpuW 是“SoC 合计 − GPU”估算出来的，不是直接读数
    public init(systemW: Double?, cpuW: Double?, gpuW: Double?, aneW: Double?, dramW: Double?, packageW: Double?, adapterW: Double?, batteryPercent: Double?, isCharging: Bool?, onACPower: Bool, lowPowerMode: Bool, thermalState: String, cpuEstimated: Bool = false) {
        self.cpuEstimated = cpuEstimated
        self.systemW = systemW
        self.cpuW = cpuW
        self.gpuW = gpuW
        self.aneW = aneW
        self.dramW = dramW
        self.packageW = packageW
        self.adapterW = adapterW
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.onACPower = onACPower
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }
}

public struct DiskIO: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String                 // 物理盘 "disk0"
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double
    public var readOpsPerSec: Double
    public var writeOpsPerSec: Double
    public var totalReadBytes: Int64           // 开机以来
    public var totalWrittenBytes: Int64
    public init(bsdName: String, readBytesPerSec: Double, writeBytesPerSec: Double, readOpsPerSec: Double, writeOpsPerSec: Double, totalReadBytes: Int64, totalWrittenBytes: Int64) {
        self.bsdName = bsdName
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
        self.readOpsPerSec = readOpsPerSec
        self.writeOpsPerSec = writeOpsPerSec
        self.totalReadBytes = totalReadBytes
        self.totalWrittenBytes = totalWrittenBytes
    }
}

public struct NetIO: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String
    public var rxBytesPerSec: Double
    public var txBytesPerSec: Double
    public var totalRxBytes: Int64             // 开机以来（32 位计数器回绕要处理）
    public var totalTxBytes: Int64
    public init(bsdName: String, rxBytesPerSec: Double, txBytesPerSec: Double, totalRxBytes: Int64, totalTxBytes: Int64) {
        self.bsdName = bsdName
        self.rxBytesPerSec = rxBytesPerSec
        self.txBytesPerSec = txBytesPerSec
        self.totalRxBytes = totalRxBytes
        self.totalTxBytes = totalTxBytes
    }
}

public struct Snapshot: Codable, Sendable {
    public var timestamp: Date
    public var uptime: TimeInterval
    public var cpu: CPULoad
    public var gpu: GPULoad
    public var memory: MemoryStatus
    public var sensors: SensorReadings
    public var power: PowerStatus
    public var disks: [DiskIO]                 // 只列物理盘
    public var network: [NetIO]                // 只列有流量或处于 up 状态的接口，不含 lo0
    public init(timestamp: Date, uptime: TimeInterval, cpu: CPULoad, gpu: GPULoad, memory: MemoryStatus, sensors: SensorReadings, power: PowerStatus, disks: [DiskIO], network: [NetIO]) {
        self.timestamp = timestamp
        self.uptime = uptime
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.sensors = sensors
        self.power = power
        self.disks = disks
        self.network = network
    }
}

// MARK: - 进程（活动监视器）

public struct ProcessEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var path: String?
    public var user: String
    public var cpuPercent: Double              // 单核 = 100%，与活动监视器一致
    public var memoryBytes: Int64              // phys_footprint（活动监视器“内存”列）
    public var residentBytes: Int64
    public var threads: Int
    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double
    public var totalDiskReadBytes: Int64       // 进程启动以来
    public var totalDiskWrittenBytes: Int64
    public var energyImpact: Double?           // 近似值，读不到给 nil
    public var startTime: Date?
    public var isApp: Bool                     // 有 .app 包的前台 App
    public init(pid: Int32, ppid: Int32, name: String, path: String?, user: String, cpuPercent: Double, memoryBytes: Int64, residentBytes: Int64, threads: Int, diskReadBytesPerSec: Double, diskWriteBytesPerSec: Double, totalDiskReadBytes: Int64, totalDiskWrittenBytes: Int64, energyImpact: Double?, startTime: Date?, isApp: Bool) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.user = user
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.residentBytes = residentBytes
        self.threads = threads
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.totalDiskReadBytes = totalDiskReadBytes
        self.totalDiskWrittenBytes = totalDiskWrittenBytes
        self.energyImpact = energyImpact
        self.startTime = startTime
        self.isApp = isApp
    }
}
