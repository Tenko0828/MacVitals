import Foundation
import Darwin
import SystemConfiguration

func SCDynamicComputerName() -> String {
    SCDynamicStoreCopyComputerName(nil,nil) as String? ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
}
extension VitalsMonitor {
    public func networkInterfaces() -> [NetworkInterface] {
        struct Addresses { var v4: [String] = []; var v6: [String] = []; var flags: UInt32 = 0; var mtu: Int?; var speed: Double? }
        var addresses: [String:Addresses] = [:]
        var first: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&first) == 0 {
            defer { freeifaddrs(first) }
            var cursor = first
            while let entry = cursor {
                let item = entry.pointee; cursor = item.ifa_next
                let name = String(cString:item.ifa_name)
                var value = addresses[name] ?? Addresses(); value.flags = item.ifa_flags
                if let address = item.ifa_addr {
                    let family = Int32(address.pointee.sa_family)
                    if family == AF_INET || family == AF_INET6 {
                        var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
                        if getnameinfo(address,socklen_t(address.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {
                            let ip = String(cString:host)
                            if family == AF_INET { value.v4.append(ip) } else { value.v6.append(ip) }
                        }
                    }
                    if family == AF_LINK,let data = item.ifa_data {
                        let d = data.assumingMemoryBound(to:if_data.self).pointee
                        value.mtu = Int(d.ifi_mtu)
                        if d.ifi_baudrate > 0 { value.speed = Double(d.ifi_baudrate) / 1e6 }
                    }
                }
                addresses[name] = value
            }
        }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var sc: [String:SCNetworkInterface] = [:]
        for item in interfaces { if let name = SCNetworkInterfaceGetBSDName(item) as String? { sc[name] = item } }
        let store = SCDynamicStoreCreate(nil,"MacVitals" as CFString,nil,nil)
        func state(_ key: String) -> [String:Any] {
            guard let store else { return [:] }; return SCDynamicStoreCopyValue(store,key as CFString) as? [String:Any] ?? [:]
        }
        var ipv4 = state("State:/Network/Global/IPv4")
        let ipv6 = state("State:/Network/Global/IPv6")
        var dns = state("State:/Network/Global/DNS")
        if ipv4["Router"] == nil,let route = command("/sbin/route",["-n","get","default"]),route.status == 0 {
            for line in route.output.split(separator:"\n") {
                let pair = line.split(separator:":",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
                if pair.count == 2 {
                    if pair[0] == "interface" { ipv4["PrimaryInterface"] = pair[1] }
                    if pair[0] == "gateway" { ipv4["Router"] = pair[1] }
                }
            }
        }
        if dns.isEmpty,let content = try? String(contentsOfFile:"/etc/resolv.conf",encoding:.utf8) {
            let servers = content.split(separator:"\n").compactMap { line -> String? in
                let fields = line.split(whereSeparator:{ $0.isWhitespace })
                return fields.count >= 2 && fields[0] == "nameserver" ? String(fields[1]) : nil
            }
            if !servers.isEmpty { dns["ServerAddresses"] = servers }
        }
        return Set(addresses.keys).union(sc.keys).sorted().map { name in
            let a = addresses[name] ?? Addresses(),s = sc[name]
            let type = s.flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? } ?? ""
            let kind: String
            if name == "lo0" { kind = "回环" }
            else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = "Wi-Fi" }
            else if type == (kSCNetworkInterfaceTypeEthernet as String) { kind = "以太网" }
            else if name.hasPrefix("bridge") || type.contains("Bridge") { kind = "雷雳网桥" }
            else if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") || type.contains("VPN") { kind = "VPN" }
            else { kind = "其它" }
            var sections: [InfoSection] = []
            if ipv4["PrimaryInterface"] as? String == name || ipv6["PrimaryInterface"] as? String == name {
                var items: [InfoItem] = []
                if let router = ipv4["Router"] as? String { items.append(InfoItem("默认 IPv4 网关",router)) }
                if let router = ipv6["Router"] as? String { items.append(InfoItem("默认 IPv6 网关",router)) }
                items += flatten(dns,prefix:"DNS")
                sections.append(InfoSection(title:"路由与 DNS",items:items))
            }
            for proto in ["IPv4","IPv6","DNS"] {
                let values = state("State:/Network/Interface/\(name)/\(proto)")
                if !values.isEmpty { sections.append(InfoSection(title:proto,items:flatten(values))) }
            }
            if kind == "Wi-Fi",a.flags & UInt32(IFF_UP) != 0,let summary = command("/usr/sbin/ipconfig",["getsummary",name]),summary.status == 0,!summary.output.isEmpty {
                sections.append(InfoSection(title:"Wi-Fi 详情",items:[InfoItem("连接信息",summary.output)]))
            }
            return NetworkInterface(bsdName:name,displayName:s.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? name,kind:kind,macAddress:s.flatMap { SCNetworkInterfaceGetHardwareAddressString($0) as String? },ipv4:a.v4,ipv6:a.v6,isUp:a.flags & UInt32(IFF_UP) != 0,mtu:a.mtu,linkSpeedMbps:a.speed,sections:sections)
        }
    }
}
