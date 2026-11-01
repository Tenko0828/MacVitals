import Foundation

// smartctl 的非零退出码也可能带有有效健康数据，以 JSON 内容为准。
func decodeDriveHealth(_ j: [String: Any], base: DriveHealth) -> DriveHealth {
    var result = base
    let nv = j["nvme_smart_health_information_log"] as? [String:Any] ?? [:]
    let status = j["smart_status"] as? [String:Any] ?? [:]
    let temperature = j["temperature"] as? [String:Any] ?? [:]
    let powerOn = j["power_on_time"] as? [String:Any] ?? [:]
    let capacity = j["user_capacity"] as? [String:Any] ?? [:]
    result.model = j["model_name"] as? String ?? j["model_family"] as? String ?? result.model
    result.serial = j["serial_number"] as? String ?? result.serial
    result.firmware = j["firmware_version"] as? String
    result.capacityBytes = i64(capacity,"bytes") ?? i64(j,"nvme_total_capacity") ?? result.capacityBytes
    result.smartPassed = status["passed"] as? Bool
    result.criticalWarning = i64(nv,"critical_warning").map(Int.init)
    result.temperatureC = n(temperature,"current") ?? n(nv,"temperature")
    result.percentageUsed = n(nv,"percentage_used").map(percent)
    result.availableSpare = n(nv,"available_spare").map(percent)
    result.availableSpareThreshold = n(nv,"available_spare_threshold").map(percent)
    // NVMe data unit 固定为 1000 个 512 字节块。
    result.dataReadBytes = i64(nv,"data_units_read").flatMap { $0 >= 0 && $0 <= Int64.max / 512000 ? $0 * 512000 : nil }
    result.dataWrittenBytes = i64(nv,"data_units_written").flatMap { $0 >= 0 && $0 <= Int64.max / 512000 ? $0 * 512000 : nil }
    result.powerOnHours = (i64(nv,"power_on_hours") ?? i64(powerOn,"hours")).map(Int.init)
    result.powerCycles = (i64(nv,"power_cycles") ?? i64(j,"power_cycle_count")).map(Int.init)
    result.unsafeShutdowns = i64(nv,"unsafe_shutdowns").map(Int.init)
    result.mediaErrors = i64(nv,"media_errors").map(Int.init)
    result.errorLogEntries = i64(nv,"num_err_log_entries").map(Int.init)
    let attrs = (j["ata_smart_attributes"] as? [String:Any])?["table"] as? [[String:Any]] ?? []
    for attr in attrs {
        let name = (attr["name"] as? String ?? "").lowercased()
        if ["percent_lifetime_remain","ssd_life_left","media_wearout_indicator"].contains(name),let remaining = n(attr,"value"),result.percentageUsed == nil { result.percentageUsed = percent(100-remaining) }
        // ATA 的 241/242 单位因厂商而异，不能一概按 512 字节换算。
    }
    if !nv.isEmpty || result.smartPassed != nil || !attrs.isEmpty { result.source = "smartctl" }
    let messages = (j["smartctl"] as? [String:Any])?["messages"] as? [[String:Any]] ?? []
    // 苹果 SSD 不支持读错误日志页，smartctl 每次都会报 GetLogPage failed，属正常现象，不提示
    let errors = messages.compactMap { $0["string"] as? String }.filter { !$0.contains("GetLogPage failed") }
    if !errors.isEmpty { result.note = errors.joined(separator:"；") }
    else if result.source == "unavailable" { result.note = "该设备未提供可读取的 SMART 健康信息" }
    return result
}
