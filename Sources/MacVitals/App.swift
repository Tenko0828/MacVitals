import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VitalsCore

@main
enum Entry {
    static func main() {
        // ./build.sh 用它渲染 App 图标
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { AppIcon.render(to: CommandLine.arguments[i + 1]) }
            return
        }
        MacVitalsApp.main()
    }
}

struct MacVitalsApp: App {
    @Local private var store = VitalsStore()

    var body: some Scene {
        Window("硬件体检", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { store.start() }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("导出完整报告…") { exportReport(store) }.keyboardShortcut("e")
            }
        }

        MenuBarExtra {
            MenuBarPanel().environment(store).onAppear { store.start() }
        } label: {
            MenuBarLabel(store: store).onAppear { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
func exportReport(_ store: VitalsStore) {
    guard let data = store.reportJSON() else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    let stamp = Date().formatted(.iso8601.year().month().day())
    panel.nameFieldStringValue = "硬件报告-\(stamp).json"
    if panel.runModal() == .OK, let url = panel.url {
        try? data.write(to: url)
    }
}

// MARK: - 侧边栏

enum Pane: String, CaseIterable, Identifiable {
    case overview, cpu, gpu, memory, storage, sensors, battery, network, processes, peripherals, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .storage: "存储与寿命"
        case .sensors: "温度 · 风扇 · 功耗"
        case .battery: "电池与电源"
        case .network: "网络"
        case .processes: "活动监视"
        case .peripherals: "外设"
        case .system: "系统与软件"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .sensors: "thermometer.medium"
        case .battery: "battery.75percent"
        case .network: "network"
        case .processes: "list.bullet.rectangle"
        case .peripherals: "cable.connector"
        case .system: "info.circle"
        }
    }
}

struct ContentView: View {
    @Environment(VitalsStore.self) private var store
    /// 记住上次打开的页面；启动参数 -page cpu 也能直接指定
    @Local private var selection: Pane? = UserDefaults.standard.string(forKey: "page").flatMap(Pane.init(rawValue:)) ?? .overview

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { s in
                NavigationLink(value: s) {
                    HStack {
                        Label(s.title, systemImage: s.symbol)
                        Spacer()
                        if let badge = badge(for: s) {
                            Text(badge).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .onChange(of: selection) { _, p in UserDefaults.standard.set(p?.rawValue, forKey: "page") }
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView()
                case .cpu: CPUView()
                case .gpu: GPUView()
                case .memory: MemoryView()
                case .storage: StorageView()
                case .sensors: SensorsView()
                case .battery: BatteryView()
                case .network: NetworkView()
                case .processes: ProcessesView()
                case .peripherals: PeripheralsView()
                case .system: SystemView()
                }
            }
            .toolbar {
                ToolbarItem {
                    Picker("曲线范围", selection: Bindable(store).window) {
                        Text("1 分钟").tag(60)
                        Text("2 分钟").tag(120)
                        Text("5 分钟").tag(300)
                        Text("10 分钟").tag(600)
                    }
                    .pickerStyle(.menu)
                    .help("图表显示最近多长时间")
                }
                ToolbarItem {
                    Button { store.refreshSlow() } label: { Label("重新读取", systemImage: "arrow.clockwise") }
                        .help("重新读取硬盘健康、外设、网络接口")
                }
                ToolbarItem {
                    Button { exportReport(store) } label: { Label("导出报告", systemImage: "square.and.arrow.up") }
                        .help("把全部数据导出为 JSON")
                }
            }
        }
    }

    private func badge(for s: Pane) -> String? {
        guard let snap = store.snapshot else { return nil }
        switch s {
        case .cpu: return Fmt.pct(snap.cpu.total)
        case .gpu: return Fmt.pct(snap.gpu.utilization)
        case .memory: return Fmt.pct(store.memoryPercent)
        case .sensors: return snap.sensors.socMaxC.map { String(format: "%.0f°", $0) }
        case .battery: return store.battery.map { Fmt.pct($0.chargePercent) }
        case .storage: return store.internalDrive?.percentageUsed.map { "寿命 \(Fmt.pct(100 - $0))" }
        case .processes: return store.processes.isEmpty ? nil : "\(store.processes.count)"
        default: return nil
        }
    }
}

// MARK: - 菜单栏

struct MenuBarLabel: View {
    let store: VitalsStore
    var body: some View {
        let snap = store.snapshot
        let cpu = snap.map { String(format: "%.0f%%", $0.cpu.total) } ?? "—"
        let temp = snap?.sensors.socMaxC.map { String(format: "%.0f°", $0) }
        Text(temp.map { "\(cpu) \($0)" } ?? cpu).monospacedDigit()
    }
}

struct MenuBarPanel: View {
    @Environment(VitalsStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snap = store.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(store.machine?.chip ?? "硬件体检").font(.headline)
                Spacer()
                if let t = snap?.power.thermalState { Pill(text: t, tint: t == "正常" ? .green : .orange) }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                panelRow("CPU", Fmt.pct(snap?.cpu.total), (snap?.cpu.total ?? 0) / 100, Tint.cpu, .cpu)
                panelRow("GPU", Fmt.pct(snap?.gpu.utilization), (snap?.gpu.utilization ?? 0) / 100, Tint.gpu, .gpu)
                panelRow("内存", Fmt.pct(store.memoryPercent), (store.memoryPercent ?? 0) / 100, Tint.memory, .memory)
                panelRow("芯片温度", Fmt.temp(snap?.sensors.socMaxC), (snap?.sensors.socMaxC ?? 0) / 110, Tint.temp(snap?.sensors.socMaxC), .socTemp)
                panelRow("整机功耗", Fmt.watts(snap?.power.systemW ?? snap?.power.packageW), 0, Tint.power, snap?.power.systemW != nil ? .systemW : .packageW, bar: false)
            }
            Divider()
            HStack {
                Label(Fmt.rate(snap?.network.reduce(0) { $0 + $1.rxBytesPerSec }), systemImage: "arrow.down")
                Label(Fmt.rate(snap?.network.reduce(0) { $0 + $1.txBytesPerSec }), systemImage: "arrow.up")
                Spacer()
                if let b = store.battery { Label(Fmt.pct(b.chargePercent), systemImage: b.isCharging ? "battery.100percent.bolt" : "battery.75percent") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack {
                Button("打开主窗口") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func panelRow(_ label: String, _ value: String, _ fraction: Double, _ tint: Color, _ metric: Metric, bar: Bool = true) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Sparkline(samples: store.history.samples(metric, last: 60), tint: tint, yMax: bar ? (metric == .socTemp ? 110 : 100) : nil)
                .frame(width: 110, height: 22)
            Text(value).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .font(.callout)
    }
}
