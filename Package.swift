// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacVitals",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CVitalsSupport", path: "Sources/CVitalsSupport", linkerSettings: [.linkedFramework("IOKit")]),
        // 数据采集后端：IOKit / SMC / IOReport / sysctl / libproc / smartctl
        .target(
            name: "VitalsCore",
            dependencies: ["CVitalsSupport"],
            path: "Sources/VitalsCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        // SwiftUI 前端
        .executableTarget(
            name: "MacVitals",
            dependencies: ["VitalsCore"],
            path: "Sources/MacVitals"
        ),
        // 命令行调试工具：把后端采到的全部数据打印成 JSON
        .executableTarget(
            name: "vitals-dump",
            dependencies: ["VitalsCore"],
            path: "Sources/vitals-dump"
        ),
    ]
)
