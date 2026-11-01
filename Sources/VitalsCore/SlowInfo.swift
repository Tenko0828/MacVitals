import Foundation
import Darwin
import IOKit
import CVitalsSupport

extension VitalsMonitor {
    public func machine() -> MachineInfo {
        machineLock.holding {
            if let cache = machineCache { return cache }
            let profile = profiler(["SPHardwareDataType","SPMemoryDataType"]) ?? [:]
            let hw = (profile["SPHardwareDataType"] as? [[String: Any]])?.first ?? [:]
            let memory = (profile["SPMemoryDataType"] as? [[String: Any]])?.first ?? [:]
            let platform = registryFirst("IOPlatformExpertDevice")
            let gpu = registryFirst("IOAccelerator")
            var sections: [InfoSection] = []
            let sysNames = ["hw.model","hw.machine","hw.memsize","hw.pagesize","hw.cachelinesize","hw.l1icachesize","hw.l1dcachesize","hw.l2cachesize","hw.l3cachesize","hw.physicalcpu","hw.logicalcpu","hw.tbfrequency","hw.cpufrequency","hw.cpufrequency_max","hw.optional.arm64"]
            var items = sysNames.compactMap { key -> InfoItem? in
                if ["hw.model","hw.machine"].contains(key) { return sysString(key).map { InfoItem(key,$0) } }
                return sysInt(key).map { InfoItem(key,String($0)) }
            }
            for level in 0..<8 {
                for suffix in ["name","physicalcpu","logicalcpu","l1icachesize","l1dcachesize","l2cachesize","cpusperl2"] {
                    let key = "hw.perflevel\(level).\(suffix)"
                    if suffix == "name" { if let s = sysString(key) { items.append(InfoItem(key,s)) } }
                    else if let v = sysInt(key) { items.append(InfoItem(key,String(v))) }
                }
            }
            sections.append(InfoSection(title: "处理器与缓存",items: items))
            let features = VCCopyARMFeatures() as? [[String: Any]] ?? []
            sections.append(InfoSection(title: "ARM 指令集特性",items: features.compactMap { d in guard let name = d["name"] as? String, let value = d["value"] else { return nil }; return InfoItem(name,textValue(value)) }))
            sections.append(InfoSection(title: "硬件概览",items: flatten(hw)))
            sections.append(InfoSection(title: "内存详情",items: flatten(profile["SPMemoryDataType"] ?? [])))
            sections.append(InfoSection(title: "频率表 MHz",items: [InfoItem("能效核",tables.efficiency.map { String(format:"%.0f",$0) }.joined(separator:", ")),InfoItem("性能核",tables.performance.map { String(format:"%.0f",$0) }.joined(separator:", ")),InfoItem("超级核心",tables.superCore.map { String(format:"%.0f",$0) }.joined(separator:", ")),InfoItem("GPU",tables.gpu.map { String(format:"%.0f",$0) }.joined(separator:", "))].filter { !$0.value.isEmpty }))
            var diagnostics = flatten(hardware.current().diagnostics)
            diagnostics.append(InfoItem("vm.swapusage",sysData("vm.swapusage") == nil ? "权限不足；契约的非可选交换区字段暂填 0" : "可读"))
            diagnostics.append(InfoItem("内存压力",sysInt("kern.memorystatus_vm_pressure_level") == nil ? "权限不足" : "可读"))
            sections.append(InfoSection(title: "采集诊断",items: diagnostics))
            let model = sysString("hw.model") ?? hw["machine_model"] as? String ?? platform["model"].map(textValue) ?? "未知"
            let laptop = !registryFirst("AppleSmartBattery").isEmpty || (hw["machine_name"] as? String ?? "").contains("Book")
            // 字段可出现在内存概览或嵌套的插槽字典内。
            func find(_ value: Any, _ keys: [String]) -> String? {
                if let d = value as? [String: Any] {
                    for key in keys { if let v = d[key], !(v is [Any]), !(v is [String: Any]) { return textValue(v) } }
                    for key in d.keys.sorted() { if let s = find(d[key]!,keys) { return s } }
                } else if let a = value as? [Any] { for v in a { if let s = find(v,keys) { return s } } }
                return nil
            }
            let result = MachineInfo(modelName: hw["machine_name"] as? String ?? (laptop ? "MacBook" : "Mac"), modelIdentifier: model, chip: sysString("machdep.cpu.brand_string") ?? hw["chip_type"] as? String ?? gpu["model"] as? String ?? "Apple Silicon", serialNumber: platform["IOPlatformSerialNumber"] as? String ?? hw["serial_number"] as? String, cpuClusters: clusters, logicalCores: Int(sysInt("hw.logicalcpu") ?? Int64(ProcessInfo.processInfo.processorCount)), gpuCores: i64(gpu,"gpu-core-count").map(Int.init), neuralEngineCores: nil, memoryBytes: totalMemory, memoryType: find(memory,["dimm_type","memory_type"]), memoryManufacturer: find(memory,["dimm_manufacturer","manufacturer"]), firmwareVersion: hw["boot_rom_version"] as? String, osLoaderVersion: hw["os_loader_version"] as? String, isLaptop: laptop, sections: sections.filter { !$0.items.isEmpty })
            machineCache = result; return result
        }
    }
    public func software() -> SoftwareInfo {
        softwareLock.holding {
            if let (date,cache) = softwareCache, Date().timeIntervalSince(date) < 60 { return cache }
            let extras = SoftwareExtras.collect()
            let sip = extras.output("sip")
            let fv = extras.output("filevault")
            let gate = extras.output("gatekeeper")
            let firewall = extras.output("firewall")
            func enabled(_ value: String?,yes: String,no: String) -> Bool? {
                guard let s = value?.lowercased() else { return nil }
                if s.contains(no) { return false }; if s.contains(yes) { return true }; return nil
            }
            let now = ProcessInfo.processInfo
            let os = now.operatingSystemVersion
            let result = SoftwareInfo(osName:extras.osName,osVersion:extras.osVersion ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",osBuild:extras.osBuild ?? sysString("kern.osversion") ?? "",kernelVersion:sysString("kern.version") ?? "",hostname:now.hostName,computerName:SCDynamicComputerName(),userName:NSUserName(),bootTime:bootDate(),sipEnabled:enabled(sip,yes:"enabled",no:"disabled"),fileVaultOn:enabled(fv,yes:"on",no:"off"),gatekeeperOn:enabled(gate,yes:"enabled",no:"disabled"),firewallOn:enabled(firewall,yes:"enabled",no:"disabled"),sections:extras.sections())
            softwareCache = (Date(),result); return result
        }
    }
    public func volumes() -> [VolumeInfo] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts,MNT_NOWAIT)
        guard let mounts,count > 0 else { return [] }
        defer { free(mounts) }
        return (0..<Int(count)).compactMap { index in
            let m = mounts[index]
            func str<T>(_ value: T) -> String { var v = value; return withUnsafePointer(to:&v) { $0.withMemoryRebound(to:CChar.self,capacity:MemoryLayout<T>.size) { String(cString:$0) } } }
            let fs = str(m.f_fstypename),path = str(m.f_mntonname),device = str(m.f_mntfromname)
            if ["devfs","autofs","map","fdesc","volfs"].contains(fs) { return nil }
            let url = URL(fileURLWithPath:path)
            let r = try? url.resourceValues(forKeys:[.volumeNameKey,.volumeIsInternalKey,.volumeIsRemovableKey,.volumeIsReadOnlyKey,.volumeAvailableCapacityForImportantUsageKey])
            return VolumeInfo(name:r?.volumeName ?? url.lastPathComponent,mountPoint:path,fileSystem:fs,bsdName:device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : nil,totalBytes:Int64(clamping:m.f_blocks)*Int64(m.f_bsize),freeBytes:Int64(clamping:m.f_bfree)*Int64(m.f_bsize),availableBytes:r?.volumeAvailableCapacityForImportantUsage,isInternal:r?.volumeIsInternal ?? false,isRemovable:r?.volumeIsRemovable ?? false,isReadOnly:r?.volumeIsReadOnly ?? (m.f_flags & UInt32(MNT_RDONLY) != 0))
        }
    }
    public func driveHealth() -> [DriveHealth] {
        let disks = physicalDisks()
        let smartctl = executable(["/opt/homebrew/bin/smartctl","/usr/local/bin/smartctl","/usr/sbin/smartctl"])
        struct Target { var name: String; var type: String?; var disk: PhysicalDisk? }
        var targets = Dictionary(uniqueKeysWithValues:disks.map { ($0.name,Target(name:$0.name,type:nil,disk:$0)) })
        if let smartctl,let scan = command(smartctl,["--scan-open","-j"]),let json = (try? JSONSerialization.jsonObject(with:scan.data)) as? [String:Any],let devices = json["devices"] as? [[String:Any]] {
            for d in devices {
                guard let path = d["name"] as? String, path.range(of: "^(/dev/)?disk[0-9]+$", options: .regularExpression) != nil else { continue }
                let name = path.replacingOccurrences(of:"/dev/",with:"")
                if targets[name] == nil { targets[name] = Target(name:name,type:d["type"] as? String,disk:nil) }
                else { targets[name]?.type = d["type"] as? String }
            }
        }
        return targets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            let target = targets[key]!
            let p = target.disk?.properties ?? [:]
            let characteristics = p["Device Characteristics"] as? [String:Any] ?? [:]
            var result = DriveHealth(bsdName:key,model:characteristics["Product Name"] as? String,serial:characteristics["Serial Number"] as? String,capacityBytes:i64(p,"Size"),isInternal:target.disk?.internalDisk ?? false,source:"unavailable")
            guard let smartctl else { result.note = "未安装 smartmontools，brew install smartmontools 后可读寿命"; return result }
            var args = ["-a","-j"]
            if let type = target.type { args += ["-d",type] }; args.append(key)
            guard let r = command(smartctl,args),let j = (try? JSONSerialization.jsonObject(with:r.data)) as? [String:Any] else { result.note = "smartctl 执行失败或超时"; return result }
            return decodeDriveHealth(j, base: result)
        }
    }
    public func peripherals() -> [DeviceGroup] {
        peripheralLock.holding {
            if let (date,cache) = peripheralCache,Date().timeIntervalSince(date) < 60 { return cache }
            let kinds = [("SPDisplaysDataType","显示器","display"),("SPUSBDataType","USB","cable.connector"),("SPThunderboltDataType","雷雳","bolt.horizontal"),("SPBluetoothDataType","蓝牙","dot.radiowaves.left.and.right"),("SPAudioDataType","音频","speaker.wave.2"),("SPCameraDataType","摄像头","camera"),("SPNVMeDataType","NVMe","internaldrive")]
            guard let profile = profiler(kinds.map { $0.0 }) else { return peripheralCache?.1 ?? [] }
            func devices(_ values: [[String:Any]],fallback: String) -> [InfoSection] {
                values.flatMap { d -> [InfoSection] in
                    let name = d["_name"] as? String ?? fallback
                    var own = d.filter { $0.key != "_items" }
                    var nested = devices(d["_items"] as? [[String:Any]] ?? [],fallback:name)
                    for key in d.keys.sorted() where key != "_items" {
                        guard let array = d[key] as? [[String:Any]] else { continue }
                        if array.contains(where:{ $0["_name"] != nil }) {
                            nested += devices(array,fallback:name)
                            own.removeValue(forKey:key)
                        } else if key.contains("device_connected") || key.contains("device_not_connected") {
                            for entry in array {
                                for deviceName in entry.keys.sorted() {
                                    if var detail = entry[deviceName] as? [String:Any] {
                                        detail["_name"] = deviceName
                                        detail["连接状态"] = key.contains("not_connected") ? "未连接" : "已连接"
                                        nested += devices([detail],fallback:deviceName)
                                    }
                                }
                            }
                            own.removeValue(forKey:key)
                        }
                    }
                    let section = InfoSection(title:name,items:flatten(own))
                    return (section.items.isEmpty ? [] : [section]) + nested
                }
            }
            let result = kinds.compactMap { key,title,symbol -> DeviceGroup? in
                var seen: [String:Int] = [:]
                let sections = devices(profile[key] as? [[String:Any]] ?? [],fallback:title).map { section -> InfoSection in
                    var section = section; let count = seen[section.title,default:0] + 1; seen[section.title] = count
                    if count > 1 { section.title += "（\(count)）" }
                    return section
                }
                return sections.isEmpty ? nil : DeviceGroup(title:title,symbol:symbol,devices:sections)
            }
            peripheralCache = (Date(),result); return result
        }
    }
}
