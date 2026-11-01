import Foundation
import Darwin
import CoreGraphics

// 所有外部命令仍走 command()；统一截止时间也约束排队和文件扫描。
// 截止后只取快照，不等待慢命令的终止回调或不可取消的文件系统读取。
private final class SoftwareProbeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String: CommandResult] = [:]
    private var files: [InfoSection] = []
    func put(_ key: String, _ result: CommandResult) { lock.holding { commands[key] = result } }
    func put(_ section: InfoSection) { lock.holding { files.append(section) } }
    func snapshot() -> SoftwareExtras { lock.holding { SoftwareExtras(commands: commands, files: files) } }
}

struct SoftwareExtras {
    fileprivate var commands: [String: CommandResult]
    fileprivate var files: [InfoSection]

    static func collect() -> SoftwareExtras {
        let deadline = ProcessInfo.processInfo.systemUptime + 3.2
        let results = SoftwareProbeResults()
        let queue = OperationQueue()
        queue.name = "MacVitals.software"
        queue.maxConcurrentOperationCount = 16
        let group = DispatchGroup()
        func task(_ body: @escaping () -> Void) {
            group.enter()
            queue.addOperation {
                defer { group.leave() }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return }
                body()
            }
        }
        func probe(_ key: String, _ path: String, _ args: [String] = [], timeout: Double = 1.4) {
            task {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime - 0.1
                guard remaining > 0.05,
                      let result = command(path, args, timeout: min(timeout, remaining)), result.status == 0 else { return }
                results.put(key, result)
            }
        }
        // 文件采集独立提交；一个不可读目录不影响其它分组。
        task { applicationSections(deadline: deadline).forEach { results.put($0) } }
        task { results.put(localFileSection(deadline: deadline)) }
        task { results.put(softwareDisplaySection()) }

        probe("swvers", "/usr/bin/sw_vers")
        probe("sip", "/usr/bin/csrutil", ["status"])
        probe("sealed", "/usr/bin/csrutil", ["authenticated-root", "status"])
        probe("filevault", "/usr/bin/fdesetup", ["status"])
        probe("gatekeeper", "/usr/sbin/spctl", ["--status"])
        probe("firewall", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        probe("firewallStealth", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"])
        probe("bootPolicy", "/usr/bin/bputil", ["-d"])
        probe("developerPath", "/usr/bin/xcode-select", ["-p"])
        probe("xcode", "/usr/bin/xcodebuild", ["-version"])
        probe("clt", "/usr/sbin/pkgutil", ["--pkg-info=com.apple.pkg.CLTools_Executables"])
        probe("java", "/usr/libexec/java_home", ["-V"])
        probe("groups", "/usr/bin/id", ["-Gn"])
        probe("power", "/usr/bin/pmset", ["-g", "custom"])
        probe("powerGlobal", "/usr/bin/pmset", ["-g"])
        probe("extensions", "/usr/bin/systemextensionsctl", ["list"])
        probe("kexts", "/usr/bin/kmutil", ["showloaded", "--list-only"])
        probe("tmDestination", "/usr/bin/tmutil", ["destinationinfo", "-X"])
        probe("tmLatest", "/usr/bin/tmutil", ["latestbackup"])
        probe("spotlight", "/usr/bin/mdutil", ["-s", "/"])
        probe("services", "/bin/launchctl", ["print-disabled", "system"])
        probe("proxy", "/usr/sbin/scutil", ["--proxy"])
        probe("dns", "/usr/sbin/scutil", ["--dns"])
        probe("localHostname", "/usr/sbin/scutil", ["--get", "LocalHostName"])
        probe("receipts", "/usr/sbin/pkgutil", ["--pkgs"])
        for (key, domain) in [
            ("global", "-g"), ("updates", "/Library/Preferences/com.apple.SoftwareUpdate"),
            ("login", "/Library/Preferences/com.apple.loginwindow"), ("keyboard", "com.apple.HIToolbox"),
            ("dock", "com.apple.dock"), ("finder", "com.apple.finder"),
            ("accessibility", "com.apple.universalaccess"), ("timeMachine", "/Library/Preferences/com.apple.TimeMachine"),
            ("commerce", "com.apple.commerce")
        ] { probe(key, "/usr/bin/defaults", ["export", domain, "-"]) }

        let home = NSHomeDirectory()
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/.bun/bin",
                    home + "/go/bin", "/usr/local/go/bin", home + "/miniconda3/bin", home + "/anaconda3/bin",
                    "/opt/miniconda3/bin", "/opt/anaconda3/bin", home + "/miniforge3/bin", "/opt/homebrew/Caskroom/miniforge/base/bin",
                    "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin"]
        func tool(_ name: String) -> String? {
            // PATH 中的自定义安装位置也纳入查找；不通过 shell 展开或执行。
            let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            return executable((dirs + pathDirs).filter { $0.hasPrefix("/") }.map { $0 + "/" + name })
        }
        let runtimes: [(String, String, [String])] = [
            ("swift", "swift", ["--version"]), ("python", "python3", ["--version"]),
            ("node", "node", ["--version"]), ("git", "git", ["--version"]),
            ("clang", "clang", ["--version"]), ("ruby", "ruby", ["--version"]),
            ("perl", "perl", ["-e", "print $^V"]), ("go", "go", ["version"]),
            ("rust", "rustc", ["--version"]), ("cargo", "cargo", ["--version"]),
            ("docker", "docker", ["--version"]), ("conda", "conda", ["--version"]),
            ("mamba", "mamba", ["--version"]), ("micromamba", "micromamba", ["--version"]),
            ("npm", "npm", ["--version"]), ("bun", "bun", ["--version"])
        ]
        for (key, name, args) in runtimes { if let path = tool(name) { probe(key, path, args) } }
        if let python = tool("python3") { probe("pipCount", python, ["-m", "pip", "list", "--format=json", "--disable-pip-version-check"], timeout: 1.8) }
        if let npm = tool("npm") { probe("npmCount", npm, ["list", "--global", "--depth=0", "--json"], timeout: 1.8) }
        if let brew = tool("brew") {
            probe("brew", brew, ["--version"])
            probe("brewPrefix", brew, ["--prefix"])
            probe("brewFormula", brew, ["list", "--formula"], timeout: 1.8)
            probe("brewCask", brew, ["list", "--cask"], timeout: 1.8)
            probe("brewOutdated", brew, ["outdated", "--quiet"], timeout: 2)
        }
        _ = group.wait(timeout: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime))
        // 排队任务会先检查截止时间再立即离开 group，避免取消 BlockOperation
        // 后闭包不执行、已 enter 的 group 永远得不到对应 leave。
        return results.snapshot()
    }

    func output(_ key: String) -> String? {
        guard let value = commands[key]?.output, !value.isEmpty else { return nil }
        return value
    }
    private func dictionary(_ key: String) -> [String: Any] {
        guard let data = commands[key]?.data else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }
    private var osValues: [String: String] { Self.pairs(output("swvers") ?? "", separator: ":") }
    var osName: String { osValues["ProductName"] ?? "macOS" }
    var osVersion: String? { osValues["ProductVersion"] }
    var osBuild: String? { osValues["BuildVersion"] }

    func sections() -> [InfoSection] {
        var sections: [InfoSection] = []
        func add(_ title: String, _ items: [InfoItem]) { if !items.isEmpty { sections.append(InfoSection(title: title, items: items)) } }
        func items(_ pairs: [(String, String?)]) -> [InfoItem] { pairs.compactMap { name, value in value.map { InfoItem(name, $0) } } }
        func selected(_ values: [String: Any], _ keys: [(String, String)]) -> [InfoItem] {
            keys.compactMap { key, name in values[key].map { InfoItem(name, Self.describe($0)) } }
        }
        let now = ProcessInfo.processInfo
        let global = dictionary("global")
        let os = now.operatingSystemVersion
        // 仅映射已知版本；未来版本不猜测名称。
        // https://support.apple.com/en-us/127257（27），109033（此前版本）
        let names = [27: "Golden Gate", 26: "Tahoe", 15: "Sequoia", 14: "Sonoma", 13: "Ventura", 12: "Monterey", 11: "Big Sur"]
        let older = [15: "Catalina", 14: "Mojave", 13: "High Sierra", 12: "Sierra", 11: "El Capitan"]
        let marketingName = os.majorVersion == 10 ? older[os.minorVersion] : names[os.majorVersion]
        var system = items([("系统名称", osName), ("系统版本", osVersion), ("系统构建号", osBuild),
                            ("系统代号", marketingName), ("内核版本", sysString("kern.osrelease")),
                            ("内核详情", sysString("kern.version")), ("内核类型", sysString("kern.ostype")),
                            ("系统卷密封", output("sealed")), ("启动安全策略", output("bootPolicy")),
                            ("上次启动原因", sysString("kern.bootreason"))])
        system.append(InfoItem("Darwin 版本", sysString("kern.osrelease") ?? ""))
        system.append(InfoItem("上次开机时间", ISO8601DateFormatter().string(from: bootDate())))
        if let receipts = commands["receipts"] { system.append(InfoItem("安装包收据数量", String(receipts.output.split(separator: "\n").count))) }
        if let reason = sysInt("kern.shutdown_reason") { system.append(InfoItem("上次关机原因代码", String(reason))) }
        add("系统", system)
        add("系统安全", items([("系统完整性保护（SIP）", output("sip")), ("磁盘加密（FileVault）", output("filevault")),
                             ("应用安全评估（Gatekeeper）", output("gatekeeper")), ("防火墙", output("firewall")),
                             ("防火墙隐身模式", output("firewallStealth")), ("系统完整性", output("sealed"))]))
        let updates = dictionary("updates")
        var updateItems = selected(updates, [
            ("AutomaticCheckEnabled", "自动检查更新"), ("AutomaticDownload", "自动下载更新"),
            ("AutomaticallyInstallMacOSUpdates", "自动安装系统更新"), ("CriticalUpdateInstall", "自动安装关键更新"),
            ("ConfigDataInstall", "自动安装配置与安全数据"), ("SplatEnabled", "快速安全响应"),
            ("LastSuccessfulDate", "上次成功检查更新时间"), ("LastSuccessfulMSUScanDate", "上次系统更新扫描时间"),
            ("LastBackgroundSuccessfulDate", "上次后台检查时间"), ("LastFullSuccessfulDate", "上次完整检查时间"),
            ("LastResultCode", "上次更新结果代码"), ("LastSessionSuccessful", "上次更新会话成功"),
            ("LastAttemptSystemVersion", "上次尝试更新版本"), ("LastAttemptBuildVersion", "上次尝试更新构建号"),
            ("CatalogURL", "更新目录地址")])
        if let recommended = updates["RecommendedUpdates"] as? [[String: Any]] {
            updateItems.append(InfoItem("推荐更新数", String(recommended.count)))
            for (i, entry) in recommended.enumerated() {
                let value = [entry["Display Name"], entry["Display Version"]].compactMap { $0 as? String }.joined(separator: " · ")
                if !value.isEmpty { updateItems.append(InfoItem("推荐更新 \(i + 1)", value)) }
            }
        }
        updateItems += selected(dictionary("commerce"), [("AutoUpdate", "自动更新商店应用"), ("AutoUpdateRestartRequired", "自动安装需重启的商店更新")])
        add("软件更新", updateItems)

        var development = items([("开发工具目录", output("developerPath")), ("命令行工具（CLT）版本", Self.pairs(output("clt") ?? "", separator: ":")["version"])])
        if let xcode = output("xcode") { development.append(InfoItem("Xcode 版本", xcode)) }
        else if output("developerPath")?.hasSuffix("/CommandLineTools") == true {
            // 选择 CLT 不能证明其它目录没有 Xcode；只在应用扫描也确认缺失时写未安装。
            if files.contains(where: { $0.items.contains(where: { $0.key == "集成开发工具安装状态" && $0.value == "未安装" }) }) {
                development.append(InfoItem("Xcode 版本", "未安装"))
            }
        }
        for (key, label) in [("swift", "Swift 版本"), ("python", "Python 版本"), ("node", "Node.js 版本"), ("git", "Git 版本"),
                             ("clang", "Clang 版本"), ("ruby", "Ruby 版本"), ("perl", "Perl 版本"), ("go", "Go 版本"),
                             ("rust", "Rust 版本"), ("cargo", "Cargo 版本"), ("docker", "Docker 版本"), ("conda", "Conda 版本"),
                             ("mamba", "Mamba 版本"), ("micromamba", "Micromamba 版本"), ("npm", "npm 版本"), ("bun", "Bun 版本")] {
            if let value = output(key) { development.append(InfoItem(label, value)) }
        }
        if let java = commands["java"] {
            let vms = java.error.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
                $0.contains("/") && $0.range(of: "^[0-9][^ ]* +\\([^)]+\\)", options: .regularExpression) != nil
            }
            if !vms.isEmpty {
                development.append(InfoItem("Java 运行时数量", String(vms.count)))
                development += vms.enumerated().map { InfoItem("Java 运行时 \($0.offset + 1)", $0.element) }
            }
            if !java.output.isEmpty { development.append(InfoItem("Java 默认目录", java.output)) }
        }
        if let data = commands["pipCount"]?.data, let packages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            development.append(InfoItem("pip 包数量", String(packages.count)))
        }
        if let data = commands["npmCount"]?.data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let packages = json["dependencies"] as? [String: Any] { development.append(InfoItem("npm 全局包数量", String(packages.count))) }
        add("开发环境", development)
        var brew = items([("版本", output("brew")), ("安装前缀", output("brewPrefix"))])
        for (key, label) in [("brewFormula", "命令行软件数量"), ("brewCask", "图形应用数量"), ("brewOutdated", "可更新软件数量")] {
            // 成功且空输出意味着 0；失败或超时绝不伪造 0。
            if let result = commands[key] { brew.append(InfoItem(label, String(result.output.split(separator: "\n").count))) }
        }
        add("Homebrew", brew)

        for title in ["应用", "启动项与后台", "存储服务", "电源与时间"] {
            var values = files.filter { $0.title == title }.flatMap(\.items)
            if title == "启动项与后台" {
                if let value = output("extensions"), let first = value.split(separator: "\n").first,
                   let count = Int(first.split(separator: " ").first ?? "") { values.append(InfoItem("系统扩展数量", String(count))) }
                if let value = output("kexts") {
                    let identifiers = value.split(whereSeparator: \.isWhitespace).map(String.init).filter {
                        $0.range(of: "^[A-Za-z][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+){2,}$", options: .regularExpression) != nil
                    }
                    // showloaded 的表头确实存在时，才把无第三方记录解释成 0。
                    if value.contains("Index") && value.contains("Refs") {
                        values.append(InfoItem("第三方内核扩展数量", String(Set(identifiers.filter { !$0.hasPrefix("com.apple.") }).count)))
                    }
                }
            } else if title == "存储服务" {
                if let value = output("spotlight") { values.append(InfoItem("根卷聚焦索引状态", value)) }
                if let value = output("tmLatest") { values.append(InfoItem("时间机器上次备份", value)) }
                let destination = dictionary("tmDestination")
                if let destinations = destination["Destinations"] as? [[String: Any]] {
                    values.append(InfoItem("时间机器目标数量", String(destinations.count)))
                    for (i, d) in destinations.enumerated() {
                        values += selected(d, [("Name", "备份目标 \(i + 1) 名称"), ("Kind", "备份目标 \(i + 1) 类型"),
                                               ("URL", "备份目标 \(i + 1) 地址"), ("MountPoint", "备份目标 \(i + 1) 挂载点")])
                    }
                }
                values += selected(dictionary("timeMachine"), [("AutoBackup", "时间机器自动备份"), ("LastSuccessfulBackupDate", "时间机器上次成功备份时间")])
            } else if title == "电源与时间" {
                values += powerItems()
                values += selected(dictionary("login"), [("autoLoginUser", "自动登录用户")])
            }
            add(title, values)
        }
        let groups = output("groups")?.split(whereSeparator: \.isWhitespace).map(String.init)
        var account = [InfoItem("用户全名", NSFullUserName()), InfoItem("账户名", NSUserName()), InfoItem("用户编号", String(getuid())),
                       InfoItem("主组编号", String(getgid())), InfoItem("主目录", NSHomeDirectory()),
                       InfoItem("区域", Locale.current.identifier), InfoItem("语言", Locale.preferredLanguages.joined(separator: ", ")),
                       InfoItem("时区", TimeZone.current.identifier), InfoItem("时区缩写", TimeZone.current.abbreviation() ?? ""),
                       InfoItem("协调世界时偏移（秒）", String(TimeZone.current.secondsFromGMT())),
                       InfoItem("夏令时", TimeZone.current.isDaylightSavingTime() ? "是" : "否")]
        if let user = getpwuid(getuid()), let shell = user.pointee.pw_shell { account.append(InfoItem("登录命令解释器", String(cString: shell))) }
        if let groups { account += [InfoItem("用户组", groups.joined(separator: ", ")), InfoItem("管理员", groups.contains("admin") ? "是" : "否")] }
        account += selected(global, [("AppleICUForce24HourTime", "强制二十四小时制"), ("AppleICUForce12HourTime", "强制十二小时制"),
                                     ("AppleMetricUnits", "公制单位"), ("AppleMeasurementUnits", "计量单位"), ("AppleTemperatureUnit", "温度单位"),
                                     ("AppleFirstWeekday", "每周第一天"), ("AppleICUDateFormatStrings", "日期格式")])
        let dateFormat = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        if !dateFormat.isEmpty { account.append(InfoItem("当前二十四小时制", dateFormat.contains("a") ? "否" : "是")) }
        if let inputs = dictionary("keyboard")["AppleEnabledInputSources"] as? [[String: Any]] {
            let names = inputs.compactMap { ($0["KeyboardLayout Name"] ?? $0["Input Mode"] ?? $0["Bundle ID"]) as? String }
            account.append(InfoItem("启用的键盘输入源", names.joined(separator: ", ")))
            account.append(InfoItem("键盘输入源数量", String(inputs.count)))
        }
        add("账户与区域", account)

        var network = [InfoItem("主机名", now.hostName), InfoItem("电脑名称", SCDynamicComputerName())]
        if let localHostname = output("localHostname") { network.append(InfoItem("本地主机名", localHostname)) }
        if let services = output("services") {
            for (label, service) in [("远程登录启动策略", "com.openssh.sshd"), ("屏幕共享启动策略", "com.apple.screensharing"), ("文件共享启动策略", "com.apple.smbd")] {
                // 仅显式覆盖项可判定；缺少记录不等于服务关闭，也不代表正在运行。
                if let line = services.split(separator: "\n").first(where: { $0.contains("\"\(service)\"") }) {
                    let state = line.components(separatedBy: "=>").last?.trimmingCharacters(in: .whitespaces)
                    if let state, ["enabled", "disabled", "true", "false"].contains(state) {
                        network.append(InfoItem(label, ["enabled", "false"].contains(state) ? "允许" : "禁用"))
                    }
                }
            }
        }
        let proxyLabels = ["HTTPEnable": "网页代理启用", "HTTPProxy": "网页代理服务器", "HTTPPort": "网页代理端口",
                           "HTTPSEnable": "安全网页代理启用", "HTTPSProxy": "安全网页代理服务器", "HTTPSPort": "安全网页代理端口",
                           "SOCKSEnable": "套接字代理启用", "SOCKSProxy": "套接字代理服务器", "SOCKSPort": "套接字代理端口",
                           "ProxyAutoConfigEnable": "自动代理配置启用", "ProxyAutoConfigURLString": "自动代理配置地址",
                           "ProxyAutoDiscoveryEnable": "自动发现代理", "ExcludeSimpleHostnames": "排除简单主机名"]
        for (key, value) in Self.pairs(output("proxy") ?? "", separator: ":").sorted(by: { $0.key < $1.key }) {
            if let label = proxyLabels[key] { network.append(InfoItem(label, value)) }
        }
        if let dns = output("dns") {
            var seen = Set<String>()
            let servers = dns.split(separator: "\n").compactMap { line -> String? in
                let s = line.trimmingCharacters(in: .whitespaces)
                guard s.hasPrefix("nameserver["), let range = s.range(of: " : ") else { return nil }
                let address = String(s[range.upperBound...])
                return seen.insert(address).inserted ? address : nil
            }
            if !servers.isEmpty { network.append(InfoItem("域名解析服务器", servers.prefix(6).joined(separator: ", "))) }
        }
        add("网络服务", network)

        var appearance = files.filter { $0.title == "显示与外观" }.flatMap(\.items)
        appearance += selected(global, [("AppleInterfaceStyle", "界面外观"), ("AppleInterfaceStyleSwitchesAutomatically", "自动切换外观"),
                                           ("AppleAccentColor", "强调色代码"), ("AppleHighlightColor", "高亮颜色"),
                                           ("AppleAquaColorVariant", "控件外观代码"), ("AppleFontSmoothing", "字体平滑等级"),
                                           ("AppleShowScrollBars", "滚动条显示方式"), ("AppleActionOnDoubleClick", "标题栏双击操作"),
                                           ("AppleShowAllExtensions", "显示文件扩展名"), ("NSAutomaticWindowAnimationsEnabled", "窗口动画"),
                                           ("com.apple.mouse.scaling", "鼠标跟踪速度"), ("com.apple.trackpad.scaling", "触控板跟踪速度"),
                                           ("com.apple.swipescrolldirection", "自然滚动")])
        if commands["global"] != nil && global["AppleInterfaceStyle"] == nil { appearance.append(InfoItem("界面外观", "浅色（默认）")) }
        appearance += selected(dictionary("accessibility"), [("reduceTransparency", "减少透明度"), ("reduceMotion", "减少动态效果"),
                                                               ("increaseContrast", "增强对比度"), ("closeViewScrollWheelToggle", "滚轮缩放启用"),
                                                               ("closeViewZoomFollowsFocus", "缩放跟随焦点"), ("closeViewZoomFactor", "辅助缩放倍数"),
                                                               ("mouseDriverCursorSize", "指针缩放倍数")])
        appearance += selected(dictionary("dock"), [("autohide", "程序坞自动隐藏"), ("tilesize", "程序坞图标大小"), ("magnification", "程序坞放大"),
                                                   ("largesize", "程序坞放大尺寸"), ("orientation", "程序坞位置"), ("show-recents", "程序坞最近使用应用"),
                                                   ("mru-spaces", "自动排列桌面空间"), ("expose-group-apps", "调度中心按应用分组")])
        appearance += selected(dictionary("finder"), [("ShowPathbar", "访达路径栏"), ("ShowStatusBar", "访达状态栏"),
                                                       ("AppleShowAllFiles", "访达显示隐藏文件"), ("FXPreferredViewStyle", "访达默认视图"),
                                                       ("FXEnableExtensionChangeWarning", "更改扩展名警告")])
        add("显示与外观", appearance)
        let fm = FileManager.default
        let rosetta = fm.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") || fm.fileExists(atPath: "/Library/Apple/System/Library/LaunchDaemons/com.apple.oahd.plist")
        // 区域、语言、时区、shell、App 数量在“账户与区域”“应用”里已有，这里不重复
        let up = Int(now.systemUptime)
        let environment = [InfoItem("Rosetta 已安装", rosetta ? "是" : "否"),
                           InfoItem("已开机", "\(up / 86400) 天 \(up % 86400 / 3600) 小时 \(up % 3600 / 60) 分"),
                           InfoItem("低电量模式", now.isLowPowerModeEnabled ? "开" : "关")]
        add("环境", environment)
        return sections
    }

    private func powerItems() -> [InfoItem] {
        let labels = ["sleep": "系统睡眠（分钟）", "displaysleep": "显示器睡眠（分钟）", "disksleep": "磁盘睡眠（分钟）",
                      "powernap": "电能小憩", "lowpowermode": "低电量模式", "hibernatemode": "休眠模式", "tcpkeepalive": "网络保活",
                      "standby": "待机", "standbydelayhigh": "高电量待机延时（秒）", "standbydelaylow": "低电量待机延时（秒）",
                      "highstandbythreshold": "高电量待机阈值", "autopoweroff": "自动断电", "autopoweroffdelay": "自动断电延时（秒）",
                      "womp": "网络唤醒", "lidwake": "开盖唤醒", "acwake": "接通电源唤醒", "ttyskeepawake": "终端会话阻止睡眠",
                      "hibernatefile": "休眠文件", "networkoversleep": "睡眠期间联网", "proximitywake": "靠近唤醒",
                      "Sleep On Power Button": "电源键睡眠", "SleepDisabled": "禁用睡眠", "gpuswitch": "图形处理器切换模式"]
        var values: [InfoItem] = []
        for key in ["power", "powerGlobal"] {
            var source = "全局"
            for line in (output(key) ?? "").split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(":") {
                    source = ["AC Power:": "接通电源", "Battery Power:": "电池供电", "UPS Power:": "备用电源", "Currently in use:": "当前", "System-wide power settings:": "全局"][trimmed] ?? trimmed
                    continue
                }
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                // pmset -g 可在数值后附带 “sleep prevented by …”。
                guard parts.count >= 2 else { continue }
                if let label = labels[String(parts[0])] { values.append(InfoItem("\(source) · \(label)", parts.dropFirst().joined(separator: " "))) }
                else if trimmed.hasPrefix("Sleep On Power Button"), let value = parts.last { values.append(InfoItem("\(source) · 电源键睡眠", String(value))) }
            }
        }
        return values
    }

    private static func pairs(_ output: String, separator: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: separator) else { continue }
            values[line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)] = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
    private static func describe(_ value: Any) -> String {
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let array = value as? [Any] { return array.map(describe).joined(separator: ", ") }
        if let dict = value as? [String: Any] { return dict.keys.sorted().map { "\($0): \(describe(dict[$0]!))" }.joined(separator: ", ") }
        return textValue(value)
    }
}

private func softwarePlist(_ path: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}

private func localFileSection(deadline: TimeInterval) -> InfoSection {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    var items: [InfoItem] = []
    for (path, name) in [(home + "/Library/LaunchAgents", "用户启动代理文件数量"), ("/Library/LaunchAgents", "共享启动代理文件数量"), ("/Library/LaunchDaemons", "后台守护进程文件数量")] {
        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
        if let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            items.append(InfoItem(name, String(urls.filter { $0.pathExtension == "plist" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count)))
        } else if !fm.fileExists(atPath: path), fm.isReadableFile(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) {
            items.append(InfoItem(name, "0"))
        }
    }
    return InfoSection(title: "启动项与后台", items: items)
}

private func applicationSections(deadline: TimeInterval) -> [InfoSection] {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    var appItems: [InfoItem] = []
    var total = Set<String>(), userApps = Set<String>()
    var complete = true
    var xcodeFound = false
    for (path, label) in [("/Applications", "共享应用数量"), (home + "/Applications", "用户应用数量"), ("/System/Applications", "系统应用数量")] {
        var count = 0
        var readable = true
        guard ProcessInfo.processInfo.systemUptime < deadline else { complete = false; break }
        if !fm.fileExists(atPath: path) {
            if fm.isReadableFile(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) { appItems.append(InfoItem(label, "0")) }
            else { complete = false }
            continue
        }
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in readable = false; return true }) else { complete = false; continue }
        for case let url as URL in enumerator {
            if ProcessInfo.processInfo.systemUptime >= deadline { readable = false; break }
            guard url.pathExtension.lowercased() == "app", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard total.insert(resolved).inserted else { continue }
            count += 1
            if path != "/System/Applications" { userApps.insert(resolved) }
            if fm.fileExists(atPath: url.appendingPathComponent("Contents/Developer/usr/bin/xcodebuild").path) { xcodeFound = true }
        }
        if readable { appItems.append(InfoItem(label, String(count))) }
        else { complete = false }
    }
    if complete {
        appItems += [InfoItem("应用总数（含系统应用）", String(total.count)), InfoItem("非系统目录应用总数", String(userApps.count))]
        // 单独保存扫描结论供开发环境使用，不把执行失败解释成未安装。
        if !xcodeFound && !fm.fileExists(atPath: "/Developer/Applications/Xcode.app") {
            appItems.append(InfoItem("集成开发工具安装状态", "未安装"))
        }
    }
    var mas = 0, ios = 0, intel = 0, inspected = 0
    for path in userApps.sorted() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { break }
        inspected += 1
        if fm.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") || fm.fileExists(atPath: path + "/Contents/_MASReceipt") { mas += 1 }
        var info = softwarePlist(path + "/Contents/Info.plist") ?? softwarePlist(path + "/Info.plist")
        var executableRoot = path + "/Contents/MacOS/"
        if let wrapped = try? fm.contentsOfDirectory(atPath: path + "/Wrapper"), let app = wrapped.first(where: { $0.hasSuffix(".app") }) {
            info = softwarePlist(path + "/Wrapper/" + app + "/Info.plist") ?? info
            executableRoot = path + "/Wrapper/" + app + "/"
        }
        if let platforms = info?["CFBundleSupportedPlatforms"] as? [String], platforms.contains("iPhoneOS") { ios += 1 }
        if let name = info?["CFBundleExecutable"] as? String,
           let architectures = softwareMachOArchitectures(executableRoot + name), !architectures.isEmpty,
           architectures.allSatisfy({ $0 == 7 || $0 == 0x01000007 }) { intel += 1 }
    }
    if complete && inspected == userApps.count {
        appItems += [InfoItem("商店来源应用数量（非系统目录）", String(mas)), InfoItem("移动平台应用数量（已确认）", String(ios)),
                     InfoItem("仅英特尔架构应用数量（已确认）", String(intel))]
    }
    var storage: [InfoItem] = []
    let mobileDocuments = home + "/Library/Mobile Documents"
    if fm.fileExists(atPath: mobileDocuments) { storage.append(InfoItem("iCloud Drive 本地目录存在", "是")) }
    else if fm.isReadableFile(atPath: home + "/Library") { storage.append(InfoItem("iCloud Drive 本地目录存在", "否")) }
    // 目录存在是可观察证据，不能据此声称账户当前正在同步。
    if fm.fileExists(atPath: mobileDocuments + "/com~apple~CloudDocs") { storage.append(InfoItem("iCloud Drive 文件目录存在", "是")) }
    var time: [InfoItem] = []
    if let ntp = try? String(contentsOfFile: "/etc/ntp.conf", encoding: .utf8) {
        let servers = ntp.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "#", omittingEmptySubsequences: false).first?.split(whereSeparator: \.isWhitespace) ?? []
            guard fields.count > 1, ["server", "pool", "peer"].contains(String(fields[0])) else { return nil }
            return String(fields[1])
        }
        if !servers.isEmpty { time.append(InfoItem("网络时间服务器", servers.joined(separator: ", "))) }
    }
    return [InfoSection(title: "应用", items: appItems), InfoSection(title: "存储服务", items: storage), InfoSection(title: "电源与时间", items: time)]
}

private func softwareDisplaySection() -> InfoSection {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else {
        return InfoSection(title: "显示与外观", items: [])
    }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return InfoSection(title: "显示与外观", items: []) }
    var items = [InfoItem("活动显示器数量", String(count))]
    for (index, display) in displays.prefix(Int(count)).enumerated() {
        let name = "显示器 \(index + 1)"
        guard let mode = CGDisplayCopyDisplayMode(display) else { continue }
        items += [InfoItem("\(name) 逻辑分辨率", "\(mode.width) × \(mode.height)"),
                  InfoItem("\(name) 渲染分辨率", "\(mode.pixelWidth) × \(mode.pixelHeight)"),
                  InfoItem("\(name) 旋转角度", String(CGDisplayRotation(display))),
                  InfoItem("\(name) 主显示器", CGDisplayIsMain(display) != 0 ? "是" : "否"),
                  InfoItem("\(name) 镜像显示", CGDisplayIsInMirrorSet(display) != 0 ? "是" : "否")]
        if mode.width > 0 { items.append(InfoItem("\(name) 像素缩放倍数", String(Double(mode.pixelWidth) / Double(mode.width)))) }
        if mode.refreshRate > 0 { items.append(InfoItem("\(name) 刷新率（赫兹）", String(mode.refreshRate))) }
    }
    return InfoSection(title: "显示与外观", items: items)
}

// 只读可执行文件头，避免为每个应用启动 lipo/file；兼容大小端和 fat64。
private func softwareMachOArchitectures(_ path: String) -> [UInt32]? {
    guard let file = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 4096), data.count >= 8 else { return nil }
    func word(_ offset: Int, little: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        return little ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }
    guard let magic = word(0, little: false) else { return nil }
    if [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe].contains(magic) {
        return word(4, little: magic == 0xcefaedfe || magic == 0xcffaedfe).map { [$0] }
    }
    guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { return nil }
    let little = magic == 0xbebafeca || magic == 0xbfbafeca
    guard let count = word(4, little: little), count > 0, count <= 64 else { return nil }
    let stride = (magic == 0xcafebabf || magic == 0xbfbafeca) ? 32 : 20
    let values = (0..<Int(count)).compactMap { word(8 + $0 * stride, little: little) }
    return values.count == Int(count) ? values : nil
}
