import SwiftUI
import VitalsCore

struct SystemView: View {
    @Environment(VitalsStore.self) private var store
    @Local private var query = ""

    var body: some View {
        Page(title: "系统与软件") {
            if let m = store.machine {
                Card(title: "这台 Mac", symbol: m.isLaptop ? "laptopcomputer" : "desktopcomputer") {
                    KVGrid(items: filter([
                        InfoItem("型号", m.modelName),
                        InfoItem("型号标识符", m.modelIdentifier),
                        InfoItem("芯片", m.chip),
                        InfoItem("CPU", "\(m.logicalCores) 核：" + m.cpuClusters.map { "\($0.coreCount) \($0.name)" }.joined(separator: " + ")),
                        InfoItem("GPU", m.gpuCores.map { "\($0) 核" } ?? "—"),
                        InfoItem("神经网络引擎", m.neuralEngineCores.map { "\($0) 核" } ?? "—"),
                        InfoItem("内存", [Fmt.mem(m.memoryBytes), m.memoryType, m.memoryManufacturer].compactMap { $0 }.joined(separator: " · ")),
                        InfoItem("序列号", m.serialNumber ?? "—"),
                        InfoItem("系统固件", m.firmwareVersion ?? "—"),
                        InfoItem("系统加载器", m.osLoaderVersion ?? "—"),
                    ]))
                }
            } else {
                Placeholder(text: "正在读取硬件信息…")
            }

            if let sw = store.software {
                Card(title: "macOS", symbol: "apple.logo") {
                    KVGrid(items: filter([
                        InfoItem("系统", "\(sw.osName) \(sw.osVersion)（\(sw.osBuild)）"),
                        InfoItem("内核", sw.kernelVersion),
                        InfoItem("电脑名称", sw.computerName),
                        InfoItem("主机名", sw.hostname),
                        InfoItem("用户", sw.userName),
                        InfoItem("启动时间", Fmt.date(sw.bootTime)),
                        InfoItem("已开机", store.snapshot.map { Fmt.duration($0.uptime) } ?? "—"),
                    ]))
                }
                Card(title: "安全", symbol: "lock.shield") {
                    HStack(spacing: 12) {
                        badge("系统完整性保护", sw.sipEnabled)
                        badge("文件保险箱", sw.fileVaultOn)
                        badge("Gatekeeper", sw.gatekeeperOn)
                        badge("防火墙", sw.firewallOn)
                    }
                }
                SectionsView(sections: sw.sections, filter: query)
            } else {
                Placeholder(text: "正在读取软件信息（Homebrew 等可能要几秒）…")
            }

            if let m = store.machine {
                Text("硬件详细参数").font(.title2.weight(.semibold)).padding(.top, 8)
                SectionsView(sections: m.sections, filter: query)
            }
        }
        .searchable(text: $query, prompt: "搜索参数")
    }

    private func filter(_ items: [InfoItem]) -> [InfoItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.key.localizedCaseInsensitiveContains(q) || $0.value.localizedCaseInsensitiveContains(q) }
    }

    private func badge(_ title: String, _ on: Bool?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: on == true ? "checkmark.shield.fill" : (on == false ? "exclamationmark.shield" : "questionmark.circle"))
                .foregroundStyle(on == true ? .green : (on == false ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout)
                Text(Fmt.bool(on)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
