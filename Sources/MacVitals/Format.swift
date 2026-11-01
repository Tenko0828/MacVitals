import SwiftUI

/// 所有数值的显示格式集中在这里
enum Fmt {
    private static let memoryFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowsNonnumericFormatting = false
        return f
    }()

    /// 内存用二进制（GiB），磁盘/流量用十进制（GB），和系统自己的显示一致
    static func mem(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return memoryFormatter.string(fromByteCount: bytes)
    }

    static func bytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return fileFormatter.string(fromByteCount: bytes)
    }

    static func rate(_ bytesPerSec: Double?) -> String {
        guard let v = bytesPerSec else { return "—" }
        if v < 1000 { return "\(Int(v)) B/s" }
        return fileFormatter.string(fromByteCount: Int64(v)) + "/s"
    }

    static func pct(_ v: Double?, digits: Int = 0) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f%%", v)
    }

    static func temp(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f°C", v)
    }

    static func watts(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 10 ? String(format: "%.2f W", v) : String(format: "%.1f W", v)
    }

    static func mhz(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 1000 ? String(format: "%.2f GHz", v / 1000) : String(format: "%.0f MHz", v)
    }

    static func rpm(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f rpm", v)
    }

    static func int(_ v: Int?) -> String {
        guard let v else { return "—" }
        return v.formatted()
    }

    static func num(_ v: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分 \(s % 60) 秒"
    }

    static func hours(_ h: Int?) -> String {
        guard let h else { return "—" }
        return h >= 48 ? "\(h.formatted()) 小时（约 \(h / 24) 天）" : "\(h) 小时"
    }

    static func minutes(_ m: Int?) -> String {
        guard let m, m > 0 else { return "—" }
        return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func bool(_ b: Bool?, on: String = "开启", off: String = "关闭") -> String {
        guard let b else { return "未知" }
        return b ? on : off
    }
}

/// 颜色阈值
enum Tint {
    static func usage(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        switch v {
        case ..<50: return .green
        case ..<80: return .orange
        default: return .red
        }
    }

    static func temp(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        switch v {
        case ..<55: return .teal
        case ..<75: return .green
        case ..<90: return .orange
        default: return .red
        }
    }

    /// 剩余寿命/健康度：越高越好
    static func health(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        switch v {
        case 80...: return .green
        case 60...: return .orange
        default: return .red
        }
    }

    static let cpu = Color.blue
    static let gpu = Color.purple
    static let memory = Color.green
    static let power = Color.yellow
    static let read = Color.teal
    static let write = Color.pink
    static let rx = Color.cyan
    static let tx = Color.orange
}
