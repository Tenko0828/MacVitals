import Foundation
import VitalsCore

func measured<T>(_ name: String, _ body: () -> T) -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = body()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    FileHandle.standardError.write(Data(String(format:"%@: %.3f ms\n",name,ms).utf8))
    return result
}
struct Dump: Encodable {
    let machine: MachineInfo
    let software: SoftwareInfo
    let volumes: [VolumeInfo]
    let driveHealth: [DriveHealth]
    let battery: BatteryInfo?
    let networkInterfaces: [NetworkInterface]
    let peripherals: [DeviceGroup]
    let snapshot: Snapshot
    let processes: [ProcessEntry]
}
let monitor = measured("init") { VitalsMonitor() }
let machine = measured("machine") { monitor.machine() }
let software = measured("software") { monitor.software() }
let volumes = measured("volumes") { monitor.volumes() }
let drives = measured("driveHealth") { monitor.driveHealth() }
let battery = measured("battery") { monitor.battery() }
let interfaces = measured("networkInterfaces") { monitor.networkInterfaces() }
let peripherals = measured("peripherals") { monitor.peripherals() }
_ = measured("snapshot[1]") { monitor.snapshot() }
_ = measured("processes[1]") { monitor.processes() }
Thread.sleep(forTimeInterval:1)
let snapshot = measured("snapshot[2]") { monitor.snapshot() }
let processes = measured("processes[2]") { Array(monitor.processes().sorted { $0.cpuPercent > $1.cpuPercent }.prefix(15)) }
let dump = Dump(machine:machine,software:software,volumes:volumes,driveHealth:drives,battery:battery,networkInterfaces:interfaces,peripherals:peripherals,snapshot:snapshot,processes:processes)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
 do {
    let data = try encoder.encode(dump)
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("JSON 编码失败：\(error)\n".utf8)); exit(1)
}
