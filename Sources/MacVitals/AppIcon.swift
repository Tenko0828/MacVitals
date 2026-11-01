import SwiftUI
import AppKit

/// App 图标：深色圆角方块里一颗芯片，芯片上一条心电图线
enum AppIcon {
    @MainActor
    static func render(to path: String) {
        let renderer = ImageRenderer(content: IconArt().frame(width: 1024, height: 1024))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private struct IconArt: View {
    var body: some View {
        ZStack {
            // macOS 图标网格：824 的圆角方块居中
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.22), Color(red: 0.03, green: 0.05, blue: 0.10)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)

            // 芯片引脚
            ForEach(0..<4) { side in
                HStack(spacing: 46) {
                    ForEach(0..<5) { _ in
                        Capsule().fill(Color(white: 0.55)).frame(width: 22, height: 70)
                    }
                }
                .offset(y: -270)
                .rotationEffect(.degrees(Double(side) * 90))
            }

            RoundedRectangle(cornerRadius: 70, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 440, height: 440)
                .overlay(RoundedRectangle(cornerRadius: 70, style: .continuous).strokeBorder(Color(white: 0.45), lineWidth: 6))

            Pulse()
                .stroke(LinearGradient(colors: [.cyan, .green], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
                .frame(width: 360, height: 220)
                .shadow(color: .cyan.opacity(0.7), radius: 18)
        }
        .frame(width: 1024, height: 1024)
    }
}

private struct Pulse: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let mid = r.midY
        p.move(to: CGPoint(x: r.minX, y: mid))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.28, y: mid))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.52, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.62, y: mid))
        p.addLine(to: CGPoint(x: r.maxX, y: mid))
        return p
    }
}
