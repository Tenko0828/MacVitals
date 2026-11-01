import Foundation

// 使用系统编译器即可运行，兼容只有 CLT 的机器。
func expect(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    if !value() { fatalError("检查失败", file:file, line:line) }
}

struct BackendTests {
    func nvmeSMARTUnitsAndWear() {
        let json: [String: Any] = [
            "model_name": "APPLE SSD", "smart_status": ["passed": true],
            "temperature": ["current": 43],
            "nvme_smart_health_information_log": ["percentage_used": 2, "available_spare": 100, "critical_warning": 0, "data_units_read": 12345, "data_units_written": 67890, "power_on_hours": 500]]
        let result = decodeDriveHealth(json,base:DriveHealth(bsdName:"disk0",isInternal:true,source:"unavailable"))
        expect(result.source == "smartctl")
        expect(result.percentageUsed == 2)
        expect(result.dataReadBytes == 6_320_640_000)
        expect(result.dataWrittenBytes == 34_759_680_000)
        expect(result.temperatureC == 43)
        expect(result.smartPassed == true)
    }
    func smartFailureRemainsUnavailable() {
        let result = decodeDriveHealth(["smartctl": ["messages": [["string":"Permission denied"]]]],base:DriveHealth(bsdName:"disk0",isInternal:true,source:"unavailable"))
        expect(result.source == "unavailable")
        expect(result.percentageUsed == nil)
        expect(result.note == "Permission denied")
        let huge = decodeDriveHealth(["nvme_smart_health_information_log": ["data_units_read": Int64.max]],base:DriveHealth(bsdName:"disk0",isInternal:true,source:"unavailable"))
        expect(huge.dataReadBytes == nil)
    }
    func temperaturesClassifyFilterAndDeduplicate() {
        let raw: [String: Any] = ["hid": ["PMU tdie0": 60, "PMU tdev0": 55, "gas gauge battery": 32, "NAND CH0 temp": 40, "PMU Tp01": 61], "smc": ["Tp01": 61, "Tp02": 65, "Tg01": 151, "TB0T": 0, "FNum": 1, "F0Ac": 2200]]
        let result = sensorReadings(raw)
        expect(result.temperatures.count == 6)
        expect(result.cpuMaxC == 65)
        expect(result.gpuMaxC == 55)
        expect(result.batteryC == 32)
        expect(result.ssdC == 40)
        expect(result.fans.first?.rpm == 2200)
        expect(Set(result.temperatures.map(\.key)).count == result.temperatures.count)
    }
    func frequencyTableHzAndKHz() {
        func table(_ values: [UInt32]) -> Data {
            var d = Data()
            for v in values { var pair = (v.littleEndian,UInt32(800).littleEndian); withUnsafeBytes(of:&pair) { d.append(contentsOf:$0) } }
            return d
        }
        expect(decodeFrequencyTable(table([0,600_000_000,3_228_000_000])) == [600,3228])
        expect(decodeFrequencyTable(table([1_344_000,4_380_000])) == [1344,4380])
        expect(decodeFrequencyTable(table([50103,40454])).isEmpty)
        expect(decodeFrequencyTable(Data([1,2,3])).isEmpty)
    }
    func batteryTemperatureFormats() {
        expect(batteryTemperature(3050) == 30.5)
        expect(abs((batteryTemperature(3031,unit:"0.1K") ?? 0) - 29.95) < 0.001)
        expect(batteryTemperature(0) == nil)
        expect(batteryTemperature(65535) == nil)
    }
    func countersResetAndFirstSample() {
        expect(delta(120,100,2) == 10)
        expect(delta(5,100,2) == 0)
        expect(delta(120,100,0) == 0)
        expect(delta(120,120,1) == 0)
    }
    func subprocessTimeout() {
        let start = ProcessInfo.processInfo.systemUptime
        expect(command("/bin/sleep",["2"],timeout:0.05) == nil)
        expect(ProcessInfo.processInfo.systemUptime-start < 1.5)
    }
    func processCPUTimebase() {
        let monitor = VitalsMonitor()
        _ = monitor.processes()
        let until = ProcessInfo.processInfo.systemUptime + 0.2
        var spins: UInt64 = 0
        while ProcessInfo.processInfo.systemUptime < until { spins &+= 1 }
        let entry = monitor.processes().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        expect(spins > 0)
        // 单线程忙循环应接近一核，错误的 timebase 会造成几十倍偏差。
        expect((entry?.cpuPercent ?? 0) > 5 && (entry?.cpuPercent ?? 0) < 300)
    }
    func concurrentNativeSampling() throws {
        let monitor = VitalsMonitor()
        let first = monitor.snapshot()
        expect(first.cpu.perCore.allSatisfy { $0.usage == 0 })
        expect(first.disks.allSatisfy { $0.readBytesPerSec == 0 && $0.writeBytesPerSec == 0 })
        expect(first.network.allSatisfy { $0.rxBytesPerSec == 0 && $0.txBytesPerSec == 0 })
        expect(monitor.processes().allSatisfy { $0.cpuPercent == 0 && $0.diskReadBytesPerSec == 0 })
        DispatchQueue.concurrentPerform(iterations:12) { index in
            if index % 3 == 0 {
                let s = monitor.snapshot()
                expect(s.cpu.total >= 0 && s.cpu.total <= 100)
                expect(s.cpu.perCore.allSatisfy { $0.usage >= 0 && $0.usage <= 100 })
                expect((try? JSONEncoder().encode(s)) != nil)
            } else if index % 3 == 1 {
                let p = monitor.processes()
                expect(Set(p.map(\.pid)).count == p.count)
                expect(p.allSatisfy { $0.cpuPercent.isFinite && $0.cpuPercent >= 0 })
            } else { _ = monitor.battery() }
        }
        expect(first.memory.usedBytes <= first.memory.totalBytes)
    }
}

@main
struct BackendCheckRunner {
    static func main() throws {
        let suite = BackendTests()
        suite.nvmeSMARTUnitsAndWear()
        suite.smartFailureRemainsUnavailable()
        suite.temperaturesClassifyFilterAndDeduplicate()
        suite.frequencyTableHzAndKHz()
        suite.batteryTemperatureFormats()
        suite.countersResetAndFirstSample()
        suite.subprocessTimeout()
        suite.processCPUTimebase()
        try suite.concurrentNativeSampling()
        print("9 组后端检查通过：SMART、温度、频率、电池单位、计数差值、超时、进程 CPU timebase、并发原生采样")
    }
}
