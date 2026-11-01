import SwiftUI
import AppKit
import VitalsCore

/// 表格排序要求非可选字段，这里把可选值摊平
private extension ProcessEntry {
    var energySort: Double { energyImpact ?? -1 }
    var startSort: Date { startTime ?? .distantPast }
}

struct ProcessesView: View {
    @Environment(VitalsStore.self) private var store
    @Local private var query = ""
    @Local private var scope: Scope = .all
    @Local private var sortOrder = [KeyPathComparator(\ProcessEntry.cpuPercent, order: .reverse)]
    @Local private var selection: Set<Int32> = []
    @Local private var toKill: ProcessEntry?
    @Local private var paused = false
    @Local private var frozen: [ProcessEntry] = []

    enum Scope: String, CaseIterable {
        case all = "全部进程", apps = "App", mine = "我的进程", system = "系统进程"
    }

    var body: some View {
        let rows = filtered
        VStack(spacing: 0) {
            ProcessSummary(processes: source)
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                mainColumns
                diskColumns
            }
            .contextMenu(forSelectionType: Int32.self) { ids in
                if let id = ids.first, let p = rows.first(where: { $0.pid == id }) {
                    Button("复制 PID") { copy("\(p.pid)") }
                    Button("复制路径") { copy(p.path ?? p.name) }.disabled(p.path == nil)
                    Button("在访达中显示") { reveal(p) }.disabled(p.path == nil)
                    Divider()
                    Button("结束进程…", role: .destructive) { toKill = p }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索名称、PID、用户、路径")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Toggle(isOn: $paused) { Label(paused ? "继续刷新" : "暂停刷新", systemImage: paused ? "play.fill" : "pause.fill") }
                    .help("暂停后表格不再跳动，方便查看")
                    .onChange(of: paused) { _, p in if p { frozen = store.processes } }
            }
        }
        .confirmationDialog("结束“\(toKill?.name ?? "")”（PID \(toKill?.pid ?? 0)）？", isPresented: Binding(get: { toKill != nil }, set: { if !$0 { toKill = nil } })) {
            Button("结束", role: .destructive) { if let p = toKill { kill(p.pid, SIGTERM) }; toKill = nil }
            Button("强制结束", role: .destructive) { if let p = toKill { kill(p.pid, SIGKILL) }; toKill = nil }
            Button("取消", role: .cancel) { toKill = nil }
        } message: {
            Text("未保存的内容可能会丢失。")
        }
        .navigationTitle("活动监视")
    }

    // 列太多时 SwiftUI 来不及推断类型，拆成两组
    @TableColumnBuilder<ProcessEntry, KeyPathComparator<ProcessEntry>>
    private var mainColumns: some TableColumnContent<ProcessEntry, KeyPathComparator<ProcessEntry>> {
        TableColumn("名称", value: \.name) { p in
            HStack(spacing: 6) {
                AppIconView(path: p.path, isApp: p.isApp)
                Text(p.name).lineLimit(1)
            }
        }
        .width(min: 160, ideal: 220)
        TableColumn("CPU %", value: \.cpuPercent) { p in
            Text(Fmt.num(p.cpuPercent)).monospacedDigit().foregroundStyle(p.cpuPercent > 50 ? .orange : .primary)
        }
        .width(64)
        TableColumn("内存", value: \.memoryBytes) { p in Text(Fmt.mem(p.memoryBytes)).monospacedDigit() }
            .width(80)
        TableColumn("线程", value: \.threads) { p in Text("\(p.threads)").monospacedDigit() }
            .width(48)
        TableColumn("能耗", value: \.energySort) { p in Text(p.energyImpact.map { Fmt.num($0) } ?? "").monospacedDigit() }
            .width(52)
        TableColumn("PID", value: \.pid) { p in Text("\(p.pid)").monospacedDigit().foregroundStyle(.secondary) }
            .width(56)
    }

    @TableColumnBuilder<ProcessEntry, KeyPathComparator<ProcessEntry>>
    private var diskColumns: some TableColumnContent<ProcessEntry, KeyPathComparator<ProcessEntry>> {
        TableColumn("读/秒", value: \.diskReadBytesPerSec) { p in Text(p.diskReadBytesPerSec > 0 ? Fmt.rate(p.diskReadBytesPerSec) : "").monospacedDigit() }
            .width(80)
        TableColumn("写/秒", value: \.diskWriteBytesPerSec) { p in Text(p.diskWriteBytesPerSec > 0 ? Fmt.rate(p.diskWriteBytesPerSec) : "").monospacedDigit() }
            .width(80)
        TableColumn("累计写入", value: \.totalDiskWrittenBytes) { p in Text(p.totalDiskWrittenBytes > 0 ? Fmt.bytes(p.totalDiskWrittenBytes) : "").monospacedDigit() }
            .width(80)
        TableColumn("用户", value: \.user) { p in Text(p.user).foregroundStyle(.secondary) }
            .width(min: 60, ideal: 80)
        TableColumn("启动于", value: \.startSort) { p in Text(p.startTime.map { $0.formatted(date: .omitted, time: .shortened) } ?? "").foregroundStyle(.secondary) }
            .width(64)
    }

    private var source: [ProcessEntry] { paused ? frozen : store.processes }

    private var filtered: [ProcessEntry] {
        let me = NSUserName()
        var list = source
        switch scope {
        case .all: break
        case .apps: list = list.filter(\.isApp)
        case .mine: list = list.filter { $0.user == me }
        case .system: list = list.filter { $0.user != me }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q) || "\($0.pid)" == q
                    || $0.user.localizedCaseInsensitiveContains(q) || ($0.path?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        return list.sorted(using: sortOrder)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func reveal(_ p: ProcessEntry) {
        guard let path = p.path else { return }
        let url = URL(fileURLWithPath: path)
        // App 进程定位到 .app 包本身
        if let r = path.range(of: ".app/") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// 顶部汇总；单独成一个视图，每秒刷新时不牵动下面的表格
struct ProcessSummary: View {
    @Environment(VitalsStore.self) private var store
    let processes: [ProcessEntry]

    var body: some View {
        let snap = store.snapshot
        let list = processes
        return HStack(spacing: 24) {
            StatTile(title: "进程", value: "\(list.count)", detail: "线程 \(list.reduce(0) { $0 + $1.threads })")
            StatTile(title: "CPU", value: Fmt.pct(snap?.cpu.total, digits: 1), detail: "用户 \(Fmt.pct(snap?.cpu.user)) · 系统 \(Fmt.pct(snap?.cpu.system))", tint: Tint.cpu)
            StatTile(title: "内存", value: Fmt.mem(snap?.memory.usedBytes), detail: "压力 \(snap?.memory.pressureLevel ?? "—")", tint: Tint.memory)
            StatTile(title: "磁盘", value: "↓\(Fmt.rate(snap?.disks.reduce(0) { $0 + $1.readBytesPerSec })) ↑\(Fmt.rate(snap?.disks.reduce(0) { $0 + $1.writeBytesPerSec }))")
            StatTile(title: "网络", value: "↓\(Fmt.rate(snap?.network.reduce(0) { $0 + $1.rxBytesPerSec })) ↑\(Fmt.rate(snap?.network.reduce(0) { $0 + $1.txBytesPerSec }))")
            StatTile(title: "功耗", value: Fmt.watts(snap?.power.systemW ?? snap?.power.packageW), tint: Tint.power)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// 进程图标：App 用自己的图标，其余用通用可执行文件图标；按路径缓存
struct AppIconView: View {
    let path: String?
    let isApp: Bool

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
    }

    private var icon: NSImage {
        guard let path else { return NSWorkspace.shared.icon(for: .unixExecutable) }
        let key = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
        if let img = Self.cache[key] { return img }
        let img = NSWorkspace.shared.icon(forFile: key)
        Self.cache[key] = img
        return img
    }
}
