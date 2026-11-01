import Foundation
import Darwin
import IOKit

extension NSLock {
    func holding<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

func sysData(_ name: String) -> Data? {
    var count = 0
    guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 0 else { return nil }
    var data = Data(count: count)
    let ok = data.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &count, nil, 0) }
    return ok == 0 ? data.prefix(count) : nil
}
func sysString(_ name: String) -> String? {
    guard let data = sysData(name) else { return nil }
    return String(data: data.prefix { $0 != 0 }, encoding: .utf8)
}
func sysInt(_ name: String) -> Int64? {
    guard let data = sysData(name) else { return nil }
    return data.withUnsafeBytes {
        if data.count == 8 { return $0.loadUnaligned(as: Int64.self) }
        if data.count == 4 { return Int64($0.loadUnaligned(as: Int32.self)) }
        return nil
    }
}
func bootDate() -> Date {
    if let data = sysData("kern.boottime"), data.count >= MemoryLayout<timeval>.size {
        let t = data.withUnsafeBytes { $0.loadUnaligned(as: timeval.self) }
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }
    return Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
}
func n(_ dict: [String: Any], _ key: String) -> Double? { (dict[key] as? NSNumber)?.doubleValue }
func i64(_ dict: [String: Any], _ key: String) -> Int64? { (dict[key] as? NSNumber)?.int64Value }
func textValue(_ value: Any) -> String {
    if let data = value as? Data {
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !s.isEmpty,
           s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) { return s }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    if let s = value as? String { return s }
    if let x = value as? NSNumber { return x.stringValue }
    return String(describing: value)
}
func cleanKey(_ key: String) -> String {
    let names = ["_name": "名称", "serial_number": "序列号", "manufacturer": "制造商", "device_speed": "速度", "battery_percent": "电池电量", "physical_memory": "内存", "boot_rom_version": "固件版本", "machine_name": "机型", "machine_model": "型号", "chip_type": "芯片"]
    if let v = names[key] { return v }
    let prefixes = ["spdisplays_", "spusb_", "spbluetooth_", "spaudio_", "spcamera_", "spnvme_", "spthunderbolt_"]
    var result = key
    for p in prefixes where result.hasPrefix(p) { result = String(result.dropFirst(p.count)) }
    return result.replacingOccurrences(of: "_", with: " ")
}
// 保留路径，避免递归 JSON 中的同名字段互相覆盖。
func flatten(_ value: Any, prefix: String = "") -> [InfoItem] {
    if let d = value as? [String: Any] {
        return d.keys.sorted().flatMap { k in flatten(d[k]!, prefix: prefix.isEmpty ? cleanKey(k) : prefix + " / " + cleanKey(k)) }
    }
    if let a = value as? [Any] { return a.enumerated().flatMap { flatten($0.element, prefix: "\(prefix) [\($0.offset + 1)]") } }
    return [InfoItem(prefix, textValue(value))]
}

struct CommandResult {
    var data: Data
    var error: String
    var status: Int32
    var output: String { String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}
// 不经 shell 执行；输出落临时文件，避免管道塞满或子孙进程持有管道造成死锁。
func command(_ path: String, _ args: [String] = [], timeout: Double = 5) -> CommandResult? {
    guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macvitals-\(UUID().uuidString)")
    let errURL = base.appendingPathExtension("err")
    let fm = FileManager.default
    guard fm.createFile(atPath: base.path, contents: nil, attributes: [.posixPermissions: 0o600]), fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
          let out = try? FileHandle(forWritingTo: base), let err = try? FileHandle(forWritingTo: errURL) else { return nil }
    defer { try? out.close(); try? err.close(); try? fm.removeItem(at: base); try? fm.removeItem(at: errURL) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"; env["LANG"] = "C"; env["HOMEBREW_NO_AUTO_UPDATE"] = "1"; env["HOMEBREW_NO_ANALYTICS"] = "1"
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env; p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return nil }
    guard done.wait(timeout: .now() + timeout) == .success else {
        kill(p.processIdentifier, SIGKILL)
        _ = done.wait(timeout: .now() + 1)
        return nil
    }
    guard let data = try? Data(contentsOf: base), data.count <= 32 * 1024 * 1024 else { return nil }
    return CommandResult(data: data, error: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "", status: p.terminationStatus)
}
func executable(_ names: [String]) -> String? { names.first { FileManager.default.isExecutableFile(atPath: $0) } }
func profiler(_ types: [String]) -> [String: Any]? {
    guard let r = command("/usr/sbin/system_profiler", types + ["-json", "-detailLevel", "full"], timeout: 20), r.status == 0 else { return nil }
    return (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any]
}
func registryProperties(_ entry: io_registry_entry_t) -> [String: Any] {
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
    return properties?.takeRetainedValue() as? [String: Any] ?? [:]
}
func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
func registryEntries(_ className: String, _ body: (io_registry_entry_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iterator) }
    while true { let e = IOIteratorNext(iterator); if e == 0 { break }; body(e); IOObjectRelease(e) }
}
func registryFirst(_ className: String) -> [String: Any] {
    var result: [String: Any] = [:]
    registryEntries(className) { if result.isEmpty { result = registryProperties($0) } }
    return result
}
func entryName(_ entry: io_registry_entry_t) -> String {
    var name = [CChar](repeating: 0, count: 128)
    guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { return "" }
    return String(cString: name)
}
func children(_ entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iterator) }
    while true { let e = IOIteratorNext(iterator); if e == 0 { break }; body(e); IOObjectRelease(e) }
}
struct PhysicalDisk {
    var name: String
    var internalDisk: Bool
    var properties: [String: Any]
    var statistics: [String: Any]
}
func physicalDisks() -> [PhysicalDisk] {
    var disks: [PhysicalDisk] = []
    registryEntries("IOBlockStorageDriver") { driver in
        var properties = registryProperties(driver)
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS {
            let p = registryProperties(parent); IOObjectRelease(parent)
            properties.merge(p) { old, _ in old }
        }
        let proto = properties["Protocol Characteristics"] as? [String: Any] ?? [:]
        let transport = proto["Physical Interconnect"] as? String ?? ""
        if transport.lowercased().contains("virtual") || transport.lowercased().contains("disk image") { return }
        children(driver) { media in
            guard IOObjectConformsTo(media, "IOMedia") != 0 else { return }
            let m = registryProperties(media)
            guard (m["Whole"] as? Bool) == true, let name = m["BSD Name"] as? String else { return }
            if entryName(driver).contains("HDIX") { return }
            properties.merge(m) { old, _ in old }
            let internalDisk = (proto["Physical Interconnect Location"] as? String) == "Internal" || (m["Removable"] as? Bool == false && transport == "Apple Fabric")
            disks.append(PhysicalDisk(name: name, internalDisk: internalDisk, properties: properties, statistics: properties["Statistics"] as? [String: Any] ?? [:]))
        }
    }
    return disks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
func percent(_ v: Double) -> Double { min(100, max(0, v)) }
func delta(_ now: Double, _ before: Double, _ dt: Double) -> Double { dt > 0 && now >= before ? (now - before) / dt : 0 }
