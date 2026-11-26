import Foundation
import SystemConfiguration

/// Системный прокси macOS (то, что видно в «Настройки → Сеть → Прокси»). Меняется через networksetup:
/// администратору пароль не нужен. Ставим HTTP, HTTPS и SOCKS на 127.0.0.1:порт во всех включённых сетях.
enum SystemProxy {
    struct Endpoint: Equatable {
        var host: String
        var port: Int
    }

    private static let tool = "/usr/sbin/networksetup"

    @discardableResult
    private static func run(_ args: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Включённые сетевые службы (Wi-Fi, кабель, iPhone по USB…).
    static func services() -> [String] {
        let out = run(["-listallnetworkservices"]).output
        return out.split(whereSeparator: \.isNewline).dropFirst()   // первая строка — пояснение про звёздочку
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    /// Возвращает службы, где не получилось (обычно служба VPN: ей прокси не нужен).
    @discardableResult
    static func enable(port: Int, services list: [String]? = nil) -> [String] {
        var failed: [String] = []
        for s in list ?? services() {
            let results = [
                run(["-setwebproxy", s, "127.0.0.1", "\(port)"]),
                run(["-setsecurewebproxy", s, "127.0.0.1", "\(port)"]),
                run(["-setsocksfirewallproxy", s, "127.0.0.1", "\(port)"]),
            ]
            if results.contains(where: { $0.code != 0 }) { failed.append(s) }
        }
        Log.write("системный прокси включён на 127.0.0.1:\(port)" + (failed.isEmpty ? "" : ", не вышло в: \(failed.joined(separator: ", "))"))
        return failed
    }

    /// Выключает только то, что указывает на наш порт: чужие настройки не трогаем.
    static func disable(port: Int, services list: [String]? = nil) {
        for s in list ?? services() {
            for (get, setState) in [("-getwebproxy", "-setwebproxystate"),
                                    ("-getsecurewebproxy", "-setsecurewebproxystate"),
                                    ("-getsocksfirewallproxy", "-setsocksfirewallproxystate")] {
                let info = parse(run([get, s]).output)
                if info.enabled && info.endpoint == Endpoint(host: "127.0.0.1", port: port) {
                    run([setState, s, "off"])
                }
            }
        }
        Log.write("системный прокси выключен")
    }

    private static let kinds = [("-getwebproxy", "-setwebproxy", "-setwebproxystate"),
                                ("-getsecurewebproxy", "-setsecurewebproxy", "-setsecurewebproxystate"),
                                ("-getsocksfirewallproxy", "-setsocksfirewallproxy", "-setsocksfirewallproxystate")]

    static func read(_ service: String) -> [(enabled: Bool, endpoint: Endpoint?)] {
        kinds.map { parse(run([$0.0, service]).output) }
    }

    /// --sysproxy-test <служба>: включить, проверить, что чужое не трогаем, выключить и вернуть как было.
    /// Для проверки на неиспользуемой службе (Thunderbolt Bridge), чтобы не задеть интернет.
    static func roundTrip(service: String, port: Int) -> [String] {
        var problems: [String] = []
        let original = read(service)
        let ours = Endpoint(host: "127.0.0.1", port: port)
        if !enable(port: port, services: [service]).isEmpty { problems.append("enable вернул ошибку") }
        if !read(service).allSatisfy({ $0.enabled && $0.endpoint == ours }) { problems.append("после включения не наш адрес: \(read(service))") }
        disable(port: port + 1, services: [service])
        if !read(service).allSatisfy({ $0.enabled && $0.endpoint == ours }) { problems.append("выключение чужого порта задело наш") }
        disable(port: port, services: [service])
        if read(service).contains(where: { $0.enabled }) { problems.append("после выключения что-то осталось: \(read(service))") }
        // Вернуть как было
        for (kind, was) in zip(kinds, original) {
            if let e = was.endpoint { run([kind.1, service, e.host, "\(e.port)"]) }
            run([kind.2, service, was.enabled ? "on" : "off"])
        }
        let restored = read(service)
        if zip(restored, original).contains(where: { $0.0.enabled != $0.1.enabled || $0.0.endpoint != $0.1.endpoint }) {
            problems.append("не вернулось как было: \(restored) вместо \(original)")
        }
        return problems
    }

    static func parse(_ output: String) -> (enabled: Bool, endpoint: Endpoint?) {
        var enabled = false, host: String?, port: Int?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": enabled = parts[1] == "Yes"
            case "Server": host = parts[1]
            case "Port": port = Int(parts[1])
            default: break
            }
        }
        if let host, let port, !host.isEmpty { return (enabled, Endpoint(host: host, port: port)) }
        return (enabled, nil)
    }

    /// Что сейчас действует для HTTPS (главная сеть). nil — прокси для HTTPS выключен.
    static func currentHTTPS() -> Endpoint? {
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any],
              (dict[kSCPropNetProxiesHTTPSEnable as String] as? Int) == 1,
              let host = dict[kSCPropNetProxiesHTTPSProxy as String] as? String,
              let port = dict[kSCPropNetProxiesHTTPSPort as String] as? Int else { return nil }
        return Endpoint(host: host, port: port)
    }
}
