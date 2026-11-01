import SwiftUI
import Charts
import VitalsCore

// MARK: - 页面骨架

/// 每个页面的统一外壳：标题 + 可滚动内容
struct Page<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.bottom, 4)
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                    if let title { Text(title).font(.headline) }
                    Spacer()
                    if let trailing {
                        Text(trailing).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

/// 自适应列数的卡片网格
struct CardGrid<Content: View>: View {
    var minWidth: CGFloat = 280
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
            content
        }
    }
}

// MARK: - 数值展示

struct RingGauge: View {
    let title: String
    let value: Double?          // 0...100
    let text: String
    var detail: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0, min(1, (value ?? 0) / 100)))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(text)
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 104, height: 104)
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var symbol: String? = nil
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MeterBar: View {
    let fraction: Double        // 0...1
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: height)
    }
}

/// 一行：名字 + 条 + 数值
struct MeterRow: View {
    let label: String
    let fraction: Double
    let value: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            Text(label).lineLimit(1).frame(width: 150, alignment: .leading)
            MeterBar(fraction: fraction, tint: tint)
            Text(value).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }
        .font(.callout)
    }
}

/// 分段堆叠条（内存构成、磁盘占用）
struct StackedBar: View {
    struct Part: Identifiable {
        let label: String
        let value: Double
        let tint: Color
        var id: String { label }
    }
    let parts: [Part]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(parts) { p in
                        Rectangle().fill(p.tint.gradient)
                            .frame(width: total > 0 ? max(0, p.value / total * g.size.width - 1.5) : 0)
                    }
                    Spacer(minLength: 0)
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 18)
            FlowLegend(parts: parts)
        }
    }
}

struct FlowLegend: View {
    let parts: [StackedBar.Part]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(parts) { p in
                HStack(spacing: 5) {
                    Circle().fill(p.tint).frame(width: 8, height: 8)
                    Text(p.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - 图表

struct SeriesSpec: Identifiable {
    let name: String
    let samples: [Sample]
    let tint: Color
    var id: String { name }
}

/// 最近一段时间的折线（可多条）
struct HistoryChart: View {
    let series: [SeriesSpec]
    var yMax: Double? = nil                 // 固定上限，例如百分比 100
    var format: (Double) -> String = { Fmt.num($0) }
    var height: CGFloat = 120
    var area = true

    var body: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.samples) { p in
                    if area && series.count == 1 {
                        AreaMark(x: .value("时间", p.t), y: .value(s.name, p.v))
                            .foregroundStyle(LinearGradient(colors: [s.tint.opacity(0.35), s.tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("时间", p.t), y: .value(s.name, p.v), series: .value("系列", s.name))
                        .foregroundStyle(s.tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: 0...(yMax ?? niceMax))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(.caption2) } }
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.tint))
        .frame(height: height)
    }

    private var niceMax: Double {
        let m = series.flatMap(\.samples).map(\.v).max() ?? 1
        return max(m * 1.15, 0.000_1)
    }
}

/// 没有坐标轴的迷你折线
struct Sparkline: View {
    let samples: [Sample]
    var tint: Color = .accentColor
    var yMax: Double? = nil

    var body: some View {
        Chart(samples) { p in
            AreaMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(tint.opacity(0.25))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...(yMax ?? max((samples.map(\.v).max() ?? 1) * 1.1, 0.000_1)))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

// MARK: - 键值信息

struct KVGrid: View {
    let items: [InfoItem]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.key)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 120, alignment: .leading)
                    Text(item.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}

/// 一组 InfoSection，带搜索过滤
struct SectionsView: View {
    let sections: [InfoSection]
    var filter: String = ""
    var minWidth: CGFloat = 380

    var body: some View {
        let shown = filtered
        if shown.isEmpty {
            Text(filter.isEmpty ? "暂无信息" : "没有匹配“\(filter)”的项目").foregroundStyle(.secondary)
        } else {
            CardGrid(minWidth: minWidth) {
                ForEach(shown) { s in
                    Card(title: s.title) { KVGrid(items: s.items) }
                }
            }
        }
    }

    private var filtered: [InfoSection] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sections.filter { !$0.items.isEmpty } }
        return sections.compactMap { s in
            if s.title.localizedCaseInsensitiveContains(q) { return s }
            let items = s.items.filter { $0.key.localizedCaseInsensitiveContains(q) || $0.value.localizedCaseInsensitiveContains(q) }
            return items.isEmpty ? nil : InfoSection(title: s.title, items: items)
        }
    }
}

struct Placeholder: View {
    let text: String
    var symbol = "hourglass"
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}
